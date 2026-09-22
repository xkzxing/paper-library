import CryptoKit
import SwiftData
import XCTest
@testable import PaperLibrary

final class LibraryEnhancementTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryEnhancementTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testAuthorYearReferenceListsUpToFourSurnames() {
        XCTAssertEqual(
            ArchiveRules.authorYearReference(
                authorsText: "Alice Adams; Bob Baker; Carol Clark; David Diaz",
                publicationYear: 2025
            ),
            "Adams, Baker, Clark & Diaz (2025)"
        )
        XCTAssertEqual(
            ArchiveRules.authorYearReference(
                authorsText: "Adams, Alice and Baker, Bob",
                publicationYear: 2024
            ),
            "Adams & Baker (2024)"
        )
    }

    func testAuthorYearReferenceUsesFirstFourSurnamesForFiveOrMoreAuthors() {
        XCTAssertEqual(
            ArchiveRules.authorYearReference(
                authorsText: "A One; B Two; C Three; D Four; E Five",
                publicationYear: 2025
            ),
            "One, Two, Three, Four et al (2025)"
        )
    }

    func testAuthorYearReferenceRespectsConfiguredAuthorLimit() {
        XCTAssertEqual(
            ArchiveRules.authorYearReference(
                authorsText: "Alice Adams; Bob Baker; Carol Clark; David Diaz",
                publicationYear: 2025,
                authorLimit: 2
            ),
            "Adams, Baker et al (2025)"
        )
        XCTAssertEqual(
            ArchiveRules.authorYearReference(
                authorsText: "Alice Adams; Bob Baker; Carol Clark; David Diaz; Erin Evans",
                publicationYear: 2025,
                authorLimit: 5
            ),
            "Adams, Baker, Clark, Diaz & Evans (2025)"
        )
    }

    func testAuthorYearReferenceRequiresAuthorsAndYear() {
        XCTAssertNil(
            ArchiveRules.authorYearReference(authorsText: "", publicationYear: 2025)
        )
        XCTAssertNil(
            ArchiveRules.authorYearReference(authorsText: "Alice Adams", publicationYear: nil)
        )
    }

    func testBatchBibTeXLocalPreparationExportsValidAndSkipsInvalid() throws {
        let valid = batchInput(title: "Valid", key: "Doe2024Valid")
        let invalid = BatchBibTeXInput(
            id: UUID(),
            workTitle: "Invalid",
            metadata: snapshot(title: "Invalid"),
            localEntry: nil,
            localFailureReason: "尚未确认元数据。"
        )

        let preparation = BatchBibTeXExporter.prepareLocal([valid, invalid])

        XCTAssertEqual(preparation.candidates.map(\.workTitle), ["Valid"])
        XCTAssertEqual(preparation.skipped.map(\.workTitle), ["Invalid"])
        XCTAssertEqual(preparation.skipped.first?.reason, "尚未确认元数据。")
    }

    func testBatchBibTeXOnlinePreparationReportsConflictAndFallsBackLocally() {
        let conflictInput = batchInput(title: "Local Title", key: "Doe2024Local")
        let fallbackInput = batchInput(title: "Fallback", key: "Doe2024Fallback")
        let remote = RemoteBibTeXRecord(
            entry: entry(key: "Doe2025Online", title: "Online Title"),
            metadata: BibliographicSnapshot(
                title: "Online Title",
                authorsText: "Jane Doe",
                publicationYear: 2025,
                doi: nil,
                journal: nil
            ),
            sourceName: "DOI"
        )
        let outcomes = [
            BatchBibTeXRemoteOutcome(
                workID: conflictInput.id,
                record: remote,
                failureReason: nil
            ),
            BatchBibTeXRemoteOutcome(
                workID: fallbackInput.id,
                record: nil,
                failureReason: "网络不可用"
            ),
        ]

        let preparation = BatchBibTeXExporter.prepareOnline(
            [conflictInput, fallbackInput],
            outcomes: outcomes
        )

        XCTAssertEqual(preparation.conflictCount, 1)
        XCTAssertEqual(preparation.fallbackCount, 1)
        XCTAssertEqual(preparation.candidates.first?.defaultEntry, remote.entry)
        XCTAssertTrue(preparation.candidates.last?.usedLocalFallback == true)
    }

    func testBatchBibTeXDocumentMakesDuplicateKeysUniqueAndParseable() throws {
        let first = BatchBibTeXChosenEntry(
            workID: UUID(),
            workTitle: "First",
            entry: entry(key: "Doe2024Paper", title: "First")
        )
        let second = BatchBibTeXChosenEntry(
            workID: UUID(),
            workTitle: "Second",
            entry: entry(key: "Doe2024Paper", title: "Second")
        )
        let third = BatchBibTeXChosenEntry(
            workID: UUID(),
            workTitle: "Third",
            entry: entry(key: "Doe2024Papera", title: "Third")
        )

        let document = try BatchBibTeXExporter.makeDocument(from: [first, second, third])
        let records = document.components(separatedBy: "\n\n")

        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(document.contains("@article{Doe2024Papera,"))
        XCTAssertTrue(document.contains("@article{Doe2024Paperb,"))
        XCTAssertTrue(document.contains("@article{Doe2024Paperaa,"))
        for record in records {
            XCTAssertNoThrow(try BibTeXRecordParser.parse(record))
        }
        XCTAssertTrue(document.hasSuffix("\n"))
    }

    @MainActor
    func testBatchBibTeXOnlineCoordinatorLimitsConcurrencyToThree() async {
        let fetcher = DelayedBibTeXFetcher(delay: .milliseconds(20))
        let coordinator = BatchBibTeXCoordinator(remoteFetcher: fetcher)
        let inputs = (0..<7).map {
            batchInput(title: "Paper \($0)", key: "Doe2024Paper\($0)")
        }
        let completed = expectation(description: "在线核验完成")

        coordinator.startOnlinePreparation(inputs: inputs, contactEmail: nil) { preparation in
            XCTAssertEqual(preparation.candidates.count, 7)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)

        let peakConcurrency = await fetcher.peakConcurrency()
        XCTAssertLessThanOrEqual(peakConcurrency, 3)
        XCTAssertEqual(coordinator.completedCount, 7)
        XCTAssertFalse(coordinator.isWorking)
    }

    @MainActor
    func testBatchBibTeXOnlineCoordinatorCancellationDoesNotCompleteExport() async {
        let fetcher = DelayedBibTeXFetcher(delay: .seconds(1))
        let coordinator = BatchBibTeXCoordinator(remoteFetcher: fetcher)
        let completed = expectation(description: "取消后不应完成")
        completed.isInverted = true

        coordinator.startOnlinePreparation(
            inputs: [batchInput(title: "Paper", key: "Doe2024Paper")],
            contactEmail: nil
        ) { _ in
            completed.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.cancel()
        await fulfillment(of: [completed], timeout: 0.2)

        XCTAssertFalse(coordinator.isWorking)
        XCTAssertEqual(coordinator.statusText, "已取消批量 BibTeX 核验。")
    }

    @MainActor
    func testLibraryHealthReportCountsRelocatedAndMissingFiles() async throws {
        let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
        try LibraryLayout.ensureExists(at: library)
        let movedURL = library.appending(path: "Moved/found.pdf")
        try FileManager.default.createDirectory(
            at: movedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data("test-pdf-bytes".utf8)
        try bytes.write(to: movedURL)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let schema = Schema([
            Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self,
            ReadingProject.self, AIAnalysis.self, StudyNoteGeneration.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let relocatedVersion = FileVersion(
            relativePath: "Old/found.pdf",
            originalFilename: "found.pdf",
            pageCount: 1,
            fileSize: Int64(bytes.count),
            sha256: hash
        )
        let missingVersion = FileVersion(
            relativePath: "Old/missing.pdf",
            originalFilename: "missing.pdf",
            pageCount: 1,
            fileSize: 1,
            sha256: "missing-hash"
        )
        let relocatedWork = Work(title: "Relocated", fileVersions: [relocatedVersion])
        let missingWork = Work(title: "Missing", fileVersions: [missingVersion])
        container.mainContext.insert(relocatedWork)
        container.mainContext.insert(missingWork)
        try container.mainContext.save()
        let coordinator = FileReconciliationCoordinator()

        let optionalReport = await coordinator.reconcile(
            rootURL: library,
            modelContext: container.mainContext
        )
        let report = try XCTUnwrap(optionalReport)

        XCTAssertEqual(report.checkedFileCount, 2)
        XCTAssertEqual(report.relocatedFileCount, 1)
        XCTAssertEqual(report.missingFileCount, 1)
        XCTAssertEqual(relocatedVersion.relativePath, "Moved/found.pdf")
        XCTAssertTrue(missingWork.needsReview)
        XCTAssertEqual(coordinator.lastReport, report)
        XCTAssertFalse(coordinator.isChecking)

        let restoredURL = library.appending(path: "Old/missing.pdf")
        try FileManager.default.createDirectory(
            at: restoredURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("restored".utf8).write(to: restoredURL)
        let optionalRestoredReport = await awaitReport(
            coordinator: coordinator,
            rootURL: library,
            modelContext: container.mainContext
        )
        let restoredReport = try XCTUnwrap(optionalRestoredReport)
        XCTAssertEqual(restoredReport.missingFileCount, 0)
        XCTAssertFalse(missingWork.needsReview)
        XCTAssertNil(missingWork.metadataConflictNote)
    }

    private func batchInput(title: String, key: String) -> BatchBibTeXInput {
        BatchBibTeXInput(
            id: UUID(),
            workTitle: title,
            metadata: snapshot(title: title),
            localEntry: entry(key: key, title: title),
            localFailureReason: nil
        )
    }

    private func snapshot(title: String) -> BibliographicSnapshot {
        BibliographicSnapshot(
            title: title,
            authorsText: "Jane Doe",
            publicationYear: 2024,
            doi: nil,
            journal: nil
        )
    }

    private func entry(key: String, title: String) -> BibTeXEntry {
        BibTeXEntry(
            citationKey: key,
            content: "@article{\(key),\n  author = {Doe, Jane},\n  title = {{\(title)}},\n  year = {2024}\n}\n"
        )
    }

    @MainActor
    private func awaitReport(
        coordinator: FileReconciliationCoordinator,
        rootURL: URL,
        modelContext: ModelContext
    ) async -> LibraryHealthReport? {
        await coordinator.reconcile(rootURL: rootURL, modelContext: modelContext)
    }
}

private actor DelayedBibTeXFetcher: BibTeXRemoteFetching {
    private let delay: Duration
    private var activeCount = 0
    private var maximumActiveCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func fetch(
        for local: BibliographicSnapshot,
        contactEmail: String?
    ) async throws -> RemoteBibTeXRecord {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        try await Task.sleep(for: delay)
        let key = "Doe\(local.publicationYear ?? 2024)Paper"
        return RemoteBibTeXRecord(
            entry: BibTeXEntry(
                citationKey: key,
                content: "@article{\(key),\n  author = {Doe, Jane},\n  title = {{\(local.title)}},\n  year = {\(local.publicationYear ?? 2024)}\n}\n"
            ),
            metadata: local,
            sourceName: "测试服务"
        )
    }

    func peakConcurrency() -> Int { maximumActiveCount }
}
