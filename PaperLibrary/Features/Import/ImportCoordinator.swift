@preconcurrency import Foundation
@preconcurrency import SwiftData

private enum ImportFetchPredicates {
    nonisolated static func work(id: UUID) -> Predicate<Work> {
        #Predicate { $0.id == id }
    }
}

struct PendingImportReview: Identifiable {
    let imported: ImportedPDF
    let candidateWorkID: UUID
    let candidateTitle: String
    let candidateAuthorsText: String
    let candidateYear: Int?
    let candidateVersionCount: Int
    let matchReason: String

    var id: UUID { imported.transactionID }
}

enum ImportReviewResolution {
    case addAsVersion(workID: UUID, versionType: String)
    case importSeparately
    case cancel
}

@MainActor
final class ImportCoordinator: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var statusText: String?
    @Published var errorText: String?
    @Published var noticeText: String?
    @Published private(set) var pendingReview: PendingImportReview?

    private let fileActor = LibraryFileActor()
    private var reviewContinuation: CheckedContinuation<ImportReviewResolution, Never>?

    func importPDFs(
        _ urls: [URL],
        into rootURL: URL,
        addingTo project: ReadingProject? = nil,
        modelContext: ModelContext
    ) {
        guard !isImporting else {
            errorText = "已有一批文献正在导入，请等待完成后再继续。"
            return
        }
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else {
            errorText = "请拖入 PDF 文件。"
            return
        }

        isImporting = true
        statusText = "正在导入 0/\(pdfURLs.count)"

        Task {
            var importedCount = 0
            var skippedCount = 0
            var failures: [String] = []
            let existingWorks: [Work]
            let existingVersions: [FileVersion]
            let availableCategories: [Category]
            do {
                existingWorks = try modelContext.fetch(FetchDescriptor<Work>())
                existingVersions = try modelContext.fetch(FetchDescriptor<FileVersion>())
                availableCategories = try modelContext.fetch(FetchDescriptor<Category>())
            } catch {
                isImporting = false
                statusText = nil
                errorText = "读取现有资料失败：\(error.localizedDescription)"
                return
            }
            var duplicateIndex = DuplicateMatcher.Index(
                works: existingWorks,
                versions: existingVersions
            )

            for url in pdfURLs {
                do {
                    let result = try await fileActor.importPDF(from: url, to: rootURL)
                    let decision = DuplicateMatcher.decision(
                        for: result,
                        index: duplicateIndex
                    )
                    var targetWork: Work?
                    var targetVersion: FileVersion?

                    switch decision {
                    case let .exactFile(existingVersion):
                        try await fileActor.rollbackImport(result, in: rootURL)
                        let existingTitle = existingVersion.work?.title ?? existingVersion.originalFilename
                        noticeText = "“\(url.lastPathComponent)”与“\(existingTitle)”中的已有文件完全一致，因此没有再次加入。"
                        if let project, let existingWork = existingVersion.work,
                           !existingWork.projects.contains(where: { $0.id == project.id }) {
                            existingWork.projects.append(project)
                            do {
                                try modelContext.save()
                            } catch {
                                modelContext.rollback()
                                failures.append("\(url.lastPathComponent)：文件已存在，但加入项目失败：\(error.localizedDescription)")
                                continue
                            }
                        }
                        skippedCount += 1
                        statusText = "已导入 \(importedCount)，跳过重复 \(skippedCount)"
                        continue
                    case let .sameWork(existingWork):
                        let resolution = await requestReview(
                            imported: result,
                            candidate: existingWork,
                            reason: "正文文本指纹完全一致"
                        )
                        switch resolution {
                        case .importSeparately:
                            let work = makeWork(from: result, modelContext: modelContext)
                            modelContext.insert(work)
                            targetWork = work
                            targetVersion = work.preferredFileVersion
                        default:
                            if let importedWork = try await finishReviewedImport(
                                resolution,
                                imported: result,
                                rootURL: rootURL,
                                project: project,
                                modelContext: modelContext
                            ) {
                                duplicateIndex.insert(importedWork)
                                importedCount += 1
                            } else {
                                skippedCount += 1
                            }
                            statusText = "正在导入 \(importedCount + skippedCount)/\(pdfURLs.count)"
                            continue
                        }
                    case let .possibleDuplicate(candidate):
                        let resolution = await requestReview(
                            imported: result,
                            candidate: candidate,
                            reason: "书目信息、标识符或正文内容相似"
                        )
                        switch resolution {
                        case .importSeparately:
                            let work = makeWork(from: result, modelContext: modelContext)
                            modelContext.insert(work)
                            targetWork = work
                            targetVersion = work.preferredFileVersion
                        default:
                            if let importedWork = try await finishReviewedImport(
                                resolution,
                                imported: result,
                                rootURL: rootURL,
                                project: project,
                                modelContext: modelContext
                            ) {
                                duplicateIndex.insert(importedWork)
                                importedCount += 1
                            } else {
                                skippedCount += 1
                            }
                            statusText = "正在导入 \(importedCount + skippedCount)/\(pdfURLs.count)"
                            continue
                        }
                    case .newWork:
                        let work = makeWork(from: result, modelContext: modelContext)
                        modelContext.insert(work)
                        targetWork = work
                        targetVersion = work.preferredFileVersion
                    }

                    if let project, let targetWork,
                       !targetWork.projects.contains(where: { $0.id == project.id }) {
                        targetWork.projects.append(project)
                    }

                    do {
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        do {
                            try await fileActor.rollbackImport(result, in: rootURL)
                        } catch {
                            failures.append("\(url.lastPathComponent)：数据库保存失败，且文件回滚失败：\(error.localizedDescription)")
                            continue
                        }
                        failures.append("\(url.lastPathComponent)：数据库保存失败，已撤销复制。")
                        continue
                    }

                    do {
                        try await fileActor.commitImport(transactionID: result.transactionID, in: rootURL)
                    } catch {
                        failures.append("\(url.lastPathComponent)：导入成功，但事务记录将在下次启动时清理。")
                    }

                    importedCount += 1
                    if let targetWork { duplicateIndex.insert(targetWork) }
                    statusText = "正在导入 \(importedCount)/\(pdfURLs.count)"
                    if let targetWork {
                        guard LocalAPIKeyStore.shared.readIfAvailable()?.isEmpty == false else {
                            markIssue(targetWork, "未配置 Gemini API 密钥，无法自动处理。", modelContext: modelContext)
                            continue
                        }
                        let defaults = UserDefaults.standard
                        let threshold = defaults.integer(forKey: "longDocumentPageThreshold")
                        let effectiveThreshold = threshold > 0 ? threshold : 200
                        let policy = defaults.string(forKey: "longDocumentPolicy") ?? "excerpt"
                        let excerptPages = defaults.integer(forKey: "longDocumentExcerptPages")
                        let effectiveExcerptPages = max(1, excerptPages > 0 ? excerptPages : 60)
                        if result.pageCount > effectiveThreshold && policy == "skip" {
                            markIssue(targetWork, "文献超过设定的页数阈值，已跳过自动处理。", modelContext: modelContext)
                            continue
                        }
                        guard let pdfURL = try? LibraryPathSafety.url(
                            for: result.relativePath,
                            inside: rootURL,
                            requirePDF: true,
                            requireExistingRegularFile: true
                        ) else {
                            markIssue(targetWork, "导入后的 PDF 路径无效或文件已丢失。", modelContext: modelContext)
                            continue
                        }
                        let coordinator = AIAnalysisCoordinator()
                        _ = await coordinator.analyze(
                            work: targetWork,
                            pdfURL: pdfURL,
                            pageCount: result.pageCount,
                            mode: .extract,
                            categories: availableCategories,
                            rootURL: rootURL,
                            pageLimit: result.pageCount > effectiveThreshold ? effectiveExcerptPages : nil,
                            analyzedVersion: targetVersion,
                            modelContext: modelContext
                        )
                    }
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            isImporting = false
            if importedCount > 0 || skippedCount > 0 {
                statusText = "已导入 \(importedCount) 篇，跳过重复 \(skippedCount) 篇"
            } else {
                statusText = nil
            }
            if !failures.isEmpty {
                errorText = failures.joined(separator: "\n")
            }
        }
    }

    func resolvePendingReview(_ resolution: ImportReviewResolution) {
        guard let continuation = reviewContinuation else { return }
        reviewContinuation = nil
        pendingReview = nil
        continuation.resume(returning: resolution)
    }

    private func requestReview(
        imported: ImportedPDF,
        candidate: Work,
        reason: String
    ) async -> ImportReviewResolution {
        await withCheckedContinuation { continuation in
            pendingReview = PendingImportReview(
                imported: imported,
                candidateWorkID: candidate.id,
                candidateTitle: candidate.title,
                candidateAuthorsText: candidate.authorsText,
                candidateYear: candidate.publicationYear,
                candidateVersionCount: candidate.fileVersions.count,
                matchReason: reason
            )
            reviewContinuation = continuation
            statusText = "等待审核“\(imported.originalFilename)”"
        }
    }

    private func finishReviewedImport(
        _ resolution: ImportReviewResolution,
        imported: ImportedPDF,
        rootURL: URL,
        project: ReadingProject?,
        modelContext: ModelContext
    ) async throws -> Work? {
        switch resolution {
        case .cancel:
            try await fileActor.rollbackImport(imported, in: rootURL)
            return nil
        case .importSeparately:
            let work = makeWork(from: imported, modelContext: modelContext)
            if let project { work.projects.append(project) }
            modelContext.insert(work)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                try? await fileActor.rollbackImport(imported, in: rootURL)
                throw error
            }
            do {
                try await fileActor.commitImport(transactionID: imported.transactionID, in: rootURL)
            } catch {
                noticeText = "“\(imported.originalFilename)”已恢复为独立文献，但导入事务记录清理失败：\(error.localizedDescription)。下次启动时会再次清理。"
            }
            return work
        case let .addAsVersion(workID, versionType):
            let descriptor = FetchDescriptor<Work>(predicate: ImportFetchPredicates.work(id: workID))
            guard let work = try modelContext.fetch(descriptor).first else {
                try await fileActor.rollbackImport(imported, in: rootURL)
                throw CocoaError(.fileNoSuchFile)
            }
            let version = makeFileVersion(from: imported, isPreferred: false)
            version.versionTypeRawValue = versionType
            work.fileVersions.append(version)
            if let project, !work.projects.contains(where: { $0.id == project.id }) {
                work.projects.append(project)
            }
            if work.nberNumber == nil { work.nberNumber = imported.nberNumber }
            if work.ssrnID == nil { work.ssrnID = imported.ssrnID }
            if work.arxivID == nil { work.arxivID = imported.arxivID }
            if work.repecHandle == nil { work.repecHandle = imported.repecHandle }

            guard let request = ArchiveRules.articleRelocationRequest(for: work) else {
                modelContext.rollback()
                try await fileActor.rollbackImport(imported, in: rootURL)
                throw CocoaError(.fileNoSuchFile)
            }
            let batch: ArticleRelocationBatch
            do {
                batch = try await fileActor.relocateArticles([request], in: rootURL)
            } catch {
                modelContext.rollback()
                try? await fileActor.rollbackImport(imported, in: rootURL)
                throw error
            }
            let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                ($0.fileVersionID, $0.destinationRelativePath)
            })
            for file in work.fileVersions where paths[file.id] != nil {
                file.relativePath = paths[file.id]!
            }
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                try await fileActor.rollbackArticleRelocations(batch, in: rootURL)
                try? await fileActor.rollbackImport(imported, in: rootURL)
                throw error
            }
            var cleanupFailures: [String] = []
            do {
                try await fileActor.commitArticleRelocations(batch, in: rootURL)
            } catch {
                cleanupFailures.append("文件整理事务：\(error.localizedDescription)")
            }
            do {
                try await fileActor.commitImport(transactionID: imported.transactionID, in: rootURL)
            } catch {
                cleanupFailures.append("导入事务：\(error.localizedDescription)")
            }
            if !cleanupFailures.isEmpty {
                noticeText = "“\(imported.originalFilename)”已作为新版本加入，但事务记录清理未完成：\(cleanupFailures.joined(separator: "；"))。下次启动时会再次清理。"
            }
            return work
        }
    }

    private func markIssue(_ work: Work, _ message: String, modelContext: ModelContext) {
        work.needsReview = true
        if work.metadataConflictNote == nil {
            work.metadataConflictNote = message
        }
        do {
            try modelContext.save()
        } catch {
            errorText = "保存待检查状态失败：\(error.localizedDescription)"
        }
    }

    func recoverPendingImports(in rootURL: URL, modelContext: ModelContext) {
        guard !isImporting else { return }
        isImporting = true

        Task {
            defer { isImporting = false }
            do {
                let scan = try await fileActor.scanRecoverableImports(in: rootURL)
                var messages = scan.warnings
                var knownPaths = Set(
                    try modelContext.fetch(FetchDescriptor<FileVersion>()).map(\.relativePath)
                )
                let existingWorks = try modelContext.fetch(FetchDescriptor<Work>())
                let existingVersions = try modelContext.fetch(FetchDescriptor<FileVersion>())
                var duplicateIndex = DuplicateMatcher.Index(
                    works: existingWorks,
                    versions: existingVersions
                )
                var recoveredCount = 0

                for item in scan.recoverableItems {
                    if knownPaths.contains(item.relativePath) {
                        try? await fileActor.commitImport(transactionID: item.transactionID, in: rootURL)
                        continue
                    }

                    let decision = DuplicateMatcher.decision(
                        for: item,
                        index: duplicateIndex
                    )
                    switch decision {
                    case let .exactFile(existingVersion):
                        try await fileActor.rollbackImport(item, in: rootURL)
                        let existingTitle = existingVersion.work?.title ?? existingVersion.originalFilename
                        messages.append("“\(item.originalFilename)”与“\(existingTitle)”中的已有文件完全一致，已撤销未完成的重复导入。")
                        continue
                    case let .sameWork(candidate), let .possibleDuplicate(candidate):
                        let reason: String
                        if case .sameWork = decision {
                            reason = "正文文本指纹完全一致"
                        } else {
                            reason = "书目信息、标识符或正文内容相似"
                        }
                        let resolution = await requestReview(
                            imported: item,
                            candidate: candidate,
                            reason: reason
                        )
                        do {
                            if let importedWork = try await finishReviewedImport(
                                resolution,
                                imported: item,
                                rootURL: rootURL,
                                project: nil,
                                modelContext: modelContext
                            ) {
                                duplicateIndex.insert(importedWork)
                                recoveredCount += 1
                            }
                        } catch {
                            messages.append("“\(item.originalFilename)”恢复失败：\(error.localizedDescription)")
                        }
                        continue
                    case .newWork:
                        break
                    }

                    let work = makeWork(from: item, modelContext: modelContext)
                    modelContext.insert(work)
                    do {
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        messages.append("\(item.originalFilename)：恢复数据库记录失败，文件和事务记录已保留。")
                        continue
                    }

                    knownPaths.insert(item.relativePath)
                    duplicateIndex.insert(work)
                    recoveredCount += 1
                    do {
                        try await fileActor.commitImport(transactionID: item.transactionID, in: rootURL)
                    } catch {
                        messages.append("\(item.originalFilename)：记录已恢复，事务记录将在下次启动时再次清理。")
                    }
                }

                if recoveredCount > 0 {
                    statusText = "已恢复 \(recoveredCount) 个未完成导入"
                }
                if !messages.isEmpty {
                    errorText = messages.joined(separator: "\n")
                }
            } catch {
                errorText = "检查未完成导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func makeWork(from imported: ImportedPDF, modelContext: ModelContext) -> Work {
        let uncategorized = try? modelContext.fetch(FetchDescriptor<Category>()).first {
            $0.name == "Uncategorized"
        }
        let work = Work(
            title: URL(fileURLWithPath: imported.originalFilename)
                .deletingPathExtension().lastPathComponent,
            authorsText: "",
            publicationYear: nil,
            // 正文正则得到的 DOI 只是一条候选证据，可能来自参考文献。
            // 正式 DOI 由 AI 提取后再交给 Crossref 核对。
            doi: nil,
            nberNumber: imported.nberNumber,
            ssrnID: imported.ssrnID,
            arxivID: imported.arxivID,
            repecHandle: imported.repecHandle,
            primaryCategory: uncategorized
        )
        work.fileVersions.append(makeFileVersion(from: imported))
        return work
    }

    private func makeFileVersion(from imported: ImportedPDF, isPreferred: Bool = true) -> FileVersion {
        FileVersion(
            relativePath: imported.relativePath,
            originalFilename: imported.originalFilename,
            pageCount: imported.pageCount,
            fileSize: imported.fileSize,
            fileMetadataYear: imported.fileMetadataYear,
            sha256: imported.sha256,
            textFingerprint: imported.textFingerprint,
            hasAnnotations: imported.hasAnnotations,
            versionTypeRawValue: imported.suggestedVersionType,
            isPreferred: isPreferred,
            bibliographicTitle: imported.title,
            bibliographicAuthorsText: imported.authorsText.isEmpty ? nil : imported.authorsText,
            bibliographicYear: imported.publicationYear,
            bibliographicDOI: PDFMetadataExtractor.normalizedDOI(imported.doi),
            bibliographicMetadataSource: "pdf",
            bibliographicMetadataConfirmed: false
        )
    }

}

enum DuplicateDecision {
    case exactFile(FileVersion)
    case sameWork(Work)
    case possibleDuplicate(Work)
    case newWork
}

enum DuplicateMatcher {
    struct Index {
        fileprivate var orderedWorkIDs: [UUID] = []
        fileprivate var worksByID: [UUID: Work] = [:]
        fileprivate var versionsBySHA256: [String: FileVersion] = [:]
        fileprivate var worksByIdentifier: [String: Work] = [:]
        fileprivate var worksByFingerprint: [String: Work] = [:]
        fileprivate var workIDsByTitleToken: [String: Set<UUID>] = [:]

        init(works: [Work], versions: [FileVersion]) {
            for work in works { insert(work) }
            for version in versions { register(version) }
        }

        mutating func insert(_ work: Work) {
            if worksByID[work.id] == nil { orderedWorkIDs.append(work.id) }
            worksByID[work.id] = work
            registerIdentifier("doi", PDFMetadataExtractor.normalizedDOI(work.doi), work: work)
            registerIdentifier("nber", work.nberNumber, work: work)
            registerIdentifier("ssrn", work.ssrnID, work: work)
            registerIdentifier("arxiv", work.arxivID, work: work)
            registerIdentifier("repec", work.repecHandle, work: work)
            for token in DuplicateMatcher.tokens(work.title) {
                workIDsByTitleToken[token, default: []].insert(work.id)
            }
            for version in work.fileVersions { register(version) }
        }

        private mutating func register(_ version: FileVersion) {
            if !version.sha256.isEmpty, versionsBySHA256[version.sha256] == nil {
                versionsBySHA256[version.sha256] = version
            }
            if let fingerprint = version.textFingerprint,
               !fingerprint.isEmpty,
               let work = version.work,
               worksByFingerprint[fingerprint] == nil {
                worksByFingerprint[fingerprint] = work
            }
        }

        private mutating func registerIdentifier(_ kind: String, _ value: String?, work: Work) {
            guard let key = DuplicateMatcher.identifierKey(kind, value),
                  worksByIdentifier[key] == nil else { return }
            worksByIdentifier[key] = work
        }
    }

    static func decision(
        for imported: ImportedPDF,
        works: [Work],
        versions: [FileVersion]
    ) -> DuplicateDecision {
        decision(for: imported, index: Index(works: works, versions: versions))
    }

    static func decision(for imported: ImportedPDF, index: Index) -> DuplicateDecision {
        if let exact = index.versionsBySHA256[imported.sha256] {
            return .exactFile(exact)
        }

        let identifierKeys = [
            identifierKey("doi", PDFMetadataExtractor.normalizedDOI(imported.doi)),
            identifierKey("nber", imported.nberNumber),
            identifierKey("ssrn", imported.ssrnID),
            identifierKey("arxiv", imported.arxivID),
            identifierKey("repec", imported.repecHandle),
        ].compactMap { $0 }
        for key in identifierKeys {
            if let candidate = index.worksByIdentifier[key] { return .possibleDuplicate(candidate) }
        }

        if let fingerprint = imported.textFingerprint,
           let work = index.worksByFingerprint[fingerprint] {
            return .sameWork(work)
        }

        // 达到阈值的候选必然至少共享一个标题词；其余字段权重之和不足 0.66。
        let candidateIDs = tokens(imported.title).reduce(into: Set<UUID>()) { result, token in
            result.formUnion(index.workIDsByTitleToken[token] ?? [])
        }
        var best: (work: Work, score: Double)?
        for workID in index.orderedWorkIDs where candidateIDs.contains(workID) {
            guard let work = index.worksByID[workID] else { continue }
            let score = similarity(imported: imported, work: work)
            if best == nil || score > best!.score { best = (work, score) }
        }
        guard let best else { return .newWork }
        // 本地标题、作者和年份尚未经过 AI 与可靠来源核对，不能据此自动合并。
        if best.score >= 0.66 { return .possibleDuplicate(best.work) }
        return .newWork
    }

    private static func similarity(imported: ImportedPDF, work: Work) -> Double {
        let title = tokenSimilarity(imported.title, work.title)
        let authors = tokenSimilarity(imported.authorsText, work.authorsText)
        let year: Double
        if let lhs = imported.publicationYear, let rhs = work.publicationYear {
            year = abs(lhs - rhs) <= 1 ? 1 : 0
        } else {
            year = 0.4
        }

        let fingerprint: Double
        if let lhs = imported.textFingerprint,
           let rhs = work.fileVersions.compactMap(\.textFingerprint).first {
            fingerprint = simHashSimilarity(lhs, rhs)
        } else {
            fingerprint = 0
        }
        return title * 0.55 + authors * 0.20 + year * 0.10 + fingerprint * 0.15
    }

    private static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }

    private static func simHashSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard let left = UInt64(lhs, radix: 16), let right = UInt64(rhs, radix: 16) else { return 0 }
        return 1 - Double((left ^ right).nonzeroBitCount) / 64
    }

    private static func identifiersMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func identifierKey(_ kind: String, _ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return "\(kind):\(value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased())"
    }

}

@MainActor
final class ArchiveCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published var errorText: String?

    private let fileActor = LibraryFileActor()
    private struct PendingArchive {
        let work: Work
        let title: String
        let authorsText: String
        let publicationYear: Int?
        let category: Category?
        let rootURL: URL
        let modelContext: ModelContext
    }
    private var pendingArchive: PendingArchive?

    func archive(
        work: Work,
        title: String,
        authorsText: String,
        publicationYear: Int?,
        category: Category?,
        in rootURL: URL,
        modelContext: ModelContext
    ) {
        guard !isWorking else {
            pendingArchive = PendingArchive(
                work: work,
                title: title,
                authorsText: authorsText,
                publicationYear: publicationYear,
                category: category,
                rootURL: rootURL,
                modelContext: modelContext
            )
            return
        }
        isWorking = true

        Task {
            do {
                guard let request = ArchiveRules.articleRelocationRequest(
                    for: work,
                    title: title,
                    authorsText: authorsText,
                    publicationYear: publicationYear,
                    categoryName: category?.name,
                    metadataConfirmed: true
                ) else { throw CocoaError(.fileNoSuchFile) }
                let batch = try await fileActor.relocateArticles([request], in: rootURL)
                let newPaths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                    ($0.fileVersionID, $0.destinationRelativePath)
                })

                work.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                work.authorsText = authorsText.trimmingCharacters(in: .whitespacesAndNewlines)
                work.publicationYear = publicationYear
                work.primaryCategory = category
                work.metadataConfirmed = true
                if work.crossrefVerifiedDOI == nil,
                   work.metadataSource.caseInsensitiveCompare("crossref") == .orderedSame {
                    work.crossrefVerifiedDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
                }
                work.metadataSource = "manual"
                for version in work.fileVersions {
                    if let path = newPaths[version.id] {
                        version.relativePath = path
                    }
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
                    errorText = "归档已完成，事务记录将在下次启动时清理。"
                }
            } catch {
                errorText = "归档失败：\(error.localizedDescription)"
            }

            isWorking = false
            if let pendingArchive {
                self.pendingArchive = nil
                archive(
                    work: pendingArchive.work,
                    title: pendingArchive.title,
                    authorsText: pendingArchive.authorsText,
                    publicationYear: pendingArchive.publicationYear,
                    category: pendingArchive.category,
                    in: pendingArchive.rootURL,
                    modelContext: pendingArchive.modelContext
                )
            }
        }
    }
}

@MainActor
final class BatchArchiveCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published var errorText: String?
    private let fileActor = LibraryFileActor()

    func reassign(
        works: [Work],
        to category: Category,
        deleting oldCategory: Category? = nil,
        rootURL: URL,
        modelContext: ModelContext,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isWorking else {
            errorText = "另一项文件移动尚未完成，请稍后重试。"
            completion?(false)
            return
        }
        isWorking = true

        Task {
            var succeeded = false
            let requests = works.compactMap {
                ArchiveRules.articleRelocationRequest(for: $0, categoryName: category.name)
            }

            do {
                let batch = try await fileActor.relocateArticles(requests, in: rootURL)
                let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                    ($0.fileVersionID, $0.destinationRelativePath)
                })
                for work in works {
                    work.primaryCategory = category
                    for file in work.fileVersions where paths[file.id] != nil {
                        file.relativePath = paths[file.id]!
                    }
                }
                if let oldCategory { modelContext.delete(oldCategory) }

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
                    errorText = "批量归档已完成，事务记录将在下次启动时清理。"
                }
                succeeded = true
            } catch {
                errorText = "批量归档失败：\(error.localizedDescription)"
            }
            isWorking = false
            completion?(succeeded)
        }
    }
}

enum WorkReprocessingRules {
    static func reset(_ work: Work, uncategorized: Category) {
        if let preferred = work.preferredFileVersion {
            work.title = URL(fileURLWithPath: preferred.originalFilename)
                .deletingPathExtension().lastPathComponent
            preferred.versionTypeRawValue = "unknown"
            preferred.bibliographicTitle = nil
            preferred.bibliographicAuthorsText = nil
            preferred.bibliographicYear = nil
            preferred.bibliographicJournal = nil
            preferred.bibliographicDOI = nil
            preferred.bibliographicMetadataSource = nil
            preferred.bibliographicMetadataConfirmed = false
        }
        work.authorsText = ""
        work.publicationYear = nil
        work.journal = nil
        work.abstractText = nil
        work.doi = nil
        work.documentTypeRawValue = nil
        work.isbn = nil
        work.publisher = nil
        work.metadataConfirmed = false
        work.metadataSource = "pendingAI"
        // 重新处理应当清除上一轮自动处理留下的复核标记。
        // 唯一需要保留的是尚未解决的重复文献关系。
        work.needsReview = work.duplicateCandidateWorkID != nil
        work.metadataConflictNote = nil
        work.clearOpenAlexJournalMetrics()
        work.primaryCategory = uncategorized
        // 用户标签、强学术标识符、重复检查状态和历史 AI 分析均保留。
    }
}

@MainActor
final class WorkReprocessingCoordinator: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published var errorText: String?
}

@MainActor
enum ArchiveMaintenance {
    static func normalizeStructuredFilenames(
        works: [Work],
        rootURL: URL,
        modelContext: ModelContext
    ) async throws {
        let fileActor = LibraryFileActor()
        let requests = works.compactMap { ArchiveRules.articleRelocationRequest(for: $0) }
            .filter(needsNormalization)
        guard !requests.isEmpty else { return }

        let batch = try await fileActor.relocateArticles(requests, in: rootURL)
        let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
            ($0.fileVersionID, $0.destinationRelativePath)
        })
        for work in works {
            for version in work.fileVersions {
                if let path = paths[version.id] { version.relativePath = path }
            }
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
            // 文件与数据库已一致；遗留的事务记录会在下次启动时清理。
        }
    }

    /// 已处于规范目录且文件名未变化的文献不创建文件移动事务。
    private static func needsNormalization(_ request: ArticleRelocationRequest) -> Bool {
        let folder = ArchiveRules.sanitizedComponent(
            request.preferredFolderName,
            fallback: "Untitled Paper",
            maximumLength: 180,
            maximumUTF8Bytes: 220
        )
        return request.files.contains { file in
            let components = file.sourceRelativePath.split(separator: "/").map(String.init)
            guard components.count >= 4 else { return true }
            let tail = Array(components.suffix(4))
            return tail[0] != request.categoryFolder ||
                tail[1] != request.yearFolder ||
                tail[2] != folder ||
                tail[3] != file.preferredFilename
        }
    }
}
