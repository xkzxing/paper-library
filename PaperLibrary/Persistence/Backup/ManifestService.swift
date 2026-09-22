import Foundation
import SwiftData

struct LibraryManifest: Codable, Sendable {
    static let currentSchemaVersion = 10

    let schemaVersion: Int
    let libraryID: UUID
    let exportedAt: Date
    let works: [WorkRecord]
    let categories: [CategoryRecord]?
    let tags: [TagRecord]?
    var personalMarks: [PersonalMarkRecord]? = nil
    let projects: [ProjectRecord]?
    var deletedWorkIDs: [UUID]? = nil

    struct CategoryRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let sortOrder: Int
        let colorHex: String
        let isSystemCategory: Bool
    }

    struct TagRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let colorHex: String
    }

    struct PersonalMarkRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let colorHex: String
        let backgroundColorHex: String?
        let sortOrder: Int
    }

    struct ProjectRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let dateCreated: Date
        let priorities: [String: Int]?
        let sortFieldRawValue: String?
        let sortDirectionRawValue: String?
    }

    struct WorkRecord: Codable, Sendable {
        let id: UUID
        let title: String
        let authorsText: String
        let publicationYear: Int?
        let journal: String?
        let abstractText: String?
        let doi: String?
        let nberNumber: String?
        let ssrnID: String?
        let arxivID: String?
        let repecHandle: String?
        let documentTypeRawValue: String?
        let isbn: String?
        let publisher: String?
        let dateAdded: Date
        let lastOpenedAt: Date?
        let metadataConfirmed: Bool
        let needsReview: Bool
        let metadataSource: String?
        let crossrefVerifiedDOI: String?
        let metadataConflictNote: String?
        let openAlexJournalMetricsJSON: String?
        let openAlexJournalLookupAttemptedAt: Date?
        let duplicateCandidateWorkID: UUID?
        let categoryName: String?
        let tagNames: [String]
        var personalMarkIDs: [UUID]? = nil
        let projectNames: [String]?
        let versions: [VersionRecord]
        let analyses: [AnalysisRecord]?
        let studyNotes: [StudyNoteRecord]?
    }

    struct VersionRecord: Codable, Sendable {
        let id: UUID
        let relativePath: String
        let originalFilename: String
        let pageCount: Int
        let fileSize: Int64
        let fileMetadataYear: Int?
        let sha256: String
        let textFingerprint: String?
        let hasAnnotations: Bool
        let importedAt: Date
        let versionTypeRawValue: String
        let isPreferred: Bool
        let bibliographicTitle: String?
        let bibliographicAuthorsText: String?
        let bibliographicYear: Int?
        let bibliographicJournal: String?
        let bibliographicDOI: String?
        let bibliographicMetadataSource: String?
        let bibliographicMetadataConfirmed: Bool?
    }

    struct AnalysisRecord: Codable, Sendable {
        let id: UUID
        let modelName: String
        let promptVersion: String
        let resultJSON: String?
        let status: String
        let errorMessage: String?
        let createdAt: Date
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let analyzedFileVersionID: UUID?
    }

    struct StudyNoteRecord: Codable, Sendable {
        let id: UUID
        let modelName: String
        let status: String
        let errorMessage: String?
        let createdAt: Date
        let completedAt: Date?
        let totalParts: Int
        let completedParts: Int
        let inputTokens: Int
        let cachedInputTokens: Int?
        let outputTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let draftFilename: String
        let downloadedFilename: String?
    }
}

actor ManifestStore {
    private let fileManager = FileManager.default

    func write(_ manifest: LibraryManifest, to rootURL: URL) throws {
        let backups = try LibraryPathSafety.url(
            for: ".paperlib/backups",
            inside: rootURL,
            fileManager: fileManager
        )
        let manifestURL = try LibraryPathSafety.url(
            for: ".paperlib/manifest.json",
            inside: rootURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: manifestURL.path) {
            let formatter = ISO8601DateFormatter()
            let stamp = formatter.string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = try LibraryPathSafety.url(
                for: ".paperlib/backups/manifest-\(stamp)-\(UUID().uuidString).json",
                inside: rootURL,
                fileManager: fileManager
            )
            try fileManager.copyItem(at: manifestURL, to: backupURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try pruneBackups(in: backups, keeping: 10)
    }

    func read(
        from rootURL: URL,
        expectedLibraryID: UUID? = nil
    ) throws -> LibraryManifest? {
        let primary = try LibraryPathSafety.url(
            for: ".paperlib/manifest.json",
            inside: rootURL,
            fileManager: fileManager
        )
        let backupDirectory = try LibraryPathSafety.url(
            for: ".paperlib/backups",
            inside: rootURL,
            fileManager: fileManager
        )
        var candidates: [URL] = []
        if fileManager.fileExists(atPath: primary.path) {
            candidates.append(primary)
        }
        if fileManager.fileExists(atPath: backupDirectory.path) {
            let backups = try fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.lastPathComponent.hasPrefix("manifest-") && $0.pathExtension == "json"
            }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            candidates.append(contentsOf: backups)
        }
        guard !candidates.isEmpty else { return nil }

        var lastError: Error?
        for candidate in candidates {
            do {
                let manifest = try JSONDecoder().decode(
                    LibraryManifest.self,
                    from: Data(contentsOf: candidate)
                )
                guard manifest.schemaVersion <= LibraryManifest.currentSchemaVersion else {
                    throw LibraryAccessError.unsupportedSchema(manifest.schemaVersion)
                }
                if let expectedLibraryID, manifest.libraryID != expectedLibraryID {
                    throw LibraryAccessError.identifierMismatch(
                        expected: expectedLibraryID,
                        found: manifest.libraryID
                    )
                }
                return manifest
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileReadCorruptFile)
    }

    private func pruneBackups(in directory: URL, keeping limit: Int) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix("manifest-") && $0.pathExtension == "json"
        }
        let sorted = files.sorted {
            let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        for url in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
final class ManifestCoordinator: ObservableObject {
    @Published var errorText: String?
    private let store = ManifestStore()
    private var scheduledExport: Task<Void, Never>?

    func scheduleExport(
        libraryID: UUID,
        rootURL: URL,
        works: [Work],
        categories: [Category],
        tags: [Tag],
        projects: [ReadingProject],
        personalMarks: [PersonalMark] = []
    ) {
        scheduledExport?.cancel()
        scheduledExport = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            scheduledExport = nil
            await export(
                libraryID: libraryID,
                rootURL: rootURL,
                works: works,
                categories: categories,
                tags: tags,
                projects: projects,
                personalMarks: personalMarks
            )
        }
    }

    func export(
        libraryID: UUID,
        rootURL: URL,
        works: [Work],
        categories: [Category],
        tags: [Tag],
        projects: [ReadingProject],
        personalMarks: [PersonalMark] = []
    ) async {
        scheduledExport?.cancel()
        scheduledExport = nil
        let records = works.map { work in
            LibraryManifest.WorkRecord(
                id: work.id,
                title: work.title,
                authorsText: work.authorsText,
                publicationYear: work.publicationYear,
                journal: work.journal,
                abstractText: work.abstractText,
                doi: work.doi,
                nberNumber: work.nberNumber,
                ssrnID: work.ssrnID,
                arxivID: work.arxivID,
                repecHandle: work.repecHandle,
                documentTypeRawValue: work.documentTypeRawValue,
                isbn: work.isbn,
                publisher: work.publisher,
                dateAdded: work.dateAdded,
                lastOpenedAt: work.lastOpenedAt,
                metadataConfirmed: work.metadataConfirmed,
                needsReview: work.needsReview,
                metadataSource: work.metadataSource,
                crossrefVerifiedDOI: work.crossrefVerifiedDOI,
                metadataConflictNote: work.metadataConflictNote,
                openAlexJournalMetricsJSON: work.openAlexJournalMetricsJSON,
                openAlexJournalLookupAttemptedAt: work.openAlexJournalLookupAttemptedAt,
                duplicateCandidateWorkID: work.duplicateCandidateWorkID,
                categoryName: work.primaryCategory?.name,
                tagNames: work.tags.map(\.name),
                personalMarkIDs: work.personalMarks.map(\.id),
                projectNames: work.projects.map(\.name),
                versions: work.fileVersions.map { file in
                    LibraryManifest.VersionRecord(
                        id: file.id,
                        relativePath: file.relativePath,
                        originalFilename: file.originalFilename,
                        pageCount: file.pageCount,
                        fileSize: file.fileSize,
                        fileMetadataYear: file.fileMetadataYear,
                        sha256: file.sha256,
                        textFingerprint: file.textFingerprint,
                        hasAnnotations: file.hasAnnotations,
                        importedAt: file.importedAt,
                        versionTypeRawValue: file.versionTypeRawValue,
                        isPreferred: file.isPreferred,
                        bibliographicTitle: file.bibliographicTitle,
                        bibliographicAuthorsText: file.bibliographicAuthorsText,
                        bibliographicYear: file.bibliographicYear,
                        bibliographicJournal: file.bibliographicJournal,
                        bibliographicDOI: file.bibliographicDOI,
                        bibliographicMetadataSource: file.bibliographicMetadataSource,
                        bibliographicMetadataConfirmed: file.bibliographicMetadataConfirmed
                    )
                },
                analyses: work.analyses.map { analysis in
                    LibraryManifest.AnalysisRecord(
                        id: analysis.id,
                        modelName: analysis.modelName,
                        promptVersion: analysis.promptVersion,
                        resultJSON: analysis.resultJSON,
                        status: analysis.status,
                        errorMessage: analysis.errorMessage,
                        createdAt: analysis.createdAt,
                        inputTokens: analysis.inputTokens,
                        outputTokens: analysis.outputTokens,
                        totalTokens: analysis.totalTokens,
                        estimatedCostUSD: analysis.estimatedCostUSD,
                        analyzedFileVersionID: analysis.analyzedFileVersionID
                    )
                },
                studyNotes: work.studyNoteGenerations.map { note in
                    LibraryManifest.StudyNoteRecord(
                        id: note.id,
                        modelName: note.modelName,
                        status: note.status,
                        errorMessage: note.errorMessage,
                        createdAt: note.createdAt,
                        completedAt: note.completedAt,
                        totalParts: note.totalParts,
                        completedParts: note.completedParts,
                        inputTokens: note.inputTokens,
                        cachedInputTokens: note.cachedInputTokens,
                        outputTokens: note.outputTokens,
                        totalTokens: note.totalTokens,
                        estimatedCostUSD: note.estimatedCostUSD,
                        draftFilename: note.draftFilename,
                        downloadedFilename: note.downloadedFilename
                    )
                }
            )
        }
        let manifest = LibraryManifest(
            schemaVersion: LibraryManifest.currentSchemaVersion,
            libraryID: libraryID,
            exportedAt: .now,
            works: records,
            categories: categories.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    sortOrder: $0.sortOrder,
                    colorHex: $0.colorHex,
                    isSystemCategory: $0.isSystemCategory
                )
            },
            tags: tags.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex) },
            personalMarks: personalMarks.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    colorHex: $0.colorHex,
                    backgroundColorHex: $0.backgroundColorHex,
                    sortOrder: $0.sortOrder
                )
            },
            projects: projects.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    dateCreated: $0.dateCreated,
                    priorities: $0.priorityValues,
                    sortFieldRawValue: $0.sortFieldRawValue,
                    sortDirectionRawValue: $0.sortDirectionRawValue
                )
            },
            deletedWorkIDs: DeletedWorkRegistry.all
        )
        do {
            try await store.write(manifest, to: rootURL)
        } catch {
            errorText = "写入资料库清单失败：\(error.localizedDescription)"
        }
    }

    func restoreIfNeeded(
        libraryID: UUID,
        rootURL: URL,
        modelContext: ModelContext
    ) async -> Bool {
        do {
            guard try modelContext.fetchCount(FetchDescriptor<Work>()) == 0 else { return true }
            guard let manifest = try await store.read(
                from: rootURL,
                expectedLibraryID: libraryID
            ) else { return true }

            for work in manifest.works {
                for version in work.versions {
                    _ = try LibraryPathSafety.url(
                        for: version.relativePath,
                        inside: rootURL,
                        requirePDF: true
                    )
                }
            }

            var categories = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<Category>()).map { ($0.name, $0) }
            )
            var tags = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<Tag>()).map { ($0.name, $0) }
            )
            var personalMarks = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<PersonalMark>()).map { ($0.id, $0) }
            )
            var projects = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<ReadingProject>()).map { ($0.name, $0) }
            )
            DeletedWorkRegistry.record(manifest.deletedWorkIDs ?? [])

            for record in manifest.categories ?? [] {
                if let existing = categories[record.name] {
                    existing.sortOrder = record.sortOrder
                    existing.colorHex = record.colorHex
                    existing.isSystemCategory = record.isSystemCategory
                } else {
                    let category = Category(
                        id: record.id,
                        name: record.name,
                        sortOrder: record.sortOrder,
                        colorHex: record.colorHex,
                        isSystemCategory: record.isSystemCategory
                    )
                    modelContext.insert(category)
                    categories[record.name] = category
                }
            }
            for record in manifest.tags ?? [] {
                if let existing = tags[record.name] {
                    existing.colorHex = record.colorHex
                } else {
                    let tag = Tag(id: record.id, name: record.name, colorHex: record.colorHex)
                    modelContext.insert(tag)
                    tags[record.name] = tag
                }
            }
            for record in manifest.personalMarks ?? [] {
                if let existing = personalMarks[record.id] {
                    existing.name = record.name
                    existing.colorHex = record.colorHex
                    existing.backgroundColorHex = record.backgroundColorHex
                    existing.sortOrder = record.sortOrder
                } else {
                    let mark = PersonalMark(
                        id: record.id,
                        name: record.name,
                        colorHex: record.colorHex,
                        backgroundColorHex: record.backgroundColorHex,
                        sortOrder: record.sortOrder
                    )
                    modelContext.insert(mark)
                    personalMarks[record.id] = mark
                }
            }
            for record in manifest.projects ?? [] {
                if projects[record.name] == nil {
                    let project = ReadingProject(
                        id: record.id,
                        name: record.name,
                        dateCreated: record.dateCreated,
                        sortFieldRawValue: record.sortFieldRawValue,
                        sortDirectionRawValue: record.sortDirectionRawValue
                    )
                    project.restorePriorityValues(record.priorities ?? [:])
                    modelContext.insert(project)
                    projects[record.name] = project
                } else if let existing = projects[record.name] {
                    existing.sortFieldRawValue = record.sortFieldRawValue
                    existing.sortDirectionRawValue = record.sortDirectionRawValue
                    existing.restorePriorityValues(record.priorities ?? [:])
                }
            }

            for record in manifest.works {
                guard !DeletedWorkRegistry.contains(record.id) else { continue }
                let category: Category?
                if let name = record.categoryName {
                    if let existing = categories[name] {
                        category = existing
                    } else {
                        let created = Category(name: name, sortOrder: categories.count)
                        modelContext.insert(created)
                        categories[name] = created
                        category = created
                    }
                } else {
                    category = categories["Uncategorized"]
                }

                let work = Work(
                    id: record.id,
                    title: record.title,
                    authorsText: record.authorsText,
                    publicationYear: record.publicationYear,
                    journal: record.journal,
                    abstractText: record.abstractText,
                    doi: record.doi,
                    nberNumber: record.nberNumber,
                    ssrnID: record.ssrnID,
                    arxivID: record.arxivID,
                    repecHandle: record.repecHandle,
                    documentTypeRawValue: record.documentTypeRawValue,
                    isbn: record.isbn,
                    publisher: record.publisher,
                    dateAdded: record.dateAdded,
                    lastOpenedAt: record.lastOpenedAt,
                    metadataConfirmed: record.metadataConfirmed,
                    needsReview: record.needsReview,
                    duplicateCandidateWorkID: record.duplicateCandidateWorkID,
                    metadataSource: record.metadataSource ?? "pdf",
                    crossrefVerifiedDOI: record.crossrefVerifiedDOI,
                    metadataConflictNote: record.metadataConflictNote,
                    openAlexJournalMetricsJSON: record.openAlexJournalMetricsJSON,
                    openAlexJournalLookupAttemptedAt: record.openAlexJournalLookupAttemptedAt,
                    primaryCategory: category
                )
                for tagName in record.tagNames {
                    let tag: Tag
                    if let existing = tags[tagName] {
                        tag = existing
                    } else {
                        tag = Tag(name: tagName)
                        modelContext.insert(tag)
                        tags[tagName] = tag
                    }
                    work.tags.append(tag)
                }
                for markID in record.personalMarkIDs ?? [] {
                    if let mark = personalMarks[markID] {
                        work.personalMarks.append(mark)
                    }
                }
                for projectName in record.projectNames ?? [] {
                    let project: ReadingProject
                    if let existing = projects[projectName] {
                        project = existing
                    } else {
                        project = ReadingProject(name: projectName)
                        modelContext.insert(project)
                        projects[projectName] = project
                    }
                    work.projects.append(project)
                }
                for version in record.versions {
                    work.fileVersions.append(FileVersion(
                        id: version.id,
                        relativePath: version.relativePath,
                        originalFilename: version.originalFilename,
                        pageCount: version.pageCount,
                        fileSize: version.fileSize,
                        fileMetadataYear: version.fileMetadataYear,
                        sha256: version.sha256,
                        textFingerprint: version.textFingerprint,
                        hasAnnotations: version.hasAnnotations,
                        importedAt: version.importedAt,
                        versionTypeRawValue: version.versionTypeRawValue,
                        isPreferred: version.isPreferred,
                        bibliographicTitle: version.bibliographicTitle,
                        bibliographicAuthorsText: version.bibliographicAuthorsText,
                        bibliographicYear: version.bibliographicYear,
                        bibliographicJournal: version.bibliographicJournal,
                        bibliographicDOI: version.bibliographicDOI,
                        bibliographicMetadataSource: version.bibliographicMetadataSource,
                        bibliographicMetadataConfirmed: version.bibliographicMetadataConfirmed ?? false
                    ))
                }
                for analysis in record.analyses ?? [] {
                    let interrupted = analysis.status == "queued" || analysis.status == "running"
                    work.analyses.append(AIAnalysis(
                        id: analysis.id,
                        modelName: analysis.modelName,
                        promptVersion: analysis.promptVersion,
                        resultJSON: analysis.resultJSON,
                        status: interrupted ? "failed" : analysis.status,
                        errorMessage: interrupted
                            ? "上次运行在处理过程中中断，请重新分析。"
                            : analysis.errorMessage,
                        createdAt: analysis.createdAt,
                        inputTokens: analysis.inputTokens,
                        outputTokens: analysis.outputTokens,
                        totalTokens: analysis.totalTokens,
                        estimatedCostUSD: analysis.estimatedCostUSD,
                        analyzedFileVersionID: analysis.analyzedFileVersionID
                    ))
                    if interrupted {
                        work.needsReview = true
                        if work.metadataConflictNote == nil {
                            work.metadataConflictNote = "AI 处理因上次运行中断而未完成。"
                        }
                    }
                }
                for note in record.studyNotes ?? [] {
                    let interrupted = note.status == "queued" || note.status == "running"
                    work.studyNoteGenerations.append(StudyNoteGeneration(
                        id: note.id,
                        modelName: note.modelName,
                        status: interrupted ? "failed" : note.status,
                        errorMessage: interrupted
                            ? "上次运行在处理过程中中断。"
                            : note.errorMessage,
                        createdAt: note.createdAt,
                        completedAt: note.completedAt,
                        totalParts: note.totalParts,
                        completedParts: note.completedParts,
                        inputTokens: note.inputTokens,
                        cachedInputTokens: note.cachedInputTokens ?? 0,
                        outputTokens: note.outputTokens,
                        totalTokens: note.totalTokens,
                        estimatedCostUSD: note.estimatedCostUSD,
                        draftFilename: note.draftFilename,
                        downloadedFilename: note.downloadedFilename
                    ))
                }
                modelContext.insert(work)
            }
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            errorText = "从资料库清单恢复失败：\(error.localizedDescription)"
            return false
        }
    }
}
