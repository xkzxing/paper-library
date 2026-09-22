import Foundation

struct SearchDocumentSnapshot: Sendable, Equatable {
    let workID: UUID
    let title: String
    let authors: String
    let abstractText: String?
    let publicationYear: Int?
    let doi: String?
    let duplicateCandidateWorkID: UUID?
    let fileVersionID: UUID
    let relativePath: String
    let sha256: String

    var metadataText: String {
        [
            title,
            authors,
            abstractText ?? "",
            publicationYear.map(String.init) ?? "",
            doi ?? "",
            relativePath,
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct SearchTextChunk: Sendable, Equatable, Identifiable {
    let id: String
    let workID: UUID
    let fileVersionID: UUID
    let ordinal: Int
    let startPage: Int
    let endPage: Int
    let text: String
    let searchableText: String
}

/// 语义扫描只保留固定数量的最高分候选，避免把全部正文和向量展开到内存。
struct SearchVectorCandidate: Sendable, Equatable {
    let chunkID: String
    let workID: UUID
    let vector: [Float]
    let score: Float
}

enum SearchMatchKind: String, Sendable {
    case metadata
    case fullText
    case semantic

    var title: String {
        switch self {
        case .metadata: return "书目信息"
        case .fullText: return "正文"
        case .semantic: return "语义相关内容"
        }
    }
}

enum SearchRelevanceTier: String, Sendable, Equatable {
    case solid
    case marginal

    static func classify(score: Double) -> Self {
        score >= Double(LocalSearchConfiguration.solidRelevanceThreshold) ? .solid : .marginal
    }
}

struct SearchPassageHit: Sendable, Equatable, Identifiable {
    let id: String
    let chunkID: String
    let workID: UUID
    let kind: SearchMatchKind
    let score: Double
    let relevance: SearchRelevanceTier
    let snippet: String
    let startPage: Int
    let endPage: Int

    var pageDescription: String {
        startPage == endPage ? "第 \(startPage) 页" : "第 \(startPage)–\(endPage) 页"
    }
}

struct SearchWorkMatch: Sendable, Equatable, Identifiable {
    var id: UUID { workID }
    let workID: UUID
    let score: Double
    let kind: SearchMatchKind
    let reason: String
    let passages: [SearchPassageHit]

    var primaryPassage: SearchPassageHit? { passages.first }
}

enum SmartSearchDepth: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast
    case balanced
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .deep: return "深度"
        }
    }

    var channelLimit: Int {
        switch self {
        case .fast: return 100
        case .balanced: return 200
        case .deep: return 300
        }
    }

    var fusedWorkLimit: Int {
        switch self {
        case .fast: return 30
        case .balanced: return 60
        case .deep: return 100
        }
    }

    var rerankPassageLimit: Int {
        switch self {
        case .fast: return 30
        case .balanced: return 80
        case .deep: return 120
        }
    }

    var characterBudget: Int {
        switch self {
        case .fast: return 45_000
        case .balanced: return 90_000
        case .deep: return 110_000
        }
    }

    var summary: String {
        switch self {
        case .fast: return "减少候选数量，优先缩短等待时间。"
        case .balanced: return "兼顾文献覆盖、等待时间和调用量。"
        case .deep: return "扩大候选范围，适合宽泛或措辞不确定的查询。"
        }
    }
}

struct SmartSearchPreferences: Sendable, Equatable {
    static let allowedResultLimits = [5, 10, 20]

    let depth: SmartSearchDepth
    let resultLimit: Int

    init(depth: SmartSearchDepth = .balanced, resultLimit: Int = 10) {
        self.depth = depth
        self.resultLimit = Self.allowedResultLimits.contains(resultLimit) ? resultLimit : 10
    }
}

struct SmartSearchScope: Sendable, Equatable {
    let allowedWorkIDs: Set<UUID>
    let revision: UInt64
}

struct SmartSearchRerankCandidate: Sendable, Equatable, Identifiable {
    let id: String
    let workID: UUID
    let chunk: SearchTextChunk?
    let vector: [Float]?
    let fusionScore: Double
    let documentText: String
}

struct SmartSearchWorkCandidate: Sendable, Equatable {
    let workID: UUID
    let fusionScore: Double
    let passages: [SmartSearchRerankCandidate]
}

struct SmartSearchPassageScore: Sendable, Equatable {
    let id: String
    let rawScore: Double
    let startPage: Int
}

enum SmartSearchPassageSelector {
    /// 文献排名仍由最高重排得分决定；这里只选择列表中的阅读入口。
    /// 开头段落与最佳段落接近时优先早页，避免整篇主题相关的文献被定位到附录或参考文献。
    static func displayOrder(
        _ passages: [SmartSearchPassageScore],
        earlyPageUpperBound: Int = 3,
        absoluteTolerance: Double = 0.08,
        minimumScoreRatio: Double = 0.85
    ) -> [String] {
        let ranked = passages.sorted {
            if $0.rawScore == $1.rawScore {
                if $0.startPage == $1.startPage { return $0.id < $1.id }
                return $0.startPage < $1.startPage
            }
            return $0.rawScore > $1.rawScore
        }
        guard let best = ranked.first else { return [] }

        let early = ranked.filter { passage in
            guard passage.startPage <= earlyPageUpperBound else { return false }
            let closeByDifference = best.rawScore - passage.rawScore <= absoluteTolerance
            let closeByRatio: Bool
            if best.rawScore > 0 {
                closeByRatio = passage.rawScore / best.rawScore >= minimumScoreRatio
            } else {
                closeByRatio = passage.rawScore >= best.rawScore
            }
            return closeByDifference || closeByRatio
        }.min {
            if $0.startPage == $1.startPage {
                if $0.rawScore == $1.rawScore { return $0.id < $1.id }
                return $0.rawScore > $1.rawScore
            }
            return $0.startPage < $1.startPage
        }

        guard let early, early.id != best.id else { return ranked.map(\.id) }
        return [early.id] + ranked.filter { $0.id != early.id }.map(\.id)
    }
}

enum SmartSearchCandidateBuilder {
    static func uniqueWorkRanking(_ workIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return workIDs.filter { seen.insert($0).inserted }
    }

    static func fusedWorkRanking(
        keyword: [UUID],
        semantic: [UUID],
        metadata: [UUID],
        limit: Int
    ) -> [(workID: UUID, score: Double)] {
        let rankings = [keyword, semantic, metadata].map {
            uniqueWorkRanking($0).map(\.uuidString)
        }
        return SearchFusion.reciprocalRankFusion(rankings: rankings)
            .compactMap { rawID, score in
                UUID(uuidString: rawID).map { (workID: $0, score: score) }
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.workID.uuidString < $1.workID.uuidString
                }
                return $0.score > $1.score
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 先为预计显示的高位文献保留主候选和阅读入口，再用剩余预算扩大文献覆盖。
    /// 未预留阅读入口时保持原有的“每篇先取一段”行为。
    static func selectRerankCandidates(
        works: [SmartSearchWorkCandidate],
        passageLimit: Int,
        characterBudget: Int,
        prioritySecondaryCount: Int = 0
    ) -> [SmartSearchRerankCandidate] {
        guard passageLimit > 0, characterBudget > 0 else { return [] }
        var selected: [SmartSearchRerankCandidate] = []
        var selectedIDs: Set<String> = []
        var usedCharacters = 0

        func append(_ candidate: SmartSearchRerankCandidate) -> Bool {
            guard selected.count < passageLimit, !selectedIDs.contains(candidate.id) else {
                return false
            }
            let size = candidate.documentText.count
            guard usedCharacters + size <= characterBudget else { return false }
            selected.append(candidate)
            selectedIDs.insert(candidate.id)
            usedCharacters += size
            return true
        }

        let reservedWorkCount = min(
            works.count,
            max(0, min(prioritySecondaryCount, passageLimit / 2))
        )
        let reservedWorks = works.prefix(reservedWorkCount)
        for work in reservedWorks {
            guard let candidate = work.passages.first else { continue }
            _ = append(candidate)
        }
        for work in reservedWorks {
            guard let candidate = work.passages.dropFirst().first else { continue }
            _ = append(candidate)
        }

        for work in works.dropFirst(reservedWorkCount) {
            guard let candidate = work.passages.first,
                  selected.count < passageLimit else { break }
            guard append(candidate) else { break }
        }

        guard selected.count < passageLimit else { return selected }
        for work in works {
            for candidate in work.passages.dropFirst() where !selectedIDs.contains(candidate.id) {
                guard selected.count < passageLimit else { return selected }
                let size = candidate.documentText.count
                guard usedCharacters + size <= characterBudget else { continue }
                selected.append(candidate)
                selectedIDs.insert(candidate.id)
                usedCharacters += size
                break
            }
        }
        return selected
    }
}

struct SearchIndexStatus: Sendable, Equatable {
    let indexedDocuments: Int
    let totalDocuments: Int
    let embeddedChunks: Int
    let totalChunks: Int
    let message: String?
    let isWorking: Bool

    static let idle = SearchIndexStatus(
        indexedDocuments: 0,
        totalDocuments: 0,
        embeddedChunks: 0,
        totalChunks: 0,
        message: nil,
        isWorking: false
    )
}

enum LocalSearchProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case balanced

    var id: String { rawValue }

    var title: String {
        "Qwen3.7 云端语义检索"
    }

    var modelDescription: String {
        "北京区百炼 qwen3.7-text-embedding·2560 维"
    }

    var modelID: String {
        "qwen3.7-text-embedding"
    }

    var revision: String {
        "cn-beijing-dashscope-v1"
    }

    var dimensions: Int {
        2_560
    }

    var batchSize: Int {
        20
    }

    var allowedBatchSizes: ClosedRange<Int> {
        1...20
    }

    func clampedBatchSize(_ value: Int) -> Int {
        min(max(value, allowedBatchSizes.lowerBound), allowedBatchSizes.upperBound)
    }

    var vectorSpaceSignature: String {
        "\(modelID)@\(revision):\(dimensions):normalized-v1"
    }
}

struct LocalSearchProfileStatistics: Sendable, Equatable {
    let profile: LocalSearchProfile
    let indexedDocuments: Int
    let totalDocuments: Int
    let embeddedChunks: Int
    let totalChunks: Int
    let failedChunks: Int
    let storedBytes: Int64

    var isComplete: Bool {
        totalChunks > 0 && embeddedChunks == totalChunks && failedChunks == 0
    }

    static func empty(_ profile: LocalSearchProfile) -> Self {
        .init(
            profile: profile,
            indexedDocuments: 0,
            totalDocuments: 0,
            embeddedChunks: 0,
            totalChunks: 0,
            failedChunks: 0,
            storedBytes: 0
        )
    }
}

enum LocalSearchMaintenanceState: Sendable, Equatable {
    case idle
    case running
    case pausing
    case paused
    case cancelling
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .running, .pausing, .paused, .cancelling: return true
        default: return false
        }
    }
}

enum LocalSearchMaintenanceStage: String, Sendable, Codable {
    case textExtraction
    case modelDownload
    case embedding
    case rerankerValidation
    case modelValidation
    case cleanup

    var title: String {
        switch self {
        case .textExtraction: return "正文提取"
        case .modelDownload: return "云端接口验证"
        case .embedding: return "向量生成"
        case .rerankerValidation: return "重排模型验证"
        case .modelValidation: return "模型推理测试"
        case .cleanup: return "索引清理"
        }
    }
}

struct LocalSearchProgress: Sendable, Equatable {
    let stage: LocalSearchMaintenanceStage
    let profile: LocalSearchProfile?
    let message: String
    let completed: Int64
    let total: Int64
    let estimatedCompletionDate: Date?

    init(
        stage: LocalSearchMaintenanceStage,
        profile: LocalSearchProfile?,
        message: String,
        completed: Int64,
        total: Int64,
        estimatedCompletionDate: Date? = nil
    ) {
        self.stage = stage
        self.profile = profile
        self.message = message
        self.completed = completed
        self.total = total
        self.estimatedCompletionDate = estimatedCompletionDate
    }

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct LocalSearchTimingEstimator: Sendable, Equatable {
    private(set) var secondsPerItemSamples: [TimeInterval] = []
    let maximumSampleCount: Int

    init(maximumSampleCount: Int = 50) {
        self.maximumSampleCount = max(1, maximumSampleCount)
    }

    var sampleCount: Int { secondsPerItemSamples.count }

    mutating func record(batchDuration: TimeInterval, completedItems: Int) {
        guard batchDuration.isFinite, batchDuration > 0, completedItems > 0 else { return }
        let secondsPerItem = batchDuration / Double(completedItems)
        secondsPerItemSamples.append(
            contentsOf: repeatElement(secondsPerItem, count: completedItems)
        )
        if secondsPerItemSamples.count > maximumSampleCount {
            secondsPerItemSamples.removeFirst(
                secondsPerItemSamples.count - maximumSampleCount
            )
        }
    }

    var estimatedSecondsPerItem: TimeInterval? {
        guard !secondsPerItemSamples.isEmpty else { return nil }
        let sorted = secondsPerItemSamples.sorted()
        let trimCount = sorted.count >= 10 ? max(1, sorted.count / 10) : 0
        let usable = sorted.dropFirst(trimCount).dropLast(trimCount)
        guard !usable.isEmpty else { return nil }
        return usable.reduce(0, +) / Double(usable.count)
    }

    func estimatedCompletionDate(
        remainingItems: Int,
        from date: Date = Date()
    ) -> Date? {
        guard remainingItems > 0, let secondsPerItem = estimatedSecondsPerItem else {
            return nil
        }
        let remainingSeconds = secondsPerItem * Double(remainingItems)
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return nil }
        return date.addingTimeInterval(remainingSeconds)
    }
}

struct LocalSearchFailure: Sendable, Equatable, Identifiable {
    let id: String
    let stage: LocalSearchMaintenanceStage
    let modelSignature: String?
    let workID: UUID?
    let chunkID: String?
    let startPage: Int?
    let endPage: Int?
    let message: String
    let occurredAt: Date
}

struct ModelDownloadProgress: Sendable, Equatable {
    let completed: Int64
    let total: Int64
}

struct LocalSearchEmbeddingTestReport: Sendable, Equatable {
    let profile: LocalSearchProfile
    let relevantSimilarity: Float
    let unrelatedSimilarity: Float
    let queryVectorLength: Float
}

struct LocalSearchRerankerTestReport: Sendable, Equatable {
    let relevantScore: Float
    let unrelatedScore: Float
}

struct LocalSearchModelTestResult: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let passed: Bool
    let duration: TimeInterval
    let finishedAt: Date

    var statusTitle: String {
        passed ? "通过" : "失败"
    }
}

enum LocalSearchWorkflowPolicy {
    static func canBuildSemanticIndex(
        allModelsVerified: Bool,
        modelsTested: Bool
    ) -> Bool {
        allModelsVerified && modelsTested
    }
}

typealias ModelDownloadProgressHandler = @Sendable (ModelDownloadProgress) -> Void

protocol TextEmbeddingProvider: Sendable {
    var profile: LocalSearchProfile { get }
    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws
    func prepareFromCache() async throws
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
    func embedQuery(_ text: String) async throws -> [Float]
    func release() async
}

protocol TextRerankingProvider: Sendable {
    var modelID: String { get }
    var revision: String { get }
    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws
    func prepareFromCache() async throws
    func scores(query: String, documents: [String]) async throws -> [Float]
    func release() async
}

enum SearchFusion {
    static func reciprocalRankFusion(
        rankings: [[String]],
        constant: Double = 60
    ) -> [String: Double] {
        var scores: [String: Double] = [:]
        for ranking in rankings {
            for (index, identifier) in ranking.enumerated() {
                scores[identifier, default: 0] += 1 / (constant + Double(index + 1))
            }
        }
        return scores
    }

    static func cosineSimilarity(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count, !left.isEmpty else { return -.infinity }
        var dot: Float = 0
        var leftLength: Float = 0
        var rightLength: Float = 0
        for index in left.indices {
            dot += left[index] * right[index]
            leftLength += left[index] * left[index]
            rightLength += right[index] * right[index]
        }
        let denominator = sqrt(leftLength) * sqrt(rightLength)
        return denominator > 0 ? dot / denominator : -.infinity
    }

    static func excerpt(_ text: String, matching terms: [String], limit: Int = 240) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let lowered = collapsed.lowercased()
        let match = terms.lazy.compactMap { lowered.range(of: $0.lowercased()) }.first
        let center = match.map { lowered.distance(from: lowered.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, min(collapsed.count - limit, center - limit / 3))
        let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let end = collapsed.index(start, offsetBy: min(limit, collapsed.distance(from: start, to: collapsed.endIndex)))
        let prefix = start == collapsed.startIndex ? "" : "…"
        let suffix = end == collapsed.endIndex ? "" : "…"
        return prefix + collapsed[start..<end] + suffix
    }

    static func normalizedTokenOverlap(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(LibrarySearchRules.queryTerms(left))
        let rightTokens = Set(LibrarySearchRules.queryTerms(right))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}

enum LocalSearchConfiguration {
    static let chunkSchemaVersion = 1
    static let obsoleteSelectedProfileKey = "localSearchSelectedProfile"
    static let obsoleteBatchSizeKeyPrefix = "localSearchEmbeddingBatchSizeV1."
    static let obsoleteModelMemoryLimitGiBKey = "localSearchModelMemoryLimitGiBV1"
    static let verifiedModelsKey = "localSearchVerifiedModelsV2"
    static let modelTestReceiptKey = "localSearchModelTestReceiptV2"
    static let pendingCleanupKeyPrefix = "localSearchPendingCleanupV1."
    static let bailianWorkspaceIDKey = "localSearchBailianBeijingWorkspaceIDV1"
    static let smartSearchDepthKey = "smartSearchDepthV1"
    static let smartSearchResultLimitKey = "smartSearchResultLimitV1"
    static let localModelCacheCleanupKey = "localSearchRemovedAllLocalModelsV2"
    static let localVectorCleanupKeyPrefix = "localSearchRemovedAllLocalVectorsV2."
    static let legacyBalancedVectorCleanupKeyPrefix = "localSearchRemovedQwen3Embedding4BVectorsV1."
    static let legacyBalancedModelID = "mlx-community/Qwen3-Embedding-4B-4bit-DWQ"
    static let legacyBalancedRevision = "b5d88f1fe49b50d2ac01b4692ca2d387f14f9c72"
    static let legacyBalancedDimensions = 2_560
    static let legacyFastVectorSpaceSignature =
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ@6c3ae70858513f1a78e9cdca3cae330d9075cd2a:1024:normalized-v1"
    static let legacyFastDimensions = 1_024
    static let rerankerModelID = "qwen3.7-text-rerank"
    static let rerankerRevision = "cn-beijing-maas-v1"
    static let solidRelevanceThreshold: Float = 0.50
    static let maximumPassagesPerWork = 2

    static var rerankerSignature: String {
        "\(rerankerModelID)@\(rerankerRevision)"
    }

    static var currentModelTestReceipt: String {
        let embeddings = LocalSearchProfile.allCases.map(\.vectorSpaceSignature).joined(separator: "|")
        return "semantic-health-v4|\(embeddings)|\(rerankerSignature)"
    }

    static var legacyBalancedVectorSpaceSignature: String {
        "\(legacyBalancedModelID)@\(legacyBalancedRevision):\(legacyBalancedDimensions):normalized-v1"
    }

    static func legacyBalancedVectorCleanupKey(libraryID: UUID) -> String {
        legacyBalancedVectorCleanupKeyPrefix + libraryID.uuidString
    }

    static func localVectorCleanupKey(libraryID: UUID) -> String {
        localVectorCleanupKeyPrefix + libraryID.uuidString
    }
}
