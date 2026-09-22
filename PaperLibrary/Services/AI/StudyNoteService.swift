import AppKit
@preconcurrency import Foundation
@preconcurrency import SwiftData

private enum StudyNoteFetchPredicates {
    nonisolated static func monthlyAnalyses(since monthStart: Date) -> Predicate<AIAnalysis> {
        #Predicate { $0.createdAt >= monthStart }
    }

    nonisolated static func monthlyNotes(since monthStart: Date) -> Predicate<StudyNoteGeneration> {
        #Predicate { $0.createdAt >= monthStart }
    }
}

enum StudyNoteDraftStore {
    static func draftURL(filename: String, fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "PaperLibrary/StudyNoteDrafts", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: filename)
    }

    static func writeHeader(title: String, filename: String) throws {
        let heading = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try draftURL(filename: filename)
        try Data("<h1 style=\"text-align: center; font-style: italic\">\(heading)</h1>\n".utf8)
            .write(to: url, options: .atomic)
    }

    static func append(_ text: String, filename: String) throws {
        let url = try draftURL(filename: filename)
        guard let handle = try? FileHandle(forWritingTo: url) else { throw CocoaError(.fileNoSuchFile) }
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        var endsWithNewline = false
        if endOffset > 0 {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            try reader.seek(toOffset: endOffset - 1)
            endsWithNewline = try reader.read(upToCount: 1) == Data([0x0A])
        }
        let separator = endsWithNewline ? "\n" : "\n\n"
        try handle.write(contentsOf: Data("\(separator)\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n".utf8))
    }

    static func hasParts(filename: String) -> Bool {
        guard let url = try? draftURL(filename: filename),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        return text.contains("\n# ")
    }

    @discardableResult
    static func export(
        filename: String,
        pdfFilename: String,
        incomplete: Bool,
        downloadsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = try draftURL(filename: filename, fileManager: fileManager)
        var contents = try String(contentsOf: source, encoding: .utf8)
        if incomplete {
            contents = contents.replacingOccurrences(
                of: "\n",
                with: "\n\n> ⚠️ 此精读笔记尚未完成，以下内容为已成功生成的章节。\n",
                options: [],
                range: contents.range(of: "\n")
            )
        }
        let downloads: URL
        if let downloadsDirectory {
            downloads = downloadsDirectory
        } else {
            downloads = try fileManager.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: pdfFilename).deletingPathExtension().lastPathComponent
        let suffix = incomplete ? "-精读笔记-未完成" : "-精读笔记"
        var target = downloads.appending(path: "\(base)\(suffix).md")
        var number = 2
        while fileManager.fileExists(atPath: target.path) {
            target = downloads.appending(path: "\(base)\(suffix) (\(number)).md")
            number += 1
        }
        try Data(contents.utf8).write(to: target, options: .withoutOverwriting)
        return target
    }

    @discardableResult
    static func exportBesidePDF(
        filename: String,
        pdfURL: URL,
        incomplete: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = try draftURL(filename: filename, fileManager: fileManager)
        var contents = try String(contentsOf: source, encoding: .utf8)
        if incomplete {
            contents = contents.replacingOccurrences(
                of: "\n",
                with: "\n\n> ⚠️ 此精读笔记尚未完成，以下内容为已成功生成的章节。\n",
                options: [],
                range: contents.range(of: "\n")
            )
        }

        let completedURL = LiteratureCompanionPaths.noteURL(for: pdfURL, kind: .study)
        var target = completedURL
        if incomplete {
            let baseURL = completedURL.deletingPathExtension()
            target = baseURL.deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)-未完成.md")
            var number = 2
            while fileManager.fileExists(atPath: target.path) {
                target = baseURL.deletingLastPathComponent()
                    .appending(path: "\(baseURL.lastPathComponent)-未完成 (\(number)).md")
                number += 1
            }
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target, options: .withoutOverwriting)
        return target
    }

    static func remove(filename: String, fileManager: FileManager = .default) {
        guard let url = try? draftURL(filename: filename, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }
}

struct StudyNoteCheckpoint: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    let taskID: UUID
    let workID: UUID
    let pdfSHA256: String
    let modelName: String
    let promptVersion: String
    var outline: String
    var totalParts: Int
    var completedParts: Int
    let createdAt: Date
    var updatedAt: Date
}

struct RecoverableStudyNote: Equatable, Sendable {
    let checkpoint: StudyNoteCheckpoint
    let draft: String
}

enum StudyNoteCheckpointStore {
    static let hiddenDirectoryName = ".paperlib-study-notes"
    private static let checkpointFilename = "checkpoint.json"
    private static let draftFilename = "draft.md"

    static func initialize(
        taskID: UUID,
        workID: UUID,
        pdfSHA256: String,
        modelName: String,
        promptVersion: String,
        title: String,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = taskDirectory(for: taskID, pdfURL: pdfURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let heading = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("<h1 style=\"text-align: center; font-style: italic\">\(heading)</h1>\n".utf8)
            .write(to: directory.appending(path: draftFilename), options: .atomic)
        let now = Date()
        try write(
            StudyNoteCheckpoint(
                taskID: taskID,
                workID: workID,
                pdfSHA256: pdfSHA256,
                modelName: modelName,
                promptVersion: promptVersion,
                outline: "",
                totalParts: 0,
                completedParts: 0,
                createdAt: now,
                updatedAt: now
            ),
            taskID: taskID,
            pdfURL: pdfURL,
            fileManager: fileManager
        )
    }

    static func savePlan(
        _ outline: String,
        totalParts: Int,
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) throws {
        var checkpoint = try readCheckpoint(taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
        checkpoint.outline = outline
        checkpoint.totalParts = totalParts
        checkpoint.updatedAt = .now
        try write(checkpoint, taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
    }

    static func appendPart(
        _ text: String,
        part: Int,
        totalParts: Int,
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard GeminiStudyNoteClient.isValidPart(text, number: part) else {
            throw StudyNoteError.invalidPart(part)
        }
        var checkpoint = try readCheckpoint(taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
        if checkpoint.completedParts >= part { return }
        guard checkpoint.completedParts == part - 1 else { throw StudyNoteError.invalidPart(part) }

        let directory = taskDirectory(for: taskID, pdfURL: pdfURL)
        let draftURL = directory.appending(path: draftFilename)
        guard let handle = try? FileHandle(forWritingTo: draftURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        var endsWithNewline = false
        if endOffset > 0 {
            let reader = try FileHandle(forReadingFrom: draftURL)
            defer { try? reader.close() }
            try reader.seek(toOffset: endOffset - 1)
            endsWithNewline = try reader.read(upToCount: 1) == Data([0x0A])
        }
        let separator = endsWithNewline ? "\n" : "\n\n"
        let addition = separator + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try handle.write(contentsOf: Data(addition.utf8))
        try handle.synchronize()

        checkpoint.totalParts = totalParts
        checkpoint.completedParts = part
        checkpoint.updatedAt = .now
        try write(checkpoint, taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
    }

    static func load(
        taskID: UUID,
        workID: UUID,
        pdfSHA256: String,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) throws -> RecoverableStudyNote {
        var checkpoint = try readCheckpoint(taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
        guard checkpoint.schemaVersion == StudyNoteCheckpoint.currentSchemaVersion,
              checkpoint.taskID == taskID,
              checkpoint.workID == workID,
              checkpoint.pdfSHA256 == pdfSHA256,
              !checkpoint.outline.isEmpty,
              checkpoint.totalParts > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        let draft = try String(
            contentsOf: taskDirectory(for: taskID, pdfURL: pdfURL)
                .appending(path: draftFilename),
            encoding: .utf8
        )
        let recoveredCount = completedPartCount(in: draft)
        guard recoveredCount > 0, recoveredCount < checkpoint.totalParts else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if recoveredCount != checkpoint.completedParts {
            checkpoint.completedParts = recoveredCount
            checkpoint.updatedAt = .now
            try write(checkpoint, taskID: taskID, pdfURL: pdfURL, fileManager: fileManager)
        }
        return RecoverableStudyNote(checkpoint: checkpoint, draft: draft)
    }

    static func hasRecoverableCheckpoint(
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let checkpoint = try? readCheckpoint(
            taskID: taskID,
            pdfURL: pdfURL,
            fileManager: fileManager
        ), checkpoint.totalParts > checkpoint.completedParts,
           checkpoint.completedParts > 0,
           let draft = try? String(
            contentsOf: taskDirectory(for: taskID, pdfURL: pdfURL)
                .appending(path: draftFilename),
            encoding: .utf8
           )
        else { return false }
        return completedPartCount(in: draft) > 0
    }

    @discardableResult
    static func exportBesidePDF(
        taskID: UUID,
        pdfURL: URL,
        incomplete: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = taskDirectory(for: taskID, pdfURL: pdfURL).appending(path: draftFilename)
        var contents = try String(contentsOf: source, encoding: .utf8)
        if incomplete {
            contents = contents.replacingOccurrences(
                of: "\n",
                with: "\n\n> ⚠️ 此精读笔记尚未完成，以下内容为已成功生成的章节。\n",
                options: [],
                range: contents.range(of: "\n")
            )
        }
        let completedURL = LiteratureCompanionPaths.noteURL(for: pdfURL, kind: .study)
        var target = completedURL
        if incomplete {
            let baseURL = completedURL.deletingPathExtension()
            target = baseURL.deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)-未完成.md")
            var number = 2
            while fileManager.fileExists(atPath: target.path) {
                target = baseURL.deletingLastPathComponent()
                    .appending(path: "\(baseURL.lastPathComponent)-未完成 (\(number)).md")
                number += 1
            }
        }
        try Data(contents.utf8).write(to: target, options: .withoutOverwriting)
        return target
    }

    static func remove(
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager = .default
    ) {
        let directory = taskDirectory(for: taskID, pdfURL: pdfURL)
        try? fileManager.removeItem(at: directory)
        let root = directory.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: root.path).isEmpty) == true {
            try? fileManager.removeItem(at: root)
        }
    }

    static func taskDirectory(for taskID: UUID, pdfURL: URL) -> URL {
        pdfURL.deletingLastPathComponent()
            .appending(path: hiddenDirectoryName, directoryHint: .isDirectory)
            .appending(path: taskID.uuidString, directoryHint: .isDirectory)
    }

    private static func readCheckpoint(
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager
    ) throws -> StudyNoteCheckpoint {
        let url = taskDirectory(for: taskID, pdfURL: pdfURL).appending(path: checkpointFilename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StudyNoteCheckpoint.self, from: data)
    }

    private static func write(
        _ checkpoint: StudyNoteCheckpoint,
        taskID: UUID,
        pdfURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = taskDirectory(for: taskID, pdfURL: pdfURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint)
            .write(to: directory.appending(path: checkpointFilename), options: .atomic)
    }

    private static func completedPartCount(in draft: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^#(?!#)\s+"#) else { return 0 }
        return regex.numberOfMatches(
            in: draft,
            range: NSRange(draft.startIndex..., in: draft)
        )
    }
}

/// 串行化精读草稿的磁盘操作，并确保生成回调不会在主线程读写文件。
actor StudyNoteFileStore {
    func initialize(
        taskID: UUID,
        workID: UUID,
        pdfSHA256: String,
        modelName: String,
        promptVersion: String,
        title: String,
        pdfURL: URL
    ) throws {
        try StudyNoteCheckpointStore.initialize(
            taskID: taskID,
            workID: workID,
            pdfSHA256: pdfSHA256,
            modelName: modelName,
            promptVersion: promptVersion,
            title: title,
            pdfURL: pdfURL
        )
    }

    func load(
        taskID: UUID,
        workID: UUID,
        pdfSHA256: String,
        pdfURL: URL
    ) throws -> RecoverableStudyNote {
        try StudyNoteCheckpointStore.load(
            taskID: taskID,
            workID: workID,
            pdfSHA256: pdfSHA256,
            pdfURL: pdfURL
        )
    }

    func savePlan(_ outline: String, totalParts: Int, taskID: UUID, pdfURL: URL) throws {
        try StudyNoteCheckpointStore.savePlan(
            outline,
            totalParts: totalParts,
            taskID: taskID,
            pdfURL: pdfURL
        )
    }

    func appendPart(_ text: String, part: Int, totalParts: Int, taskID: UUID, pdfURL: URL) throws {
        try StudyNoteCheckpointStore.appendPart(
            text,
            part: part,
            totalParts: totalParts,
            taskID: taskID,
            pdfURL: pdfURL
        )
    }

    func export(taskID: UUID, pdfURL: URL, incomplete: Bool) throws -> URL {
        try StudyNoteCheckpointStore.exportBesidePDF(
            taskID: taskID,
            pdfURL: pdfURL,
            incomplete: incomplete
        )
    }

    func hasRecoverableCheckpoint(taskID: UUID, pdfURL: URL) -> Bool {
        StudyNoteCheckpointStore.hasRecoverableCheckpoint(taskID: taskID, pdfURL: pdfURL)
    }

    func remove(taskID: UUID, pdfURL: URL) {
        StudyNoteCheckpointStore.remove(taskID: taskID, pdfURL: pdfURL)
    }
}

enum StudyNoteResumeRules {
    static func canResume(_ record: StudyNoteGeneration) -> Bool {
        (record.status == "failed" || record.status == "cancelled") &&
            record.completedParts > 0 &&
            record.totalParts > record.completedParts
    }

    static func canResume(_ record: StudyNoteGeneration, pdfURL: URL) -> Bool {
        canResume(record) && StudyNoteCheckpointStore.hasRecoverableCheckpoint(
            taskID: record.id,
            pdfURL: pdfURL
        )
    }
}

@MainActor
final class StudyNoteCoordinator: ObservableObject {
    @Published var isPresenting = false
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var previewText = ""
    @Published private(set) var completedParts = 0
    @Published private(set) var totalParts = 0
    @Published private(set) var cachedInputTokens = 0
    @Published private(set) var estimatedCostUSD = 0.0
    @Published private(set) var cacheStatusText: String?
    @Published var errorText: String?
    @Published private(set) var downloadedURL: URL?

    private var task: Task<Void, Never>?
    private var ticket: UUID?
    private let fileStore = StudyNoteFileStore()

    func generate(work: Work, pdfURL: URL, modelContext: ModelContext) {
        guard !isGenerating else { return }
        isPresenting = true
        let outputURL = LiteratureCompanionPaths.noteURL(for: pdfURL, kind: .study)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            errorText = "精读笔记已经存在，未调用人工智能，也没有覆盖现有内容。"
            return
        }
        guard LocalAPIKeyStore.shared.readIfAvailable()?.isEmpty == false else {
            errorText = GeminiAnalysisError.missingAPIKey.localizedDescription
            return
        }
        let recordID = UUID()
        let record = StudyNoteGeneration(
            id: recordID,
            draftFilename: "\(recordID.uuidString).md"
        )
        work.studyNoteGenerations.append(record)
        isGenerating = true
        statusText = "正在建立精读笔记草稿…"
        task = Task { [self] in
            do {
                try await fileStore.initialize(
                    taskID: record.id,
                    workID: work.id,
                    pdfSHA256: work.preferredFileVersion?.sha256 ?? "",
                    modelName: record.modelName,
                    promptVersion: "study-note-v2",
                    title: work.title,
                    pdfURL: pdfURL
                )
                try Task.checkCancellation()
                try modelContext.save()
                task = nil
                isGenerating = false
                start(
                    record: record,
                    work: work,
                    pdfURL: pdfURL,
                    resume: nil,
                    initialDraft: "",
                    modelContext: modelContext
                )
            } catch {
                modelContext.rollback()
                await fileStore.remove(taskID: record.id, pdfURL: pdfURL)
                isGenerating = false
                task = nil
                errorText = error is CancellationError
                    ? "已取消建立精读笔记。"
                    : "建立精读笔记草稿失败：\(error.localizedDescription)"
            }
        }
    }

    func resume(
        work: Work,
        record: StudyNoteGeneration,
        pdfURL: URL,
        modelContext: ModelContext
    ) {
        guard !isGenerating else { return }
        isPresenting = true
        guard StudyNoteResumeRules.canResume(record) else {
            errorText = "这条精读任务没有可继续的进度。"
            return
        }
        let outputURL = LiteratureCompanionPaths.noteURL(for: pdfURL, kind: .study)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            errorText = "完整精读笔记已经存在，未继续生成，也没有覆盖现有内容。"
            return
        }
        guard LocalAPIKeyStore.shared.readIfAvailable()?.isEmpty == false else {
            errorText = GeminiAnalysisError.missingAPIKey.localizedDescription
            return
        }
        isGenerating = true
        statusText = "正在读取精读检查点…"
        task = Task { [self] in
            do {
                let recovered = try await fileStore.load(
                    taskID: record.id,
                    workID: work.id,
                    pdfSHA256: work.preferredFileVersion?.sha256 ?? "",
                    pdfURL: pdfURL
                )
                try Task.checkCancellation()
                record.completedParts = recovered.checkpoint.completedParts
                record.totalParts = recovered.checkpoint.totalParts
                record.status = "queued"
                record.errorMessage = nil
                record.completedAt = nil
                try modelContext.save()
                task = nil
                isGenerating = false
                start(
                    record: record,
                    work: work,
                    pdfURL: pdfURL,
                    resume: StudyNoteResumeContext(
                        outline: recovered.checkpoint.outline,
                        completedParts: recovered.checkpoint.completedParts,
                        totalParts: recovered.checkpoint.totalParts,
                        existingDraft: recovered.draft
                    ),
                    initialDraft: recovered.draft,
                    modelContext: modelContext
                )
            } catch {
                modelContext.rollback()
                isGenerating = false
                task = nil
                errorText = error is CancellationError
                    ? "已取消继续精读。"
                    : "无法读取精读检查点：\(error.localizedDescription)"
            }
        }
    }

    private func start(
        record: StudyNoteGeneration,
        work: Work,
        pdfURL: URL,
        resume: StudyNoteResumeContext?,
        initialDraft: String,
        modelContext: ModelContext
    ) {
        guard let apiKey = LocalAPIKeyStore.shared.readIfAvailable(), !apiKey.isEmpty else {
            errorText = GeminiAnalysisError.missingAPIKey.localizedDescription
            return
        }
        isGenerating = true
        errorText = nil
        statusText = resume == nil ? "正在排队…" : "正在排队继续精读…"
        previewText = initialDraft
        completedParts = resume?.completedParts ?? 0
        totalParts = resume?.totalParts ?? 0
        cachedInputTokens = record.cachedInputTokens
        estimatedCostUSD = record.estimatedCostUSD
        cacheStatusText = nil
        downloadedURL = nil
        let ticket = UUID()
        self.ticket = ticket

        task = Task { [self] in
            let acquired = await AIRequestGate.shared.acquire(ticket)
            defer { Task { await AIRequestGate.shared.release(ticket) } }
            guard acquired, !Task.isCancelled else {
                await finishCancelled(record: record, pdfURL: pdfURL, modelContext: modelContext)
                return
            }
            do {
                let defaults = UserDefaults.standard
                let budget = defaults.double(forKey: "monthlyAIBudgetUSD")
                let spent = try monthlySpent(modelContext: modelContext)
                guard budget <= 0 || spent < budget else { throw StudyNoteError.budgetExceeded }
                record.status = "running"
                try modelContext.save()
                let pricing = StudyNotePricing(
                    liteInput: defaults.object(forKey: "aiInputPricePerMillionUSD") == nil
                        ? 0.30 : defaults.double(forKey: "aiInputPricePerMillionUSD"),
                    liteCachedInput: defaults.object(forKey: "aiCachedInputPricePerMillionUSD") == nil
                        ? 0.03 : defaults.double(forKey: "aiCachedInputPricePerMillionUSD"),
                    liteOutput: defaults.object(forKey: "aiOutputPricePerMillionUSD") == nil
                        ? 2.50 : defaults.double(forKey: "aiOutputPricePerMillionUSD"),
                    regularInput: defaults.object(forKey: "studyNoteRegularInputPricePerMillionUSD") == nil
                        ? 2.0 : defaults.double(forKey: "studyNoteRegularInputPricePerMillionUSD"),
                    regularCachedInput: defaults.object(forKey: "studyNoteRegularCachedInputPricePerMillionUSD") == nil
                        ? 0.20 : defaults.double(forKey: "studyNoteRegularCachedInputPricePerMillionUSD"),
                    regularOutput: defaults.object(forKey: "studyNoteRegularOutputPricePerMillionUSD") == nil
                        ? 12.0 : defaults.double(forKey: "studyNoteRegularOutputPricePerMillionUSD"),
                    largeInput: defaults.object(forKey: "studyNoteInputPricePerMillionUSD") == nil
                        ? 4.0 : defaults.double(forKey: "studyNoteInputPricePerMillionUSD"),
                    largeCachedInput: defaults.object(forKey: "studyNoteCachedInputPricePerMillionUSD") == nil
                        ? 0.40 : defaults.double(forKey: "studyNoteCachedInputPricePerMillionUSD"),
                    largeOutput: defaults.object(forKey: "studyNoteOutputPricePerMillionUSD") == nil
                        ? 18.0 : defaults.double(forKey: "studyNoteOutputPricePerMillionUSD"),
                    cacheStoragePerMillionTokenHours: defaults.object(
                        forKey: "studyNoteCacheStoragePricePerMillionTokenHoursUSD"
                    ) == nil ? 4.50 : defaults.double(
                        forKey: "studyNoteCacheStoragePricePerMillionTokenHoursUSD"
                    )
                )
                try await GeminiStudyNoteClient(apiKey: apiKey).generate(
                    pdfURL: pdfURL,
                    resume: resume,
                    onStage: { [weak self] stage in
                        await MainActor.run {
                            self?.statusText = stage
                            if stage.hasPrefix("显式缓存不可用") || stage.hasPrefix("PDF 显式缓存已建立") {
                                self?.cacheStatusText = stage
                            }
                        }
                    },
                    onPlan: { [weak self] outline, total in
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        try await self.fileStore.savePlan(
                            outline,
                            totalParts: total,
                            taskID: record.id,
                            pdfURL: pdfURL
                        )
                    },
                    onPart: { [weak self] part, total, text, usage in
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        if part > 0 {
                            try await self.fileStore.appendPart(
                                text,
                                part: part,
                                totalParts: total,
                                taskID: record.id,
                                pdfURL: pdfURL
                            )
                        }
                        try await MainActor.run {
                            record.inputTokens += usage.inputTokens
                            record.cachedInputTokens += usage.cachedInputTokens
                            record.outputTokens += usage.outputTokens
                            record.totalTokens += usage.totalTokens
                            record.estimatedCostUSD += pricing.estimatedCostUSD(for: usage)
                            self.cachedInputTokens += usage.cachedInputTokens
                            self.estimatedCostUSD = record.estimatedCostUSD
                            if usage.cacheStorageTokenHours > 0 {
                                self.cacheStatusText = "已建立一小时 PDF 显式缓存。"
                            }
                            record.totalParts = total
                            if part > 0 {
                                record.completedParts = part
                                self.previewText += (self.previewText.isEmpty ? "" : "\n\n") + text
                                self.completedParts = part
                            }
                            self.totalParts = total
                            try modelContext.save()
                        }
                    }
                )
                try Task.checkCancellation()
                let output = try await fileStore.export(
                    taskID: record.id, pdfURL: pdfURL, incomplete: false
                )
                record.status = "completed"
                record.completedAt = .now
                record.downloadedFilename = output.lastPathComponent
                try modelContext.save()
                downloadedURL = output
                statusText = "已保存到文献所在文件夹。"
                await fileStore.remove(taskID: record.id, pdfURL: pdfURL)
            } catch is CancellationError {
                await finishCancelled(record: record, pdfURL: pdfURL, modelContext: modelContext)
            } catch {
                await finishFailed(record: record, pdfURL: pdfURL, error: error, modelContext: modelContext)
            }
            isGenerating = false
            task = nil
            self.ticket = nil
        }
    }

    func cancel() {
        task?.cancel()
        if let ticket { Task { await AIRequestGate.shared.cancel(ticket) } }
    }

    func revealDownload() {
        guard let downloadedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
    }

    func openDownload() {
        guard let downloadedURL else { return }
        _ = NSWorkspace.shared.open(downloadedURL)
    }

    private func monthlySpent(modelContext: ModelContext) throws -> Double {
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        let analyses = try modelContext.fetch(FetchDescriptor<AIAnalysis>(
            predicate: StudyNoteFetchPredicates.monthlyAnalyses(since: monthStart)
        ))
        let notes = try modelContext.fetch(FetchDescriptor<StudyNoteGeneration>(
            predicate: StudyNoteFetchPredicates.monthlyNotes(since: monthStart)
        ))
        return analyses.reduce(0) { $0 + $1.estimatedCostUSD } +
            notes.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    private func finishCancelled(record: StudyNoteGeneration, pdfURL: URL, modelContext: ModelContext) async {
        await finishIncomplete(record: record, pdfURL: pdfURL, message: "用户已取消生成。", modelContext: modelContext)
    }

    private func finishFailed(record: StudyNoteGeneration, pdfURL: URL, error: Error, modelContext: ModelContext) async {
        await finishIncomplete(record: record, pdfURL: pdfURL, message: error.localizedDescription, modelContext: modelContext)
    }

    private func finishIncomplete(record: StudyNoteGeneration, pdfURL: URL, message: String, modelContext: ModelContext) async {
        record.status = Task.isCancelled ? "cancelled" : "failed"
        record.errorMessage = message
        record.completedAt = .now
        if await fileStore.hasRecoverableCheckpoint(taskID: record.id, pdfURL: pdfURL),
           let output = try? await fileStore.export(
               taskID: record.id, pdfURL: pdfURL, incomplete: true
           ) {
            record.downloadedFilename = output.lastPathComponent
            downloadedURL = output
            statusText = "自动重试仍未成功，已保留检查点并将未完成稿保存到文献所在文件夹。"
        } else {
            statusText = message
            await fileStore.remove(taskID: record.id, pdfURL: pdfURL)
        }
        do { try modelContext.save() } catch { errorText = "保存精读笔记状态失败：\(error.localizedDescription)" }
        isGenerating = false
        task = nil
        ticket = nil
    }
}
@MainActor
enum StudyNoteRecoveryMaintenance {
    @discardableResult
    static func recoverInterruptedTasks(modelContext: ModelContext) throws -> Int {
        let tasks = try modelContext.fetch(FetchDescriptor<StudyNoteGeneration>())
        let interrupted = tasks.filter { $0.status == "queued" || $0.status == "running" }
        for task in interrupted {
            task.status = "failed"
            task.errorMessage = "上次运行在处理过程中中断。"
            task.completedAt = .now
            if StudyNoteDraftStore.hasParts(filename: task.draftFilename),
               let filename = task.work?.preferredFileVersion?.originalFilename,
               let output = try? StudyNoteDraftStore.export(
                   filename: task.draftFilename,
                   pdfFilename: filename,
                   incomplete: true
               ) {
                task.downloadedFilename = output.lastPathComponent
                StudyNoteDraftStore.remove(filename: task.draftFilename)
            }
        }
        if !interrupted.isEmpty { try modelContext.save() }
        return interrupted.count
    }
}
