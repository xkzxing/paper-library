import Foundation
import GRDB
import Accelerate

struct SearchStoredChunk: Sendable, Equatable {
    let chunk: SearchTextChunk
    let vector: [Float]?
}

struct SearchStoreHit: Sendable, Equatable {
    let chunk: SearchTextChunk
    let rank: Double
}

actor SearchIndexStore {
    private let database: DatabaseQueue

    init(libraryID: UUID, baseDirectory: URL? = nil) throws {
        let manager = FileManager.default
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if AppRuntimeEnvironment.isRunningTests {
            base = manager.temporaryDirectory.appending(
                path: "PaperLibrarySearchTests-\(ProcessInfo.processInfo.processIdentifier)",
                directoryHint: .isDirectory
            )
        } else {
            base = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = base
            .appending(path: "dev.paperlibrary.PaperLibrary", directoryHint: .isDirectory)
            .appending(path: "SearchIndexes", directoryHint: .isDirectory)
            .appending(path: libraryID.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(
            path: directory.appending(path: "search.sqlite").path,
            configuration: configuration
        )
        try Self.migrator.migrate(database)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("search-v1") { db in
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
        migrator.registerMigration("search-v2-dual-vectors-and-failures") { db in
            try db.create(table: "chunk_vectors") { table in
                table.column("chunk_id", .text).notNull()
                table.column("model_signature", .text).notNull()
                table.column("dimensions", .integer).notNull()
                table.column("vector", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["chunk_id", "model_signature"])
            }
            try db.create(index: "chunk_vectors_signature", on: "chunk_vectors", columns: ["model_signature"])
            try db.create(table: "search_failures") { table in
                table.column("id", .text).primaryKey()
                table.column("stage", .text).notNull()
                table.column("model_signature", .text)
                table.column("work_id", .text)
                table.column("chunk_id", .text)
                table.column("start_page", .integer)
                table.column("end_page", .integer)
                table.column("message", .text).notNull()
                table.column("occurred_at", .datetime).notNull()
            }
            try db.create(index: "search_failures_work", on: "search_failures", columns: ["work_id"])
            try db.create(index: "search_failures_model", on: "search_failures", columns: ["model_signature"])

            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO chunk_vectors
                    (chunk_id, model_signature, dimensions, vector, updated_at)
                    SELECT id, ?, ?, vector, ?
                    FROM chunks
                    WHERE vector IS NOT NULL
                    """,
                arguments: [
                    LocalSearchConfiguration.legacyFastVectorSpaceSignature,
                    LocalSearchConfiguration.legacyFastDimensions,
                    Date(),
                ]
            )
            try db.execute(sql: "UPDATE chunks SET vector = NULL, vector_signature = NULL")
        }
        return migrator
    }

    func needsTextIndex(_ snapshot: SearchDocumentSnapshot) throws -> Bool {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT file_version_id, sha256, chunk_schema, status
                    FROM documents WHERE work_id = ?
                    """,
                arguments: [snapshot.workID.uuidString]
            ) else { return true }
            let versionID: String = row["file_version_id"]
            let sha256: String = row["sha256"]
            let schema: Int = row["chunk_schema"]
            let status: String = row["status"]
            return versionID != snapshot.fileVersionID.uuidString ||
                sha256 != snapshot.sha256 ||
                schema != LocalSearchConfiguration.chunkSchemaVersion ||
                status == "pending"
        }
    }

    func snapshotsNeedingTextIndex(
        _ snapshots: [SearchDocumentSnapshot]
    ) throws -> [SearchDocumentSnapshot] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT work_id, file_version_id, sha256, chunk_schema, status
                    FROM documents
                    """
            )
            let stored = Dictionary(uniqueKeysWithValues: rows.map { row in
                let workID: String = row["work_id"]
                let fileVersionID: String = row["file_version_id"]
                let sha256: String = row["sha256"]
                let chunkSchema: Int = row["chunk_schema"]
                let status: String = row["status"]
                return (
                    workID,
                    (fileVersionID, sha256, chunkSchema, status)
                )
            })

            return snapshots.filter { snapshot in
                guard let existing = stored[snapshot.workID.uuidString] else { return true }
                return existing.0 != snapshot.fileVersionID.uuidString ||
                    existing.1 != snapshot.sha256 ||
                    existing.2 != LocalSearchConfiguration.chunkSchemaVersion ||
                    existing.3 == "pending"
            }
        }
    }

    func replaceDocument(
        _ snapshot: SearchDocumentSnapshot,
        chunks: [SearchTextChunk]
    ) throws {
        try database.write { db in
            try deleteDocumentContent(rawWorkID: snapshot.workID.uuidString, db: db)
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO documents
                    (work_id, file_version_id, relative_path, sha256, chunk_schema, status, error_message, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'ready', NULL, ?)
                    """,
                arguments: [
                    snapshot.workID.uuidString,
                    snapshot.fileVersionID.uuidString,
                    snapshot.relativePath,
                    snapshot.sha256,
                    LocalSearchConfiguration.chunkSchemaVersion,
                    Date(),
                ]
            )
            for chunk in chunks {
                try db.execute(
                    sql: """
                        INSERT INTO chunks
                        (id, work_id, file_version_id, ordinal, start_page, end_page, text, searchable_text)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        chunk.id, chunk.workID.uuidString, chunk.fileVersionID.uuidString,
                        chunk.ordinal, chunk.startPage, chunk.endPage, chunk.text, chunk.searchableText,
                    ]
                )
                try db.execute(
                    sql: "INSERT INTO chunks_fts (chunk_id, searchable_text) VALUES (?, ?)",
                    arguments: [chunk.id, chunk.searchableText]
                )
            }
        }
    }

    func markUnindexable(_ snapshot: SearchDocumentSnapshot, message: String) throws {
        try database.write { db in
            try deleteDocumentContent(rawWorkID: snapshot.workID.uuidString, db: db)
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO documents
                    (work_id, file_version_id, relative_path, sha256, chunk_schema, status, error_message, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'unindexable', ?, ?)
                    """,
                arguments: [
                    snapshot.workID.uuidString, snapshot.fileVersionID.uuidString,
                    snapshot.relativePath, snapshot.sha256,
                    LocalSearchConfiguration.chunkSchemaVersion, message, Date(),
                ]
            )
            try insertFailure(
                stage: .textExtraction,
                modelSignature: nil,
                workID: snapshot.workID,
                chunk: nil,
                message: message,
                db: db
            )
        }
    }

    func removeDocuments(workIDs: Set<UUID>) throws {
        guard !workIDs.isEmpty else { return }
        try database.write { db in
            for workID in workIDs {
                try deleteDocumentContent(rawWorkID: workID.uuidString, db: db)
                try db.execute(
                    sql: "DELETE FROM documents WHERE work_id = ?",
                    arguments: [workID.uuidString]
                )
            }
        }
    }

    func removeDocuments(notIn workIDs: Set<UUID>) throws {
        try database.write { db in
            let documentIDs = try String.fetchAll(db, sql: "SELECT work_id FROM documents")
            let chunkIDs = try String.fetchAll(db, sql: "SELECT DISTINCT work_id FROM chunks")
            for rawID in Set(documentIDs + chunkIDs)
            where UUID(uuidString: rawID).map({ !workIDs.contains($0) }) ?? true {
                try deleteDocumentContent(rawWorkID: rawID, db: db)
                try db.execute(sql: "DELETE FROM documents WHERE work_id = ?", arguments: [rawID])
            }
            try db.execute(sql: """
                DELETE FROM chunks_fts
                WHERE chunk_id NOT IN (SELECT id FROM chunks)
                """)
            try db.execute(sql: """
                DELETE FROM chunk_vectors
                WHERE chunk_id NOT IN (SELECT id FROM chunks)
                """)
            try db.execute(sql: """
                DELETE FROM search_failures
                WHERE chunk_id IS NOT NULL
                  AND chunk_id NOT IN (SELECT id FROM chunks)
                """)
            try db.execute(sql: """
                DELETE FROM search_failures
                WHERE work_id IS NOT NULL
                  AND work_id NOT IN (SELECT work_id FROM documents)
                """)
        }
    }

    func keywordSearch(
        _ query: String,
        matchMode: LibrarySearchMatchMode = .anyTerm,
        limit: Int = 100,
        allowedWorkIDs: Set<UUID>? = nil,
        maximumHitsPerWork: Int = .max
    ) throws -> [SearchStoreHit] {
        let expression = Self.ftsExpression(query, matchMode: matchMode)
        guard !expression.isEmpty, limit > 0, maximumHitsPerWork > 0 else { return [] }
        if allowedWorkIDs?.isEmpty == true { return [] }
        return try database.read { db in
            let perWorkLimit = min(maximumHitsPerWork, limit)
            let batches: [[String]?]
            if let allowedWorkIDs {
                batches = allowedWorkIDs.map(\.uuidString)
                    .sorted()
                    .chunked(maximumSize: 400)
                    .map(Optional.some)
            } else {
                batches = [nil]
            }

            var hits: [SearchStoreHit] = []
            for batch in batches {
                try Task.checkCancellation()
                let scopeClause: String
                var arguments: StatementArguments = [expression]
                if let batch {
                    let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                    scopeClause = "AND c.work_id IN (\(placeholders))"
                    arguments += StatementArguments(batch)
                } else {
                    scopeClause = ""
                }
                arguments += [perWorkLimit, limit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        WITH matched AS (
                            SELECT c.*, bm25(chunks_fts) AS relevance
                            FROM chunks_fts
                            JOIN chunks c ON c.id = chunks_fts.chunk_id
                            WHERE chunks_fts MATCH ?
                            \(scopeClause)
                        ), ranked AS (
                            SELECT *, ROW_NUMBER() OVER (
                                PARTITION BY work_id
                                ORDER BY relevance ASC, id ASC
                            ) AS work_position
                            FROM matched
                        )
                        SELECT * FROM ranked
                        WHERE work_position <= ?
                        ORDER BY relevance ASC, id ASC
                        LIMIT ?
                        """,
                    arguments: arguments
                )
                hits.append(contentsOf: try rows.map { row in
                    let rank: Double = row["relevance"]
                    return SearchStoreHit(chunk: try Self.chunk(from: row), rank: -rank)
                })
            }

            var counts: [UUID: Int] = [:]
            return hits.sorted {
                if $0.rank == $1.rank { return $0.chunk.id < $1.chunk.id }
                return $0.rank > $1.rank
            }.filter { hit in
                guard counts[hit.chunk.workID, default: 0] < perWorkLimit else {
                    return false
                }
                counts[hit.chunk.workID, default: 0] += 1
                return true
            }.prefix(limit).map { $0 }
        }
    }

    /// 流式扫描持久向量，仅在内存中保留 `limit` 个最高分候选。
    /// 查询向量与持久向量都已归一化，因此点积即余弦相似度。
    func topSemanticCandidates(
        queryVector: [Float],
        signature: String,
        limit: Int,
        allowedWorkIDs: Set<UUID>? = nil,
        maximumHitsPerWork: Int = 2
    ) throws -> [SearchVectorCandidate] {
        guard !queryVector.isEmpty, limit > 0, maximumHitsPerWork > 0 else { return [] }
        if allowedWorkIDs?.isEmpty == true { return [] }
        return try database.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT c.id, c.work_id, v.dimensions, v.vector
                    FROM chunk_vectors v
                    JOIN chunks c ON c.id = v.chunk_id
                    WHERE v.model_signature = ?
                    """,
                arguments: [signature]
            )
            var candidates: [SearchVectorCandidate] = []
            candidates.reserveCapacity(limit)
            var scanned = 0

            while let row = try cursor.next() {
                if scanned.isMultiple(of: 256) { try Task.checkCancellation() }
                scanned += 1

                let rawWorkID: String = row["work_id"]
                guard let workID = UUID(uuidString: rawWorkID) else {
                    throw SearchIndexStoreError.corruptIdentifier(rawWorkID)
                }
                if let allowedWorkIDs, !allowedWorkIDs.contains(workID) { continue }

                let dimensions: Int = row["dimensions"]
                guard dimensions == queryVector.count else { continue }
                let data: Data = row["vector"]
                let vector = Self.decodeVector(data)
                guard vector.count == queryVector.count else { continue }

                var score: Float = 0
                vDSP_dotpr(
                    queryVector, 1,
                    vector, 1,
                    &score, vDSP_Length(queryVector.count)
                )
                if candidates.count == limit, score <= (candidates.last?.score ?? -.infinity) {
                    continue
                }
                let existingForWork = candidates.indices.filter {
                    candidates[$0].workID == workID
                }
                if existingForWork.count >= maximumHitsPerWork,
                   let worstIndex = existingForWork.last {
                    guard score > candidates[worstIndex].score else { continue }
                    candidates.remove(at: worstIndex)
                }
                let candidate = SearchVectorCandidate(
                    chunkID: row["id"],
                    workID: workID,
                    vector: vector,
                    score: score
                )
                let insertionIndex = candidates.firstIndex { score > $0.score } ?? candidates.endIndex
                candidates.insert(candidate, at: insertionIndex)
                if candidates.count > limit { candidates.removeLast() }
            }
            try Task.checkCancellation()
            return candidates
        }
    }

    /// 候选确定后再读取正文，避免语义扫描期间把整库文本驻留在内存中。
    func chunks(ids: Set<String>) throws -> [SearchTextChunk] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var chunks: [SearchTextChunk] = []
            chunks.reserveCapacity(ids.count)
            for batch in ids.chunked(maximumSize: 400) {
                try Task.checkCancellation()
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chunks WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
                chunks.append(contentsOf: try rows.map { try Self.chunk(from: $0) })
            }
            return chunks
        }
    }

    /// 返回每篇文献序号最小的正文片段，用于把书目信息结果纳入融合排序。
    func firstChunkIDs(workIDs: Set<UUID>) throws -> [UUID: String] {
        guard !workIDs.isEmpty else { return [:] }
        return try database.read { db in
            var result: [UUID: String] = [:]
            let rawIDs = workIDs.map(\.uuidString)
            for batch in rawIDs.chunked(maximumSize: 400) {
                try Task.checkCancellation()
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, work_id FROM chunks
                        WHERE work_id IN (\(placeholders))
                        ORDER BY work_id, ordinal
                        """,
                    arguments: StatementArguments(batch)
                )
                for row in rows {
                    let rawWorkID: String = row["work_id"]
                    guard let workID = UUID(uuidString: rawWorkID) else {
                        throw SearchIndexStoreError.corruptIdentifier(rawWorkID)
                    }
                    if result[workID] == nil { result[workID] = row["id"] }
                }
            }
            return result
        }
    }

    func allEmbeddedChunks(signature: String) throws -> [SearchStoredChunk] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.*, v.vector AS stored_vector
                    FROM chunk_vectors v
                    JOIN chunks c ON c.id = v.chunk_id
                    WHERE v.model_signature = ?
                    """,
                arguments: [signature]
            ).map { row in
                let data: Data? = row["stored_vector"]
                return SearchStoredChunk(
                    chunk: try Self.chunk(from: row),
                    vector: data.map(Self.decodeVector)
                )
            }
        }
    }

    func chunksNeedingEmbedding(
        signature: String,
        limit: Int = 64,
        excludingFailures: Bool = true
    ) throws -> [SearchTextChunk] {
        try database.read { db in
            let failureClause = excludingFailures
                ? """
                    AND NOT EXISTS (
                        SELECT 1 FROM search_failures f
                        WHERE f.chunk_id = c.id
                          AND f.model_signature = ?
                          AND f.stage = ?
                    )
                    """
                : ""
            var arguments: StatementArguments = [signature]
            if excludingFailures {
                arguments += [signature, LocalSearchMaintenanceStage.embedding.rawValue]
            }
            arguments += [limit]
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM chunks c
                    WHERE NOT EXISTS (
                        SELECT 1 FROM chunk_vectors v
                        WHERE v.chunk_id = c.id AND v.model_signature = ?
                    )
                    \(failureClause)
                    ORDER BY c.work_id, c.ordinal
                    LIMIT ?
                    """,
                arguments: arguments
            ).map { try Self.chunk(from: $0) }
        }
    }

    func saveEmbeddings(
        _ vectors: [[Float]],
        for chunks: [SearchTextChunk],
        profile: LocalSearchProfile
    ) throws {
        guard vectors.count == chunks.count else {
            throw SearchIndexStoreError.vectorCountMismatch
        }
        guard vectors.allSatisfy({ $0.count == profile.dimensions }) else {
            throw SearchIndexStoreError.vectorDimensionMismatch(expected: profile.dimensions)
        }
        try database.write { db in
            for (chunk, vector) in zip(chunks, vectors) {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO chunk_vectors
                        (chunk_id, model_signature, dimensions, vector, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        chunk.id, profile.vectorSpaceSignature, profile.dimensions,
                        Self.encodeVector(vector), Date(),
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM search_failures WHERE chunk_id = ? AND model_signature = ?",
                    arguments: [chunk.id, profile.vectorSpaceSignature]
                )
            }
        }
    }

    func statistics(
        profile: LocalSearchProfile,
        totalDocuments: Int
    ) throws -> LocalSearchProfileStatistics {
        try database.read { db in
            let indexedDocuments = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM documents WHERE status = 'ready'"
            ) ?? 0
            let chunks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            let embedded = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chunk_vectors WHERE model_signature = ?",
                arguments: [profile.vectorSpaceSignature]
            ) ?? 0
            let failures = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM search_failures
                    WHERE stage = ? AND model_signature = ?
                    """,
                arguments: [
                    LocalSearchMaintenanceStage.embedding.rawValue,
                    profile.vectorSpaceSignature,
                ]
            ) ?? 0
            let storedBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(length(vector)), 0) FROM chunk_vectors WHERE model_signature = ?",
                arguments: [profile.vectorSpaceSignature]
            ) ?? 0
            return LocalSearchProfileStatistics(
                profile: profile,
                indexedDocuments: indexedDocuments,
                totalDocuments: totalDocuments,
                embeddedChunks: embedded,
                totalChunks: chunks,
                failedChunks: failures,
                storedBytes: storedBytes
            )
        }
    }

    func documentsMissingEmbeddings(
        signature: String,
        allowedWorkIDs: Set<UUID>? = nil
    ) throws -> Int {
        if allowedWorkIDs?.isEmpty == true { return 0 }
        return try database.read { db in
            let batches: [[String]?]
            if let allowedWorkIDs {
                batches = allowedWorkIDs.map(\.uuidString)
                    .chunked(maximumSize: 400)
                    .map(Optional.some)
            } else {
                batches = [nil]
            }
            var total = 0
            for batch in batches {
                let scopeClause: String
                var arguments: StatementArguments = [signature]
                if let batch {
                    let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                    scopeClause = "AND c.work_id IN (\(placeholders))"
                    arguments += StatementArguments(batch)
                } else {
                    scopeClause = ""
                }
                total += try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(DISTINCT c.work_id)
                        FROM chunks c
                        WHERE NOT EXISTS (
                            SELECT 1 FROM chunk_vectors v
                            WHERE v.chunk_id = c.id AND v.model_signature = ?
                        )
                        \(scopeClause)
                        """,
                    arguments: arguments
                ) ?? 0
            }
            return total
        }
    }

    @discardableResult
    func removeVectors(profile: LocalSearchProfile) throws -> Bool {
        try removeVectors(signature: profile.vectorSpaceSignature)
    }

    @discardableResult
    func removeVectors(signature: String) throws -> Bool {
        try database.write { db in
            let vectorCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chunk_vectors WHERE model_signature = ?",
                arguments: [signature]
            ) ?? 0
            try db.execute(
                sql: "DELETE FROM chunk_vectors WHERE model_signature = ?",
                arguments: [signature]
            )
            try db.execute(
                sql: "DELETE FROM search_failures WHERE model_signature = ?",
                arguments: [signature]
            )
            return vectorCount > 0
        }
    }

    func recordEmbeddingFailure(
        profile: LocalSearchProfile,
        chunk: SearchTextChunk,
        message: String
    ) throws {
        try database.write { db in
            try insertFailure(
                stage: .embedding,
                modelSignature: profile.vectorSpaceSignature,
                workID: chunk.workID,
                chunk: chunk,
                message: message,
                db: db
            )
        }
    }

    func clearEmbeddingFailures(profile: LocalSearchProfile) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM search_failures WHERE stage = ? AND model_signature = ?",
                arguments: [
                    LocalSearchMaintenanceStage.embedding.rawValue,
                    profile.vectorSpaceSignature,
                ]
            )
        }
    }

    func prepareFailuresForRetry() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE documents SET status = 'pending' WHERE status = 'unindexable'")
            try db.execute(sql: "DELETE FROM search_failures")
        }
    }

    func recordGlobalFailure(
        stage: LocalSearchMaintenanceStage,
        modelSignature: String?,
        message: String
    ) throws {
        try database.write { db in
            try insertFailure(
                stage: stage,
                modelSignature: modelSignature,
                workID: nil,
                chunk: nil,
                message: message,
                db: db
            )
        }
    }

    func clearGlobalFailures(stage: LocalSearchMaintenanceStage) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM search_failures
                    WHERE stage = ? AND work_id IS NULL AND chunk_id IS NULL
                    """,
                arguments: [stage.rawValue]
            )
        }
    }

    func failures() throws -> [LocalSearchFailure] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM search_failures ORDER BY occurred_at DESC"
            ).compactMap { row in
                guard let stage = LocalSearchMaintenanceStage(rawValue: row["stage"]) else { return nil }
                let rawWorkID: String? = row["work_id"]
                return LocalSearchFailure(
                    id: row["id"],
                    stage: stage,
                    modelSignature: row["model_signature"],
                    workID: rawWorkID.flatMap(UUID.init(uuidString:)),
                    chunkID: row["chunk_id"],
                    startPage: row["start_page"],
                    endPage: row["end_page"],
                    message: row["message"],
                    occurredAt: row["occurred_at"]
                )
            }
        }
    }

    func compactIfNeeded(force: Bool = false) throws {
        let shouldCompact = try database.read { db -> Bool in
            if force { return true }
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let freePages = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let freeBytes = freePages * pageSize
            return freeBytes >= 64 * 1_024 * 1_024 ||
                (pageCount > 0 && Double(freePages) / Double(pageCount) >= 0.20)
        }
        guard shouldCompact else { return }
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
        }
    }

    private func deleteDocumentContent(rawWorkID: String, db: Database) throws {
        let identifiers = try String.fetchAll(
            db,
            sql: "SELECT id FROM chunks WHERE work_id = ?",
            arguments: [rawWorkID]
        )
        for identifier in identifiers {
            try db.execute(sql: "DELETE FROM chunks_fts WHERE chunk_id = ?", arguments: [identifier])
        }
        if !identifiers.isEmpty {
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM chunk_vectors WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(identifiers)
            )
            try db.execute(
                sql: "DELETE FROM search_failures WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(identifiers)
            )
        }
        try db.execute(sql: "DELETE FROM search_failures WHERE work_id = ?", arguments: [rawWorkID])
        try db.execute(sql: "DELETE FROM chunks WHERE work_id = ?", arguments: [rawWorkID])
    }

    private func insertFailure(
        stage: LocalSearchMaintenanceStage,
        modelSignature: String?,
        workID: UUID?,
        chunk: SearchTextChunk?,
        message: String,
        db: Database
    ) throws {
        let identity = chunk?.id ?? workID?.uuidString ?? "global"
        let identifier = "\(stage.rawValue)|\(modelSignature ?? "none")|\(identity)"
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO search_failures
                (id, stage, model_signature, work_id, chunk_id, start_page, end_page, message, occurred_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                identifier, stage.rawValue, modelSignature, workID?.uuidString,
                chunk?.id, chunk?.startPage, chunk?.endPage, message, Date(),
            ]
        )
    }

    private static func chunk(from row: Row) throws -> SearchTextChunk {
        let rawWorkID: String = row["work_id"]
        let rawFileVersionID: String = row["file_version_id"]
        guard let workID = UUID(uuidString: rawWorkID) else {
            throw SearchIndexStoreError.corruptIdentifier(rawWorkID)
        }
        guard let fileVersionID = UUID(uuidString: rawFileVersionID) else {
            throw SearchIndexStoreError.corruptIdentifier(rawFileVersionID)
        }
        return SearchTextChunk(
            id: row["id"],
            workID: workID,
            fileVersionID: fileVersionID,
            ordinal: row["ordinal"],
            startPage: row["start_page"],
            endPage: row["end_page"],
            text: row["text"],
            searchableText: row["searchable_text"]
        )
    }

    private static func ftsExpression(
        _ query: String,
        matchMode: LibrarySearchMatchMode
    ) -> String {
        if matchMode == .exactPhrase {
            let phrase = LibrarySearchRules.normalize(query)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                .replacingOccurrences(of: "\"", with: "\"\"")
            guard !phrase.isEmpty else { return "" }
            let bigrams = cjkBigrams(phrase)
            return bigrams.isEmpty
                ? "\"\(phrase)\""
                : "\"\(bigrams.joined(separator: " "))\""
        }
        let terms = LibrarySearchRules.queryTerms(query)
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        let separator = matchMode == .allTerms ? " AND " : " OR "
        return terms.map { term in
            let bigrams = cjkBigrams(term)
            guard !bigrams.isEmpty else { return "\"\(term)\"" }
            let joined = bigrams.map { "\"\($0)\"" }.joined(separator: " AND ")
            return "(\(joined))"
        }.joined(separator: separator)
    }

    private static func cjkBigrams(_ value: String) -> [String] {
        let characters = value.unicodeScalars.filter { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value))
        }.map(String.init)
        guard characters.count > 1 else { return [] }
        return zip(characters, characters.dropFirst()).map { $0 + $1 }
    }

    private static func encodeVector(_ vector: [Float]) -> Data {
        let values = vector.map { Float16($0).bitPattern.littleEndian }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            stride(from: 0, to: rawBuffer.count, by: MemoryLayout<UInt16>.size).map { offset in
                let bits = rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                return Float(Float16(bitPattern: UInt16(littleEndian: bits)))
            }
        }
    }
}

enum SearchIndexStoreError: LocalizedError {
    case vectorCountMismatch
    case vectorDimensionMismatch(expected: Int)
    case corruptIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .vectorCountMismatch:
            return "向量数量与正文片段数量不一致。"
        case let .vectorDimensionMismatch(expected):
            return "向量维度不正确，预期为 \(expected) 维。"
        case let .corruptIdentifier(value):
            return "搜索索引包含损坏的标识符：\(value)。请重建搜索索引。"
        }
    }
}

private extension Collection {
    func chunked(maximumSize: Int) -> [[Element]] {
        guard maximumSize > 0 else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index != endIndex {
            let next = self.index(index, offsetBy: maximumSize, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}
