import GRDB
import XCTest
@testable import PaperLibrary

final class SearchEngineTests: XCTestCase {
    func testUnitTestHostUsesIsolatedRuntime() {
        XCTAssertTrue(AppRuntimeEnvironment.isRunningTests)
    }

    func testPDFChunksKeepPhysicalPageNumbersAndOverlap() throws {
        let workID = UUID()
        let versionID = UUID()
        let chunks = PDFTextExtractor.makeChunks(
            pageTexts: [
                (1, String(repeating: "第一页中的制度分析。", count: 40)),
                (2, String(repeating: "第二页中的识别策略。", count: 40)),
                (3, String(repeating: "第三页中的稳健性检验。", count: 40)),
            ],
            workID: workID,
            fileVersionID: versionID,
            targetLength: 220,
            maximumLength: 360,
            overlapLength: 80
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startPage, 1)
        XCTAssertEqual(chunks.last?.endPage, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.workID == workID && $0.fileVersionID == versionID })
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
    }

    func testChineseSearchTextContainsBigrams() {
        let searchable = PDFTextExtractor.searchable("财政政策影响企业投资")
        XCTAssertTrue(searchable.contains("财政"))
        XCTAssertTrue(searchable.contains("企业"))
    }

    func testPDFChunkingReconnectsWordsAcrossWindowsLineEndings() {
        let chunks = PDFTextExtractor.makeChunks(
            pageTexts: [(1, "inter-\r\nnational trade")],
            workID: UUID(),
            fileVersionID: UUID()
        )
        XCTAssertEqual(chunks.first?.text, "international trade")
    }

    func testReciprocalRankFusionRewardsAgreement() {
        let scores = SearchFusion.reciprocalRankFusion(rankings: [
            ["shared", "keyword-only"],
            ["shared", "semantic-only"],
        ])
        XCTAssertGreaterThan(scores["shared"] ?? 0, scores["keyword-only"] ?? 0)
        XCTAssertGreaterThan(scores["shared"] ?? 0, scores["semantic-only"] ?? 0)
    }

    func testSmartSearchFusesAtWorkLevelAndRewardsCrossChannelAgreement() {
        let shared = UUID()
        let keywordOnly = UUID()
        let semanticOnly = UUID()
        let ranking = SmartSearchCandidateBuilder.fusedWorkRanking(
            keyword: [shared, shared, keywordOnly],
            semantic: [shared, semanticOnly],
            metadata: [],
            limit: 10
        )

        XCTAssertEqual(ranking.first?.workID, shared)
        XCTAssertEqual(ranking.map(\.workID).filter { $0 == shared }.count, 1)
        XCTAssertEqual(Set(ranking.map(\.workID)), [shared, keywordOnly, semanticOnly])
    }

    func testRerankCandidateSelectionPrioritizesOnePassagePerWork() {
        let firstWork = UUID()
        let secondWork = UUID()
        let thirdWork = UUID()
        let works = [
            SmartSearchWorkCandidate(
                workID: firstWork,
                fusionScore: 3,
                passages: [
                    makeRerankCandidate(id: "a1", workID: firstWork, text: "aaaaaaaaaa"),
                    makeRerankCandidate(id: "a2", workID: firstWork, text: "aaaaaaaaaa"),
                ]
            ),
            SmartSearchWorkCandidate(
                workID: secondWork,
                fusionScore: 2,
                passages: [makeRerankCandidate(id: "b1", workID: secondWork, text: "bbbbbbbbbb")]
            ),
            SmartSearchWorkCandidate(
                workID: thirdWork,
                fusionScore: 1,
                passages: [makeRerankCandidate(id: "c1", workID: thirdWork, text: "cccccccccc")]
            ),
        ]

        let selected = SmartSearchCandidateBuilder.selectRerankCandidates(
            works: works,
            passageLimit: 4,
            characterBudget: 40
        )
        XCTAssertEqual(selected.map(\.id), ["a1", "b1", "c1", "a2"])

        let budgeted = SmartSearchCandidateBuilder.selectRerankCandidates(
            works: works,
            passageLimit: 4,
            characterBudget: 20
        )
        XCTAssertEqual(budgeted.map(\.id), ["a1", "b1"])

        let openingReserved = SmartSearchCandidateBuilder.selectRerankCandidates(
            works: works,
            passageLimit: 4,
            characterBudget: 40,
            prioritySecondaryCount: 1
        )
        XCTAssertEqual(openingReserved.map(\.id), ["a1", "a2", "b1", "c1"])
    }

    func testDisplayPassagePrefersStrongOpeningWithoutChangingBestScore() {
        let ordered = SmartSearchPassageSelector.displayOrder([
            .init(id: "page-32", rawScore: 0.91, startPage: 32),
            .init(id: "page-1", rawScore: 0.84, startPage: 1),
        ])

        XCTAssertEqual(ordered, ["page-1", "page-32"])
    }

    func testDisplayPassageKeepsClearlyStrongerLaterMatch() {
        let ordered = SmartSearchPassageSelector.displayOrder([
            .init(id: "page-32", rawScore: 0.91, startPage: 32),
            .init(id: "page-1", rawScore: 0.40, startPage: 1),
        ])

        XCTAssertEqual(ordered, ["page-32", "page-1"])
    }

    func testSmartSearchDepthAndResultDefaultsAreStable() {
        XCTAssertEqual(SmartSearchDepth.fast.channelLimit, 100)
        XCTAssertEqual(SmartSearchDepth.balanced.fusedWorkLimit, 60)
        XCTAssertEqual(SmartSearchDepth.deep.rerankPassageLimit, 120)
        XCTAssertEqual(SmartSearchDepth.deep.characterBudget, 110_000)
        XCTAssertEqual(SmartSearchPreferences().resultLimit, 10)
        XCTAssertEqual(SmartSearchPreferences(depth: .deep, resultLimit: 20).resultLimit, 20)
        XCTAssertEqual(SmartSearchPreferences(depth: .fast, resultLimit: 999).resultLimit, 10)
    }

    func testWorkLevelFusionKeepsDiversityAtFiveThousandWorkScale() {
        let workIDs = (0..<5_000).map { _ in UUID() }
        let hundredThousandChunkHits = (0..<100_000).map { workIDs[$0 % workIDs.count] }
        let semantic = Array(workIDs.reversed())
        let fused = SmartSearchCandidateBuilder.fusedWorkRanking(
            keyword: hundredThousandChunkHits,
            semantic: semantic,
            metadata: Array(workIDs.prefix(500)),
            limit: SmartSearchDepth.deep.fusedWorkLimit
        )

        XCTAssertEqual(fused.count, SmartSearchDepth.deep.fusedWorkLimit)
        XCTAssertEqual(Set(fused.map(\.workID)).count, fused.count)
    }

    func testKeywordSearchAppliesScopeAndPerWorkPassageLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryScopedKeywordTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        let firstWork = UUID()
        let secondWork = UUID()
        let excludedWork = UUID()

        for (workID, count) in [(firstWork, 8), (secondWork, 1), (excludedWork, 1)] {
            let versionID = UUID()
            let snapshot = SearchDocumentSnapshot(
                workID: workID, title: "检索测试", authors: "作者", abstractText: nil,
                publicationYear: 2026, doi: nil, duplicateCandidateWorkID: nil,
                fileVersionID: versionID, relativePath: "\(workID).pdf", sha256: workID.uuidString
            )
            let chunks = (0..<count).map { ordinal in
                SearchTextChunk(
                    id: "\(versionID.uuidString):\(ordinal)", workID: workID,
                    fileVersionID: versionID, ordinal: ordinal, startPage: ordinal + 1,
                    endPage: ordinal + 1, text: "融资约束候选段落 \(ordinal)",
                    searchableText: PDFTextExtractor.searchable("融资约束候选段落 \(ordinal)")
                )
            }
            try await store.replaceDocument(snapshot, chunks: chunks)
        }

        let hits = try await store.keywordSearch(
            "融资约束",
            limit: 20,
            allowedWorkIDs: [firstWork, secondWork],
            maximumHitsPerWork: 2
        )
        XCTAssertEqual(hits.filter { $0.chunk.workID == firstWork }.count, 2)
        XCTAssertEqual(hits.filter { $0.chunk.workID == secondWork }.count, 1)
        XCTAssertFalse(hits.contains { $0.chunk.workID == excludedWork })
        let scopedMissing = try await store.documentsMissingEmbeddings(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature,
            allowedWorkIDs: [firstWork, secondWork]
        )
        let emptyScopeMissing = try await store.documentsMissingEmbeddings(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature,
            allowedWorkIDs: []
        )
        XCTAssertEqual(scopedMissing, 2)
        XCTAssertEqual(emptyScopeMissing, 0)
    }

    func testFirstChunkLookupReturnsOpeningPassageForEachWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryFirstChunkTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        let workID = UUID()
        let versionID = UUID()
        let snapshot = SearchDocumentSnapshot(
            workID: workID, title: "文章开头", authors: "作者", abstractText: nil,
            publicationYear: 2026, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: versionID, relativePath: "opening.pdf", sha256: "opening"
        )
        let later = SearchTextChunk(
            id: "later", workID: workID, fileVersionID: versionID, ordinal: 8,
            startPage: 32, endPage: 32, text: "后文", searchableText: "后文"
        )
        let opening = SearchTextChunk(
            id: "opening", workID: workID, fileVersionID: versionID, ordinal: 0,
            startPage: 1, endPage: 2, text: "开头", searchableText: "开头"
        )
        try await store.replaceDocument(snapshot, chunks: [later, opening])

        let firstChunks = try await store.firstChunkIDs(workIDs: [workID])

        XCTAssertEqual(firstChunks[workID], opening.id)
    }

    func testSearchIndexPersistsKeywordHitsAndHalfPrecisionVectors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workID = UUID()
        let versionID = UUID()
        let snapshot = SearchDocumentSnapshot(
            workID: workID,
            title: "地方财政与企业投资",
            authors: "测试作者",
            abstractText: nil,
            publicationYear: 2024,
            doi: "10.1000/test",
            duplicateCandidateWorkID: nil,
            fileVersionID: versionID,
            relativePath: "文章/原文.pdf",
            sha256: "abc"
        )
        let chunk = SearchTextChunk(
            id: "\(versionID.uuidString):0",
            workID: workID,
            fileVersionID: versionID,
            ordinal: 0,
            startPage: 7,
            endPage: 7,
            text: "财政政策会通过融资约束影响企业投资。",
            searchableText: PDFTextExtractor.searchable("财政政策会通过融资约束影响企业投资。")
        )
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        try await store.replaceDocument(snapshot, chunks: [chunk])

        let hits = try await store.keywordSearch("融资约束")
        XCTAssertEqual(hits.first?.chunk.workID, workID)
        XCTAssertEqual(hits.first?.chunk.startPage, 7)

        let vector = (0..<LocalSearchProfile.balanced.dimensions).map { Float($0) / 2_560 }
        try await store.saveEmbeddings([vector], for: [chunk], profile: .balanced)
        let stored = try await store.allEmbeddedChunks(signature: LocalSearchProfile.balanced.vectorSpaceSignature)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].vector?.count, 2_560)
        XCTAssertEqual(stored[0].vector?[500] ?? 0, vector[500], accuracy: 0.001)

        let balancedStored = try await store.allEmbeddedChunks(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature
        )
        XCTAssertEqual(balancedStored.first?.vector?.count, 2_560)

        try await store.removeDocuments(workIDs: [workID])
        let remainingBalancedChunks = try await store.allEmbeddedChunks(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature
        )
        let remainingKeywordHits = try await store.keywordSearch("融资约束")
        XCTAssertTrue(remainingBalancedChunks.isEmpty)
        XCTAssertTrue(remainingKeywordHits.isEmpty)
    }

    func testSemanticScanKeepsOnlyHighestScoringCandidatesAndLoadsTextOnDemand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryBoundedSearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        var chunks: [SearchTextChunk] = []
        var vectors: [[Float]] = []

        for ordinal in 0..<6 {
            let workID = UUID()
            let versionID = UUID()
            let chunk = SearchTextChunk(
                id: "\(versionID.uuidString):0",
                workID: workID,
                fileVersionID: versionID,
                ordinal: 0,
                startPage: 1,
                endPage: 1,
                text: "候选 \(ordinal)",
                searchableText: "候选 \(ordinal)"
            )
            let snapshot = SearchDocumentSnapshot(
                workID: workID,
                title: "候选 \(ordinal)",
                authors: "作者",
                abstractText: nil,
                publicationYear: nil,
                doi: nil,
                duplicateCandidateWorkID: nil,
                fileVersionID: versionID,
                relativePath: "\(ordinal).pdf",
                sha256: "hash-\(ordinal)"
            )
            try await store.replaceDocument(snapshot, chunks: [chunk])
            var vector = Array(repeating: Float.zero, count: LocalSearchProfile.balanced.dimensions)
            vector[0] = Float(ordinal) / 5
            chunks.append(chunk)
            vectors.append(vector)
        }
        try await store.saveEmbeddings(vectors, for: chunks, profile: .balanced)
        var query = Array(repeating: Float.zero, count: LocalSearchProfile.balanced.dimensions)
        query[0] = 1

        let candidates = try await store.topSemanticCandidates(
            queryVector: query,
            signature: LocalSearchProfile.balanced.vectorSpaceSignature,
            limit: 2
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertGreaterThanOrEqual(candidates[0].score, candidates[1].score)
        XCTAssertEqual(Set(candidates.map(\.chunkID)), Set(chunks.suffix(2).map(\.id)))

        let loaded = try await store.chunks(ids: Set(candidates.map(\.chunkID)))
        XCTAssertEqual(Set(loaded.map(\.id)), Set(candidates.map(\.chunkID)))

        let allowedIDs = Set(chunks.prefix(3).map(\.workID))
        let scoped = try await store.topSemanticCandidates(
            queryVector: query,
            signature: LocalSearchProfile.balanced.vectorSpaceSignature,
            limit: 6,
            allowedWorkIDs: allowedIDs,
            maximumHitsPerWork: 2
        )
        XCTAssertEqual(Set(scoped.map(\.workID)), allowedIDs)
    }

    func testEmbeddingFailuresAreSkippedUntilExplicitRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workID = UUID()
        let versionID = UUID()
        let snapshot = SearchDocumentSnapshot(
            workID: workID,
            title: "测试文献",
            authors: "测试作者",
            abstractText: nil,
            publicationYear: nil,
            doi: nil,
            duplicateCandidateWorkID: nil,
            fileVersionID: versionID,
            relativePath: "文章/原文.pdf",
            sha256: "failure"
        )
        let chunk = SearchTextChunk(
            id: "\(versionID.uuidString):0",
            workID: workID,
            fileVersionID: versionID,
            ordinal: 0,
            startPage: 1,
            endPage: 1,
            text: "用于测试的正文。",
            searchableText: PDFTextExtractor.searchable("用于测试的正文。")
        )
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        try await store.replaceDocument(snapshot, chunks: [chunk])
        try await store.recordEmbeddingFailure(profile: .balanced, chunk: chunk, message: "测试失败")

        let chunksBeforeRetry = try await store.chunksNeedingEmbedding(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature
        )
        XCTAssertTrue(chunksBeforeRetry.isEmpty)
        try await store.clearEmbeddingFailures(profile: .balanced)
        let chunksAfterRetry = try await store.chunksNeedingEmbedding(
            signature: LocalSearchProfile.balanced.vectorSpaceSignature
        )
        XCTAssertEqual(chunksAfterRetry.count, 1)
    }

    func testSuccessfulTextIndexPassCanClearStaleGlobalFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchGlobalFailureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)

        try await store.recordGlobalFailure(
            stage: .textExtraction,
            modelSignature: nil,
            message: "database is locked"
        )
        let failuresBeforeClearing = try await store.failures()
        XCTAssertEqual(failuresBeforeClearing.count, 1)

        try await store.clearGlobalFailures(stage: .textExtraction)
        let failuresAfterClearing = try await store.failures()
        XCTAssertTrue(failuresAfterClearing.isEmpty)
    }

    func testTextIndexPreflightOnlyReturnsNewOrChangedDocuments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchPreflightTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SearchIndexStore(libraryID: UUID(), baseDirectory: directory)
        let existing = SearchDocumentSnapshot(
            workID: UUID(), title: "已有文献", authors: "甲", abstractText: nil,
            publicationYear: 2025, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "已有文献.pdf", sha256: "existing"
        )
        try await store.replaceDocument(existing, chunks: [])

        let unchanged = try await store.snapshotsNeedingTextIndex([existing])
        XCTAssertTrue(unchanged.isEmpty)

        let changed = SearchDocumentSnapshot(
            workID: existing.workID, title: existing.title, authors: existing.authors,
            abstractText: nil, publicationYear: 2025, doi: nil,
            duplicateCandidateWorkID: nil, fileVersionID: existing.fileVersionID,
            relativePath: existing.relativePath, sha256: "changed"
        )
        let newDocument = SearchDocumentSnapshot(
            workID: UUID(), title: "新增文献", authors: "乙", abstractText: nil,
            publicationYear: 2026, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "新增文献.pdf", sha256: "new"
        )
        let pending = try await store.snapshotsNeedingTextIndex([changed, newDocument])
        XCTAssertEqual(Set(pending.map(\.workID)), Set([changed.workID, newDocument.workID]))
    }

    func testCloudRerankerConfigurationUsesQwenThreePointSeven() {
        XCTAssertEqual(LocalSearchConfiguration.rerankerModelID, "qwen3.7-text-rerank")
        XCTAssertEqual(LocalSearchConfiguration.rerankerRevision, "cn-beijing-maas-v1")
    }

    func testLegacyVectorMigratesUnderItsLegacySignatureWithoutBeingLost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryID = UUID()
        let databaseURL = try makeSearchDatabaseURL(baseDirectory: directory, libraryID: libraryID)
        let workID = UUID()
        let versionID = UUID()
        let chunkID = "\(versionID.uuidString):0"
        let vector = (0..<LocalSearchConfiguration.legacyFastDimensions).map { Float($0) / 1_024 }

        do {
            let database = try DatabaseQueue(path: databaseURL.path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("search-v1") { db in
                try self.createLegacySearchSchema(in: db)
            }
            try migrator.migrate(database)
            try await database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO documents
                        (work_id, file_version_id, relative_path, sha256, chunk_schema, status, updated_at)
                        VALUES (?, ?, 'article.pdf', 'legacy', 1, 'ready', ?)
                        """,
                    arguments: [workID.uuidString, versionID.uuidString, Date()]
                )
                try db.execute(
                    sql: """
                        INSERT INTO chunks
                        (id, work_id, file_version_id, ordinal, start_page, end_page,
                         text, searchable_text, vector, vector_signature)
                        VALUES (?, ?, ?, 0, 1, 1, '历史正文', '历史 正文', ?, 'legacy-signature')
                        """,
                    arguments: [
                        chunkID, workID.uuidString, versionID.uuidString,
                        encodedHalfPrecisionVector(vector),
                    ]
                )
            }
        }

        let store = try SearchIndexStore(libraryID: libraryID, baseDirectory: directory)
        let migrated = try await store.allEmbeddedChunks(
            signature: LocalSearchConfiguration.legacyFastVectorSpaceSignature
        )
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].vector?.count, LocalSearchConfiguration.legacyFastDimensions)
        XCTAssertEqual(migrated[0].vector?[500] ?? 0, vector[500], accuracy: 0.001)
    }

    func testLegacyFourBVectorsAndFailuresAreRemovedWithoutTouchingCurrentVectors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryLegacyFourBVectorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryID = UUID()
        let store = try SearchIndexStore(libraryID: libraryID, baseDirectory: directory)
        let databaseURL = try makeSearchDatabaseURL(baseDirectory: directory, libraryID: libraryID)
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            for signature in [
                LocalSearchConfiguration.legacyBalancedVectorSpaceSignature,
                LocalSearchProfile.balanced.vectorSpaceSignature,
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO chunk_vectors
                        (chunk_id, model_signature, dimensions, vector, updated_at)
                        VALUES (?, ?, 1, ?, ?)
                        """,
                    arguments: [
                        "\(signature):chunk",
                        signature,
                        encodedHalfPrecisionVector([1]),
                        Date(),
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO search_failures
                        (id, stage, model_signature, message, occurred_at)
                        VALUES (?, 'embedding', ?, '测试', ?)
                        """,
                    arguments: ["\(signature):failure", signature, Date()]
                )
            }
        }

        try await store.removeVectors(
            signature: LocalSearchConfiguration.legacyBalancedVectorSpaceSignature
        )

        let legacyVectorCount = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chunk_vectors WHERE model_signature = ?",
                arguments: [LocalSearchConfiguration.legacyBalancedVectorSpaceSignature]
            ) ?? -1
        }
        let legacyFailureCount = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM search_failures WHERE model_signature = ?",
                arguments: [LocalSearchConfiguration.legacyBalancedVectorSpaceSignature]
            ) ?? -1
        }
        let currentVectorCount = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chunk_vectors WHERE model_signature = ?",
                arguments: [LocalSearchProfile.balanced.vectorSpaceSignature]
            ) ?? -1
        }
        XCTAssertEqual(legacyVectorCount, 0)
        XCTAssertEqual(legacyFailureCount, 0)
        XCTAssertEqual(currentVectorCount, 1)
    }

    func testStartupReconciliationRemovesOrphanedVectorsAndFailures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibrarySearchOrphanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryID = UUID()
        let store = try SearchIndexStore(libraryID: libraryID, baseDirectory: directory)
        let databaseURL = try makeSearchDatabaseURL(baseDirectory: directory, libraryID: libraryID)
        let orphanWorkID = UUID()

        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chunk_vectors
                    (chunk_id, model_signature, dimensions, vector, updated_at)
                    VALUES ('orphan:0', ?, 1, ?, ?)
                    """,
                arguments: [
                    LocalSearchProfile.balanced.vectorSpaceSignature,
                    encodedHalfPrecisionVector([1]),
                    Date(),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_failures
                    (id, stage, model_signature, work_id, chunk_id, message, occurred_at)
                    VALUES ('orphan-failure', 'embedding', ?, ?, 'orphan:0', '孤立记录', ?)
                    """,
                arguments: [
                    LocalSearchProfile.balanced.vectorSpaceSignature,
                    orphanWorkID.uuidString,
                    Date(),
                ]
            )
        }

        try await store.removeDocuments(notIn: [])

        let vectorCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors") ?? -1
        }
        let failureCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_failures") ?? -1
        }
        XCTAssertEqual(vectorCount, 0)
        XCTAssertEqual(failureCount, 0)
    }

    @MainActor
    func testRelevanceThresholdsAndDuplicateVersionRules() {
        XCTAssertEqual(SearchRelevanceTier.classify(score: 0.49), .marginal)
        XCTAssertEqual(SearchRelevanceTier.classify(score: 0.50), .solid)

        let left = SearchDocumentSnapshot(
            workID: UUID(), title: "Trade and Growth", authors: "A", abstractText: nil,
            publicationYear: 2024, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "left.pdf", sha256: "left"
        )
        let sameTitleNearbyYear = SearchDocumentSnapshot(
            workID: UUID(), title: "Trade and Growth", authors: "B", abstractText: nil,
            publicationYear: 2025, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "right.pdf", sha256: "right"
        )
        let distantYear = SearchDocumentSnapshot(
            workID: UUID(), title: "Trade and Growth", authors: "C", abstractText: nil,
            publicationYear: 2027, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "distant.pdf", sha256: "distant"
        )
        XCTAssertTrue(SearchIndexCoordinator.areDuplicateVersions(left, sameTitleNearbyYear))
        XCTAssertFalse(SearchIndexCoordinator.areDuplicateVersions(left, distantYear))

        let extra = SearchDocumentSnapshot(
            workID: UUID(), title: "Different Paper", authors: "D", abstractText: nil,
            publicationYear: 2025, doi: nil, duplicateCandidateWorkID: nil,
            fileVersionID: UUID(), relativePath: "extra.pdf", sha256: "extra"
        )
        let snapshots = Dictionary(uniqueKeysWithValues: [left, sameTitleNearbyYear, extra].map {
            ($0.workID, $0)
        })
        XCTAssertEqual(
            SearchIndexCoordinator.uniqueVersionWorkIDs(
                rankedWorkIDs: [left.workID, sameTitleNearbyYear.workID, extra.workID],
                snapshots: snapshots,
                limit: 2
            ),
            [left.workID, extra.workID]
        )
    }

    @MainActor
    func testRelativeRerankScoresKeepLowAbsoluteScoresUsable() {
        let normalized = SearchIndexCoordinator.relativeRerankScores([0.003, 0.002, 0.001])
        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized[0], 1, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(normalized[2], 0, accuracy: 0.0001)
        XCTAssertEqual(SearchIndexCoordinator.relativeRerankScores([0.01, 0.01]), [1, 1])
    }

    func testCloudModelRuntimeHealthChecksUseInjectedServices() async throws {
        let probe = SearchModelLoadProbe()
        let runtime = LocalSearchModelRuntime(
            embedder: SearchFakeEmbedder(profile: .balanced, probe: probe),
            reranker: SearchFakeReranker(probe: probe)
        )

        let balanced = try await runtime.validateEmbedding(profile: .balanced)
        let reranker = try await runtime.validateReranker()

        XCTAssertGreaterThan(balanced.relevantSimilarity, balanced.unrelatedSimilarity)
        XCTAssertGreaterThan(reranker.relevantScore, reranker.unrelatedScore)
    }

    func testSemanticSearchUsesSingleCloudConfiguration() {
        XCTAssertEqual(LocalSearchProfile.allCases, [.balanced])
        XCTAssertEqual(LocalSearchProfile.balanced.batchSize, 20)
        XCTAssertEqual(LocalSearchProfile.balanced.allowedBatchSizes, 1...20)
        XCTAssertEqual(LocalSearchProfile.balanced.clampedBatchSize(0), 1)
        XCTAssertEqual(LocalSearchProfile.balanced.clampedBatchSize(99), 20)
        XCTAssertEqual(LocalSearchProfile.balanced.modelID, "qwen3.7-text-embedding")
        XCTAssertEqual(LocalSearchProfile.balanced.dimensions, 2_560)
        XCTAssertEqual(LocalSearchConfiguration.rerankerModelID, "qwen3.7-text-rerank")
        XCTAssertNotEqual(
            LocalSearchProfile.balanced.vectorSpaceSignature,
            LocalSearchConfiguration.legacyBalancedVectorSpaceSignature
        )
    }

    func testBailianEmbeddingProviderUsesBeijingEndpointAndRetrievalParameters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BailianURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let dimensions = LocalSearchProfile.balanced.dimensions
        var firstVector = Array(repeating: Float.zero, count: dimensions)
        firstVector[0] = 2
        var secondVector = Array(repeating: Float.zero, count: dimensions)
        secondVector[1] = 3

        BailianURLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.url?.host,
                "workspace-test.cn-beijing.maas.aliyuncs.com"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret-test-key"
            )
            let body = try XCTUnwrap(BailianURLProtocolStub.bodyData(for: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "qwen3.7-text-embedding")
            let parameters = try XCTUnwrap(json["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["dimension"] as? Int, 2_560)
            XCTAssertEqual(parameters["output_type"] as? String, "dense")
            let textType = try XCTUnwrap(parameters["text_type"] as? String)
            if textType == "query" {
                XCTAssertEqual(
                    parameters["instruct"] as? String,
                    BailianSearchConfiguration.queryInstruction
                )
            } else {
                XCTAssertEqual(textType, "document")
                XCTAssertNil(parameters["instruct"])
            }

            let input = try XCTUnwrap(json["input"] as? [String: Any])
            let texts = try XCTUnwrap(input["texts"] as? [String])
            let embeddings: [[String: Any]]
            if textType == "query" {
                XCTAssertEqual(texts, ["测试查询"])
                embeddings = [["text_index": 0, "embedding": firstVector]]
            } else {
                XCTAssertEqual(texts, ["第一段", "第二段"])
                embeddings = [
                    ["text_index": 1, "embedding": secondVector],
                    ["text_index": 0, "embedding": firstVector],
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "request_id": "request-test",
                "output": ["embeddings": embeddings],
            ])
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { BailianURLProtocolStub.handler = nil }

        let provider = BailianQwenEmbeddingProvider(
            session: session,
            credentialsProvider: {
                BailianSearchCredentials(
                    workspaceID: "workspace-test",
                    apiKey: "secret-test-key"
                )
            }
        )
        let documents = try await provider.embedDocuments(["第一段", "第二段"])
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents[0][0], 1, accuracy: 0.0001)
        XCTAssertEqual(documents[1][1], 1, accuracy: 0.0001)
        let query = try await provider.embedQuery("测试查询")
        XCTAssertEqual(query[0], 1, accuracy: 0.0001)
    }

    func testBailianEmbeddingProviderRejectsUnsafeWorkspaceAndOversizedBatch() async throws {
        XCTAssertFalse(BailianSearchConfiguration.isValidWorkspaceID("bad.example.com"))
        XCTAssertThrowsError(try BailianSearchConfiguration.embeddingEndpoint(workspaceID: "bad/path"))

        let provider = BailianQwenEmbeddingProvider(credentialsProvider: {
            BailianSearchCredentials(workspaceID: "workspace-test", apiKey: "key")
        })
        let texts = Array(repeating: "片段", count: 21)
        do {
            _ = try await provider.embedDocuments(texts)
            XCTFail("超过百炼批次上限时应当失败。")
        } catch let error as BailianEmbeddingError {
            guard case let .tooManyInputs(maximum, actual) = error else {
                return XCTFail("返回了错误的失败类型：\(error)")
            }
            XCTAssertEqual(maximum, 20)
            XCTAssertEqual(actual, 21)
        }
    }

    func testBailianRerankerMapsSortedResultsBackToInputOrder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BailianURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        BailianURLProtocolStub.handler = { request in
            XCTAssertTrue(request.url?.path.contains("/rerank/text-rerank/text-rerank") == true)
            let body = try XCTUnwrap(BailianURLProtocolStub.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "qwen3.7-text-rerank")
            let input = try XCTUnwrap(json["input"] as? [String: Any])
            XCTAssertEqual(input["query"] as? String, "测试查询")
            XCTAssertEqual(input["documents"] as? [String], ["弱相关", "强相关"])
            let parameters = try XCTUnwrap(json["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["top_n"] as? Int, 2)
            XCTAssertEqual(parameters["instruct"] as? String,
                           BailianSearchConfiguration.rerankInstruction)
            let data = try JSONSerialization.data(withJSONObject: [
                "output": ["results": [
                    ["index": 1, "relevance_score": 0.91],
                    ["index": 0, "relevance_score": 0.12],
                ]],
                "request_id": "request-test",
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, data)
        }
        defer { BailianURLProtocolStub.handler = nil }

        let provider = BailianQwenRerankingProvider(
            session: session,
            credentialsProvider: {
                .init(workspaceID: "workspace-test", apiKey: "secret-test-key")
            }
        )
        let scores = try await provider.scores(
            query: "测试查询", documents: ["弱相关", "强相关"]
        )
        XCTAssertEqual(scores[0], 0.12, accuracy: 0.0001)
        XCTAssertEqual(scores[1], 0.91, accuracy: 0.0001)
    }

    func testLegacyModelCacheCleanupOnlyDeletesKnownRepositories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperLibraryModelCleanupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownTargets = LegacyLocalModelCacheCleaner.modelIDs.flatMap { modelID in
            let name = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
            return [
                directory.appending(path: name, directoryHint: .isDirectory),
                directory.appending(path: ".metadata", directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory),
                directory.appending(path: ".locks", directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory),
            ]
        }
        let unrelated = directory.appending(path: "models--unrelated--keep", directoryHint: .isDirectory)
        for target in knownTargets + [unrelated] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: target.appending(path: "marker"))
        }

        try LegacyLocalModelCacheCleaner.removeKnownRepositories(cacheRoot: directory)

        XCTAssertTrue(knownTargets.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testTimingEstimatorUsesOnlyRecentSamplesAndTrimsOutliers() {
        var estimator = LocalSearchTimingEstimator(maximumSampleCount: 50)
        for _ in 0 ..< 8 {
            estimator.record(batchDuration: 2, completedItems: 1)
        }
        estimator.record(batchDuration: 0.1, completedItems: 1)
        estimator.record(batchDuration: 100, completedItems: 1)
        XCTAssertEqual(estimator.estimatedSecondsPerItem ?? 0, 2, accuracy: 0.001)

        for _ in 0 ..< 60 {
            estimator.record(batchDuration: 1, completedItems: 1)
        }
        XCTAssertEqual(estimator.sampleCount, 50)
        XCTAssertEqual(estimator.estimatedSecondsPerItem ?? 0, 1, accuracy: 0.001)

        let start = Date(timeIntervalSince1970: 1_000)
        let completion = estimator.estimatedCompletionDate(
            remainingItems: 25,
            from: start
        )
        XCTAssertEqual(completion?.timeIntervalSince1970 ?? 0, 1_025, accuracy: 0.001)
    }

    func testSemanticIndexRequiresDownloadedAndTestedModels() {
        XCTAssertFalse(LocalSearchWorkflowPolicy.canBuildSemanticIndex(
            allModelsVerified: false,
            modelsTested: false
        ))
        XCTAssertFalse(LocalSearchWorkflowPolicy.canBuildSemanticIndex(
            allModelsVerified: true,
            modelsTested: false
        ))
        XCTAssertFalse(LocalSearchWorkflowPolicy.canBuildSemanticIndex(
            allModelsVerified: false,
            modelsTested: true
        ))
        XCTAssertTrue(LocalSearchWorkflowPolicy.canBuildSemanticIndex(
            allModelsVerified: true,
            modelsTested: true
        ))
    }

    private func makeSearchDatabaseURL(baseDirectory: URL, libraryID: UUID) throws -> URL {
        let directory = baseDirectory
            .appending(path: "dev.paperlibrary.PaperLibrary", directoryHint: .isDirectory)
            .appending(path: "SearchIndexes", directoryHint: .isDirectory)
            .appending(path: libraryID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "search.sqlite")
    }

    private func makeRerankCandidate(
        id: String,
        workID: UUID,
        text: String
    ) -> SmartSearchRerankCandidate {
        SmartSearchRerankCandidate(
            id: id,
            workID: workID,
            chunk: nil,
            vector: nil,
            fusionScore: 0,
            documentText: text
        )
    }

    private func createLegacySearchSchema(in db: Database) throws {
        try db.create(table: "documents") { table in
            table.column("work_id", .text).primaryKey()
            table.column("file_version_id", .text).notNull()
            table.column("relative_path", .text).notNull()
            table.column("sha256", .text).notNull()
            table.column("chunk_schema", .integer).notNull()
            table.column("status", .text).notNull()
            table.column("error_message", .text)
            table.column("updated_at", .datetime).notNull()
        }
        try db.create(table: "chunks") { table in
            table.column("id", .text).primaryKey()
            table.column("work_id", .text).notNull().indexed()
            table.column("file_version_id", .text).notNull()
            table.column("ordinal", .integer).notNull()
            table.column("start_page", .integer).notNull()
            table.column("end_page", .integer).notNull()
            table.column("text", .text).notNull()
            table.column("searchable_text", .text).notNull()
            table.column("vector", .blob)
            table.column("vector_signature", .text)
        }
        try db.execute(sql: """
            CREATE VIRTUAL TABLE chunks_fts USING fts5(
                chunk_id UNINDEXED,
                searchable_text,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
    }

    private func encodedHalfPrecisionVector(_ vector: [Float]) -> Data {
        let values = vector.map { Float16($0).bitPattern.littleEndian }
        return values.withUnsafeBytes { Data($0) }
    }
}

private final class BailianURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor SearchModelLoadProbe {
    private var loadedCount = 0
    private var maximumCount = 0
    private var downloadPreparations = 0
    private var cachedPreparations = 0

    func didPrepareForDownload() {
        downloadPreparations += 1
    }

    func didPrepareFromCache() {
        cachedPreparations += 1
    }

    func didLoad() {
        loadedCount += 1
        maximumCount = max(maximumCount, loadedCount)
    }

    func didRelease() {
        loadedCount -= 1
    }

    func maximumLoadedCount() -> Int { maximumCount }
    func currentLoadedCount() -> Int { loadedCount }
    func downloadPreparationCount() -> Int { downloadPreparations }
    func cachedPreparationCount() -> Int { cachedPreparations }
}

private actor SearchFakeEmbedder: TextEmbeddingProvider {
    nonisolated let profile: LocalSearchProfile
    private let probe: SearchModelLoadProbe
    private var isLoaded = false

    init(profile: LocalSearchProfile, probe: SearchModelLoadProbe) {
        self.profile = profile
        self.probe = probe
    }

    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws {
        await probe.didPrepareForDownload()
        try await loadIfNeeded()
        progress(.init(completed: 1, total: 1))
    }

    func prepareFromCache() async throws {
        await probe.didPrepareFromCache()
        try await loadIfNeeded()
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        await probe.didLoad()
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        try await Task.sleep(for: .milliseconds(20))
        return texts.map(vector)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await Task.sleep(for: .milliseconds(20))
        return vector(for: text)
    }

    private func vector(for text: String) -> [Float] {
        var value = Array(repeating: Float.zero, count: profile.dimensions)
        if text.contains("融资") || text.contains("投资") {
            value[0] = 1
        } else {
            value[1] = 1
        }
        return value
    }

    func release() async {
        guard isLoaded else { return }
        isLoaded = false
        await probe.didRelease()
    }
}

private actor SearchFakeReranker: TextRerankingProvider {
    nonisolated let modelID = "fake-reranker"
    nonisolated let revision = "1"
    private let probe: SearchModelLoadProbe
    private var isLoaded = false

    init(probe: SearchModelLoadProbe) {
        self.probe = probe
    }

    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws {
        await probe.didPrepareForDownload()
        try await loadIfNeeded()
        progress(.init(completed: 1, total: 1))
    }

    func prepareFromCache() async throws {
        await probe.didPrepareFromCache()
        try await loadIfNeeded()
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        await probe.didLoad()
    }

    func scores(query: String, documents: [String]) async throws -> [Float] {
        try await Task.sleep(for: .milliseconds(20))
        return documents.map {
            ($0.contains("融资") || $0.contains("投资")) ? 0.9 : 0.1
        }
    }

    func release() async {
        guard isLoaded else { return }
        isLoaded = false
        await probe.didRelease()
    }
}
