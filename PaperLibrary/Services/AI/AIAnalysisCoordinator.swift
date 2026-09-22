@preconcurrency import Foundation
@preconcurrency import SwiftData

private enum AnalysisFetchPredicates {
    nonisolated static func monthlyAnalyses(
        since monthStart: Date,
        excluding id: UUID
    ) -> Predicate<AIAnalysis> {
        #Predicate { $0.createdAt >= monthStart && $0.id != id }
    }

    nonisolated static func monthlyStudyNotes(since monthStart: Date) -> Predicate<StudyNoteGeneration> {
        #Predicate { $0.createdAt >= monthStart }
    }
}

enum AnalysisOutcome: Equatable {
    case completed
    case cancelled
    case failed(String)
}

@MainActor
final class AIAnalysisCoordinator: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published var errorText: String?
    private var analysisTask: Task<Void, Never>?
    private weak var currentRecord: AIAnalysis?
    private var currentTicket: UUID?
    private let fileActor = LibraryFileActor()
    private let crossrefClient = CrossrefClient()

    func analyze(
        work: Work,
        pdfURL: URL,
        pageCount: Int,
        mode: AnalysisMode,
        categories: [Category],
        rootURL: URL,
        pageLimit: Int? = nil,
        analyzedVersion: FileVersion? = nil,
        resetBeforeApplying: Category? = nil,
        modelContext: ModelContext,
        completion: ((AnalysisOutcome) -> Void)? = nil
    ) {
        guard !isAnalyzing else {
            completion?(.failed("已有分析正在进行。"))
            return
        }
        guard let apiKey = LocalAPIKeyStore.shared.readIfAvailable(), !apiKey.isEmpty else {
            errorText = GeminiAnalysisError.missingAPIKey.localizedDescription
            completion?(.failed(errorText ?? "缺少 API 密钥。"))
            return
        }

        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: "geminiModel") ?? "gemini-3.5-flash-lite"
        let effectiveAnalyzedVersion = analyzedVersion ?? work.preferredFileVersion
        let record = AIAnalysis(
            modelName: model,
            promptVersion: "economics-card-v5",
            status: "queued",
            analyzedFileVersionID: effectiveAnalyzedVersion?.id
        )
        work.analyses.append(record)
        currentRecord = record
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            currentRecord = nil
            errorText = "建立 AI 队列记录失败：\(error.localizedDescription)"
            completion?(.failed(errorText ?? error.localizedDescription))
            return
        }
        isAnalyzing = true
        let ticket = UUID()
        currentTicket = ticket

        analysisTask = Task {
            let acquired = await AIRequestGate.shared.acquire(ticket)
            guard acquired, !Task.isCancelled else {
                if acquired {
                    await AIRequestGate.shared.release(ticket)
                }
                record.status = "cancelled"
                record.errorMessage = "用户已取消分析。"
                do {
                    try modelContext.save()
                } catch {
                    errorText = "保存取消状态失败：\(error.localizedDescription)"
                }
                isAnalyzing = false
                analysisTask = nil
                currentRecord = nil
                currentTicket = nil
                completion?(.cancelled)
                return
            }
            let inputRate = defaults.double(forKey: "aiInputPricePerMillionUSD")
            let outputRate = defaults.double(forKey: "aiOutputPricePerMillionUSD")
            do {
                record.status = "running"
                try modelContext.save()
                let budget = defaults.double(forKey: "monthlyAIBudgetUSD")
                let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
                let currentRecordID = record.id
                let analysisSpent = (try? modelContext.fetch(FetchDescriptor<AIAnalysis>(
                    predicate: AnalysisFetchPredicates.monthlyAnalyses(
                        since: monthStart,
                        excluding: currentRecordID
                    )
                )))?
                    .reduce(0) { $0 + $1.estimatedCostUSD } ?? 0
                let studyNoteSpent = (try? modelContext.fetch(FetchDescriptor<StudyNoteGeneration>(
                    predicate: AnalysisFetchPredicates.monthlyStudyNotes(since: monthStart)
                )))?
                    .reduce(0) { $0 + $1.estimatedCostUSD } ?? 0
                let spent = analysisSpent + studyNoteSpent
                guard budget <= 0 || spent < budget else {
                    throw GeminiAnalysisError.budgetExceeded
                }
                let remainingBudget = budget > 0 ? budget - spent : nil
                let allowedCategoryNames = categories.map(\.name)
                let existingTagNames = (try? modelContext.fetch(FetchDescriptor<Tag>()))?.map(\.name) ?? []
                let response = try await GeminiPaperAnalyzer(
                    apiKey: apiKey,
                    model: model,
                    remainingBudgetUSD: remainingBudget,
                    inputPricePerMillionUSD: inputRate,
                    outputPricePerMillionUSD: outputRate
                )
                    .analyze(
                        pdfURL: pdfURL,
                        mode: mode,
                        allowedCategories: allowedCategoryNames,
                        existingTags: existingTagNames,
                        pageLimit: pageLimit
                    )
                record.inputTokens = response.inputTokens
                record.outputTokens = response.outputTokens
                record.totalTokens = response.totalTokens
                record.estimatedCostUSD =
                    Double(response.inputTokens) / 1_000_000 * inputRate +
                    Double(response.outputTokens) / 1_000_000 * outputRate
                try Task.checkCancellation()
                let providedPageCount = min(pageCount, pageLimit ?? pageCount)
                guard response.analysis.evidenceFields
                    .flatMap(\.pages)
                    .allSatisfy({ $0 >= 1 && $0 <= providedPageCount })
                else { throw GeminiAnalysisError.invalidPageEvidence }
                guard allowedCategoryNames.contains(response.analysis.suggestedCategory) else {
                    throw GeminiAnalysisError.invalidResponse
                }

                let data = try JSONEncoder().encode(response.analysis)
                record.resultJSON = String(decoding: data, as: UTF8.self)
                record.status = "completed"
                if let resetBeforeApplying {
                    WorkReprocessingRules.reset(work, uncategorized: resetBeforeApplying)
                }
                AIAnalysisMetadataApplier.apply(
                    response.analysis,
                    to: work,
                    version: effectiveAnalyzedVersion
                )
                WorkReviewRules.setPageNumberWarning(response.needsEvidenceReview, on: work)
                try AIAnalysisTagApplier.apply(
                    response.analysis.suggestedTags,
                    to: work,
                    modelContext: modelContext
                )
                try modelContext.save()
                if !Task.isCancelled {
                    await verifyWithCrossref(
                        work,
                        version: effectiveAnalyzedVersion,
                        modelContext: modelContext
                    )
                }
                if !Task.isCancelled {
                    do {
                        try PostAnalysisDuplicateLinker.link(work, modelContext: modelContext)
                    } catch {
                    // 分析结果已经完整保存；重复链接失败只需要后续检查，
                    // 不应把这次 AI 分析改写为失败。
                        work.needsReview = true
                        if work.metadataConflictNote == nil {
                            work.metadataConflictNote = "重复文献检查未完成：\(error.localizedDescription)"
                        }
                        do {
                            try modelContext.save()
                            errorText = "AI 分析已完成，但重复文献检查未完成。"
                        } catch {
                            errorText = "AI 分析已完成，但检查状态保存失败：\(error.localizedDescription)"
                        }
                    }
                }
                if !Task.isCancelled {
                    do {
                        try await applySuggestedCategory(
                            response.analysis.suggestedCategory,
                            to: work,
                            categories: categories,
                            rootURL: rootURL,
                            modelContext: modelContext
                        )
                        AIAnalysisIssueRules.clearResolvedAutomaticIssue(on: work)
                        try modelContext.save()
                    } catch {
                        errorText = "AI 分析已保存，但自动分类失败：\(error.localizedDescription)"
                        work.needsReview = true
                        work.metadataConflictNote = "自动分类失败：\(error.localizedDescription)"
                        do {
                            try modelContext.save()
                        } catch {
                            errorText = "AI 分析已保存，但分类状态保存失败：\(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                if case let GeminiAnalysisError.billedUsage(input, output, total, _) = error {
                    record.inputTokens = input
                    record.outputTokens = output
                    record.totalTokens = total
                    record.estimatedCostUSD =
                        Double(input) / 1_000_000 * inputRate +
                        Double(output) / 1_000_000 * outputRate
                }
                record.status = Task.isCancelled ? "cancelled" : "failed"
                record.errorMessage = Task.isCancelled ? "用户已取消分析。" : error.localizedDescription
                do {
                    try modelContext.save()
                } catch {
                    errorText = "AI 处理失败，且错误状态无法保存：\(error.localizedDescription)"
                }
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
            await AIRequestGate.shared.release(ticket)
            isAnalyzing = false
            analysisTask = nil
            currentRecord = nil
            currentTicket = nil
            switch record.status {
            case "completed": completion?(.completed)
            case "cancelled": completion?(.cancelled)
            default: completion?(.failed(record.errorMessage ?? errorText ?? "分析失败。"))
            }
        }
    }

    func analyze(
        work: Work,
        pdfURL: URL,
        pageCount: Int,
        mode: AnalysisMode,
        categories: [Category],
        rootURL: URL,
        pageLimit: Int? = nil,
        analyzedVersion: FileVersion? = nil,
        resetBeforeApplying: Category? = nil,
        modelContext: ModelContext
    ) async -> AnalysisOutcome {
        await withCheckedContinuation { continuation in
            analyze(
                work: work,
                pdfURL: pdfURL,
                pageCount: pageCount,
                mode: mode,
                categories: categories,
                rootURL: rootURL,
                pageLimit: pageLimit,
                analyzedVersion: analyzedVersion,
                resetBeforeApplying: resetBeforeApplying,
                modelContext: modelContext
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    func cancel() {
        if let currentTicket {
            Task { await AIRequestGate.shared.cancel(currentTicket) }
        }
        analysisTask?.cancel()
    }

    private func applySuggestedCategory(
        _ categoryName: String,
        to work: Work,
        categories: [Category],
        rootURL: URL,
        modelContext: ModelContext
    ) async throws {
        guard work.primaryCategory == nil || work.primaryCategory?.isSystemCategory == true,
              let target = categories.first(where: { $0.name == categoryName }),
              target.modelContext != nil
        else { return }

        guard let request = ArchiveRules.articleRelocationRequest(
            for: work,
            categoryName: target.name
        ) else {
            work.primaryCategory = target
            try modelContext.save()
            return
        }

        let batch = try await fileActor.relocateArticles([request], in: rootURL)
        let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
            ($0.fileVersionID, $0.destinationRelativePath)
        })
        work.primaryCategory = target
        for version in work.fileVersions {
            if let path = paths[version.id] { version.relativePath = path }
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            try await fileActor.rollbackArticleRelocations(batch, in: rootURL)
            throw error
        }
        do {
            try await fileActor.commitArticleRelocations(batch, in: rootURL)
        } catch {
            errorText = "自动分类已完成，事务记录将在下次启动时清理。"
        }
    }

    private func verifyWithCrossref(
        _ work: Work,
        version: FileVersion?,
        modelContext: ModelContext
    ) async {
        do {
            let email = UserDefaults.standard.string(forKey: "crossrefContactEmail")
            guard let metadata = try await crossrefClient.lookup(
                doi: work.doi,
                title: work.title,
                author: work.authorsText,
                publicationYear: work.publicationYear,
                contactEmail: email
            ) else { return }
            CrossrefMetadataApplier.apply(metadata, to: work, version: version)
            try modelContext.save()
        } catch {
            // 网络核对失败不会丢弃已完成的 AI 提取和本地文件。
        }
    }

}

@MainActor
final class BatchAIAnalysisCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusText: String?
    @Published var errorText: String?

    private var task: Task<Void, Never>?
    private var currentAnalyzer: AIAnalysisCoordinator?

    func analyze(
        works: [Work],
        categories: [Category],
        rootURL: URL,
        resetBeforeAnalysis: Bool,
        modelContext: ModelContext
    ) {
        guard !isWorking, !works.isEmpty else { return }
        guard LocalAPIKeyStore.shared.readIfAvailable()?.isEmpty == false else {
            errorText = GeminiAnalysisError.missingAPIKey.localizedDescription
            return
        }
        guard !resetBeforeAnalysis || uncategorizedCategory(in: categories) != nil else {
            errorText = "找不到系统未分类目录。"
            return
        }

        isWorking = true
        errorText = nil
        let operationName = resetBeforeAnalysis ? "重新处理" : "快速提取"

        task = Task {
            var completed = 0
            var skipped = 0
            var failed = 0
            var stoppedForBudget = false

            for (index, work) in works.enumerated() {
                guard !Task.isCancelled else { break }
                statusText = "\(operationName) \(index + 1)/\(works.count)：\(work.title)"

                guard let preferred = work.preferredFileVersion else {
                    skipped += 1
                    continue
                }
                let settings = analysisSettings(pageCount: preferred.pageCount)
                guard !settings.shouldSkip else {
                    skipped += 1
                    continue
                }

                guard let currentFile = work.preferredFileVersion else {
                    skipped += 1
                    continue
                }
                guard let pdfURL = try? LibraryPathSafety.url(
                    for: currentFile.relativePath,
                    inside: rootURL,
                    requirePDF: true,
                    requireExistingRegularFile: true
                ) else {
                    failed += 1
                    continue
                }
                let analyzer = AIAnalysisCoordinator()
                currentAnalyzer = analyzer
                let outcome = await analyzer.analyze(
                    work: work,
                    pdfURL: pdfURL,
                    pageCount: currentFile.pageCount,
                    mode: .extract,
                    categories: categories,
                    rootURL: rootURL,
                    pageLimit: settings.pageLimit,
                    resetBeforeApplying: resetBeforeAnalysis
                        ? uncategorizedCategory(in: categories)
                        : nil,
                    modelContext: modelContext
                )
                currentAnalyzer = nil
                guard !Task.isCancelled else { break }

                if outcome == .completed {
                    completed += 1
                } else {
                    failed += 1
                    let message: String
                    if case let .failed(reason) = outcome {
                        message = reason
                    } else {
                        message = analyzer.errorText ?? ""
                    }
                    if message.contains("预算") || message.contains("费用核算") {
                        stoppedForBudget = true
                        skipped += works.count - index - 1
                        break
                    }
                }
            }

            if Task.isCancelled {
                statusText = "已取消\(operationName)；已完成 \(completed) 篇。"
            } else {
                statusText = "\(operationName)完成：成功 \(completed) 篇，跳过 \(skipped) 篇，失败 \(failed) 篇。"
                if stoppedForBudget {
                    errorText = "费用预算不足，已停止后续文献。"
                } else if failed > 0 {
                    errorText = "\(failed) 篇文献处理失败，其他文献已保存。"
                }
            }
            isWorking = false
            task = nil
        }
    }

    func cancel() {
        currentAnalyzer?.cancel()
        task?.cancel()
    }

    private func uncategorizedCategory(in categories: [Category]) -> Category? {
        categories.first(where: { $0.isSystemCategory })
            ?? categories.first(where: { $0.name == "Uncategorized" })
    }

    private func analysisSettings(pageCount: Int) -> (shouldSkip: Bool, pageLimit: Int?) {
        let defaults = UserDefaults.standard
        let thresholdValue = defaults.integer(forKey: "longDocumentPageThreshold")
        let threshold = thresholdValue > 0 ? thresholdValue : 200
        guard pageCount > threshold else { return (false, nil) }
        let policy = defaults.string(forKey: "longDocumentPolicy") ?? "excerpt"
        guard policy != "skip" else { return (true, nil) }
        let excerptValue = defaults.integer(forKey: "longDocumentExcerptPages")
        return (false, max(1, excerptValue > 0 ? excerptValue : 60))
    }
}

enum AIAnalysisIssueRules {
    static func clearResolvedAutomaticIssue(on work: Work) {
        guard work.duplicateCandidateWorkID == nil, let note = work.metadataConflictNote else { return }
        let resolvedPrefixes = [
            "未配置 Gemini API 密钥",
            "文献超过设定的页数阈值",
            "AI 处理因上次运行中断",
            "重复文献检查未完成",
            "自动分类失败"
        ]
        guard resolvedPrefixes.contains(where: { note.contains($0) }) else { return }
        WorkReviewRules.removeIssues(from: work, whosePrefixMatches: resolvedPrefixes)
    }
}

@MainActor
enum PostAnalysisDuplicateLinker {
    static func link(_ work: Work, modelContext: ModelContext) throws {
        guard work.duplicateCandidateWorkID == nil else { return }
        let normalizedDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
        let candidates = try modelContext.fetch(FetchDescriptor<Work>()).filter { $0.id != work.id }
        let candidate = candidates.first { other in
            if let normalizedDOI,
               PDFMetadataExtractor.normalizedDOI(other.doi) == normalizedDOI,
               work.crossrefChecked || other.crossrefChecked {
                return true
            }
            return strongIdentifierMatches(work, other)
        }
        guard let candidate else { return }
        work.duplicateCandidateWorkID = candidate.id
        work.needsReview = true
        work.metadataConflictNote = "可靠标识符显示这可能是已有文献的另一个版本，请检查后合并。"
        try modelContext.save()
    }

    private static func strongIdentifierMatches(_ lhs: Work, _ rhs: Work) -> Bool {
        matches(lhs.nberNumber, rhs.nberNumber) ||
            matches(lhs.ssrnID, rhs.ssrnID) ||
            matches(lhs.arxivID, rhs.arxivID) ||
            matches(lhs.repecHandle, rhs.repecHandle)
    }

    private static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }
}

@MainActor
enum AIAnalysisTagApplier {
    @discardableResult
    static func apply(
        _ suggestions: [String],
        to work: Work,
        modelContext: ModelContext
    ) throws -> Bool {
        let names = normalizedNames(suggestions)
        guard !names.isEmpty else { return false }
        let existingTags = try modelContext.fetch(FetchDescriptor<Tag>())
        var byName: [String: Tag] = [:]
        for tag in existingTags where byName[tag.name.lowercased()] == nil {
            byName[tag.name.lowercased()] = tag
        }
        var changed = false

        for name in names {
            let key = name.lowercased()
            let tag: Tag
            if let existing = byName[key] {
                tag = existing
            } else {
                tag = Tag(name: name, colorHex: colorHex(for: name))
                modelContext.insert(tag)
                byName[key] = tag
            }
            if !work.tags.contains(where: { $0.id == tag.id }) {
                work.tags.append(tag)
                changed = true
            }
        }
        return changed
    }

    static func normalizedNames(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw -> String? in
            let value = raw
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 48,
                  seen.insert(value.lowercased()).inserted
            else { return nil }
            return value
        }.prefix(8).map { $0 }
    }

    private static func colorHex(for name: String) -> String {
        let palette = ["#4F7CAC", "#7A6FBE", "#3A9278", "#C4773B", "#B65C75", "#547A3E"]
        let value = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[value % palette.count]
    }
}

@MainActor
enum AIAnalysisTagBackfill {
    private struct StoredTagSuggestions: Decodable {
        let suggestedTags: [String]
    }

    @discardableResult
    static func run(modelContext: ModelContext) throws -> Int {
        let works = try modelContext.fetch(FetchDescriptor<Work>())
        var changedCount = 0
        for work in works {
            guard let latest = work.analyses
                .filter({ $0.status == "completed" })
                .max(by: { $0.createdAt < $1.createdAt }),
                  let json = latest.resultJSON,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(StoredTagSuggestions.self, from: data),
                  try AIAnalysisTagApplier.apply(
                    payload.suggestedTags,
                    to: work,
                    modelContext: modelContext
                  )
            else { continue }
            changedCount += 1
        }
        if changedCount > 0 { try modelContext.save() }
        return changedCount
    }
}

@MainActor
enum TagMaintenance {
    @discardableResult
    static func deleteOrphans(modelContext: ModelContext) throws -> Int {
        let tags = try modelContext.fetch(FetchDescriptor<Tag>())
        let orphans = tags.filter(\.works.isEmpty)
        for tag in orphans { modelContext.delete(tag) }
        return orphans.count
    }
}

@MainActor
enum AIAnalysisRecoveryMaintenance {
    @discardableResult
    static func markInterruptedTasks(modelContext: ModelContext) throws -> Int {
        let analyses = try modelContext.fetch(FetchDescriptor<AIAnalysis>())
        let interrupted = analyses.filter { $0.status == "queued" || $0.status == "running" }
        for analysis in interrupted {
            analysis.status = "failed"
            analysis.errorMessage = "上次运行在处理过程中中断，请重新分析。"
            analysis.work?.needsReview = true
            if analysis.work?.metadataConflictNote == nil {
                analysis.work?.metadataConflictNote = "AI 处理因上次运行中断而未完成。"
            }
        }
        if !interrupted.isEmpty { try modelContext.save() }
        return interrupted.count
    }
}

enum AIAnalysisMetadataApplier {
    @discardableResult
    static func apply(_ analysis: PaperAnalysis, to work: Work, version: FileVersion?) -> Bool {
        var versionChanged = false
        if let version, !version.bibliographicMetadataConfirmed {
            if let value = explicitValue(analysis.bibliographicTitle),
               version.bibliographicTitle != value {
                version.bibliographicTitle = value
                versionChanged = true
            }
            if let value = explicitValue(analysis.bibliographicAuthors),
               version.bibliographicAuthorsText != value {
                version.bibliographicAuthorsText = value
                versionChanged = true
            }
            if let value = explicitValue(analysis.bibliographicYear),
               let year = Int(value),
               (1900...(Calendar.current.component(.year, from: .now) + 1)).contains(year),
               version.bibliographicYear != year {
                version.bibliographicYear = year
                versionChanged = true
            }
            if let value = explicitValue(analysis.bibliographicDOI),
               let doi = PDFMetadataExtractor.normalizedDOI(value),
               version.bibliographicDOI != doi {
                version.bibliographicDOI = doi
                versionChanged = true
            }
            if let value = explicitValue(analysis.bibliographicJournalOrSeries),
               version.bibliographicJournal != value {
                version.bibliographicJournal = value
                versionChanged = true
            }
            if let value = explicitValue(analysis.fileVersionType),
               allowedVersionTypes.contains(value),
               version.versionTypeRawValue != value {
                version.versionTypeRawValue = value
                versionChanged = true
            }
            if versionChanged {
                version.bibliographicMetadataSource = "ai"
            }
        }

        guard !work.metadataConfirmed, !work.crossrefChecked else { return versionChanged }
        let previousDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
        let previousJournal = work.journal
        var changed = false

        if let value = explicitValue(analysis.bibliographicTitle),
           let version,
           LocalMetadataRepairRules.isPlaceholderTitle(
            work.title,
            originalFilename: version.originalFilename
           ) {
            work.title = value
            changed = true
        }
        if work.authorsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = explicitValue(analysis.bibliographicAuthors) {
            work.authorsText = value
            changed = true
        }
        if work.publicationYear == nil,
           let value = explicitValue(analysis.bibliographicYear),
           let year = Int(value),
           (1900...(Calendar.current.component(.year, from: .now) + 1)).contains(year) {
            work.publicationYear = year
            changed = true
        }
        if let value = explicitValue(analysis.bibliographicDOI),
           let doi = PDFMetadataExtractor.normalizedDOI(value) {
            if PDFMetadataExtractor.normalizedDOI(work.doi) != doi {
                work.doi = doi
                changed = true
            }
        }
        if (work.journal ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = explicitValue(analysis.bibliographicJournalOrSeries) {
            work.journal = value
            changed = true
        }
        if work.isbn == nil, let value = explicitValue(analysis.bibliographicISBN) {
            work.isbn = value
            changed = true
        }
        if work.publisher == nil, let value = explicitValue(analysis.bibliographicPublisher) {
            work.publisher = value
            changed = true
        }
        if work.documentTypeRawValue == nil,
           let value = explicitValue(analysis.documentType),
           allowedDocumentTypes.contains(value) {
            work.documentTypeRawValue = value
            changed = true
        }
        if changed { work.metadataSource = "ai" }
        if previousDOI != PDFMetadataExtractor.normalizedDOI(work.doi) ||
            previousJournal != work.journal {
            work.clearOpenAlexJournalMetrics()
        }
        return changed || versionChanged
    }

    private static let allowedVersionTypes: Set<String> = [
        "published", "workingPaper", "acceptedManuscript", "preprint",
        "supplement", "annotatedCopy"
    ]
    private static let allowedDocumentTypes: Set<String> = [
        "article", "workingPaper", "book", "bookChapter", "report", "thesis", "other"
    ]

    private static func explicitValue(_ field: AnalysisField?) -> String? {
        guard let field,
              field.status == "explicit",
              field.confidence >= 0.8
        else { return nil }
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "unknown" ? nil : value
    }
}
