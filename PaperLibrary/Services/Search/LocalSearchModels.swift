import Foundation

struct BailianSearchCredentials: Sendable, Equatable {
    let workspaceID: String
    let apiKey: String
}

struct BailianAPIKeyStore: Sendable {
    static let shared = BailianAPIKeyStore()
    let fileURL: URL

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        let applicationSupport = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        fileURL = applicationSupport
            .appending(path: "PaperLibrary/Private", directoryHint: .isDirectory)
            .appending(path: "bailian-beijing-api-key")
    }

    func save(_ value: String, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(value.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    }

    func readIfAvailable() -> String? { try? read() }

    func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

enum BailianSearchConfiguration {
    static let queryInstruction =
        "Given a research paper query, retrieve relevant research paper passages."
    static let rerankInstruction =
        "Given a literature-search query, judge whether each passage answers or supports it."

    static func credentials(
        defaults: UserDefaults = .standard,
        keyStore: BailianAPIKeyStore = .shared
    ) throws -> BailianSearchCredentials {
        let workspaceID = defaults.string(forKey: LocalSearchConfiguration.bailianWorkspaceIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiKey = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !workspaceID.isEmpty, !apiKey.isEmpty else {
            throw BailianEmbeddingError.missingCredentials
        }
        guard isValidWorkspaceID(workspaceID) else {
            throw BailianEmbeddingError.invalidWorkspaceID
        }
        return BailianSearchCredentials(workspaceID: workspaceID, apiKey: apiKey)
    }

    static func isConfigured(
        defaults: UserDefaults = .standard,
        keyStore: BailianAPIKeyStore = .shared
    ) -> Bool {
        (try? credentials(defaults: defaults, keyStore: keyStore)) != nil
    }

    static func isValidWorkspaceID(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
                (97...122).contains(byte) || byte == 45
        }
    }

    static func embeddingEndpoint(workspaceID: String) throws -> URL {
        try endpoint(workspaceID: workspaceID,
                     path: "embeddings/text-embedding/text-embedding")
    }

    static func rerankEndpoint(workspaceID: String) throws -> URL {
        try endpoint(workspaceID: workspaceID,
                     path: "rerank/text-rerank/text-rerank")
    }

    private static func endpoint(workspaceID: String, path: String) throws -> URL {
        guard isValidWorkspaceID(workspaceID),
              let url = URL(string: "https://\(workspaceID).cn-beijing.maas.aliyuncs.com/api/v1/services/\(path)")
        else { throw BailianEmbeddingError.invalidWorkspaceID }
        return url
    }
}

actor BailianQwenEmbeddingProvider: TextEmbeddingProvider {
    typealias CredentialsProvider = @Sendable () throws -> BailianSearchCredentials
    nonisolated let profile = LocalSearchProfile.balanced
    private let session: URLSession
    private let credentialsProvider: CredentialsProvider

    init(
        session: URLSession = .shared,
        credentialsProvider: @escaping CredentialsProvider = {
            try BailianSearchConfiguration.credentials()
        }
    ) {
        self.session = session
        self.credentialsProvider = credentialsProvider
    }

    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws {
        progress(.init(completed: 0, total: 1))
        _ = try await embedDocuments(["用于验证文献语义检索接口的测试文本。"])
        progress(.init(completed: 1, total: 1))
    }

    func prepareFromCache() async throws { _ = try credentialsProvider() }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        guard texts.count <= profile.allowedBatchSizes.upperBound else {
            throw BailianEmbeddingError.tooManyInputs(
                maximum: profile.allowedBatchSizes.upperBound, actual: texts.count
            )
        }
        return try await requestEmbeddings(texts: texts, textType: "document", instruction: nil)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await requestEmbeddings(
            texts: [text], textType: "query",
            instruction: BailianSearchConfiguration.queryInstruction
        )[0]
    }

    func release() async {}

    private func requestEmbeddings(
        texts: [String], textType: String, instruction: String?
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await withBailianRetry {
            try await self.performRequest(texts: texts, textType: textType,
                                          instruction: instruction)
        }
    }

    private func performRequest(
        texts: [String], textType: String, instruction: String?
    ) async throws -> [[Float]] {
        try Task.checkCancellation()
        let credentials = try credentialsProvider()
        var request = URLRequest(url: try BailianSearchConfiguration.embeddingEndpoint(
            workspaceID: credentials.workspaceID
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BailianEmbeddingRequest(
            model: profile.modelID,
            input: .init(texts: texts),
            parameters: .init(dimension: profile.dimensions, outputType: "dense",
                              textType: textType, instruction: instruction)
        ))

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw BailianEmbeddingError.invalidResponse("服务器没有返回 HTTP 状态。")
        }
        let envelope = try? JSONDecoder().decode(BailianEmbeddingResponse.self, from: data)
        guard (200...299).contains(http.statusCode) else {
            throw BailianEmbeddingError.httpFailure(
                status: http.statusCode, code: envelope?.code, message: envelope?.message,
                requestID: envelope?.requestID
            )
        }
        guard let items = envelope?.output?.embeddings, items.count == texts.count else {
            throw BailianEmbeddingError.invalidResponse("返回的向量数量与输入片段数量不一致。")
        }
        let sortedItems = items.enumerated().sorted {
            ($0.element.textIndex ?? $0.offset) < ($1.element.textIndex ?? $1.offset)
        }
        return try sortedItems.map {
            try Self.normalizedVector($0.element.embedding, expected: profile.dimensions)
        }
    }

    private static func normalizedVector(_ vector: [Float], expected: Int) throws -> [Float] {
        guard vector.count == expected, vector.allSatisfy(\.isFinite) else {
            throw BailianEmbeddingError.invalidDimensions(expected: expected, actual: vector.count)
        }
        let squaredLength = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        let length = sqrt(squaredLength)
        guard length.isFinite, length > 0 else {
            throw BailianEmbeddingError.invalidResponse("模型返回了零长度向量。")
        }
        return vector.map { Float(Double($0) / length) }
    }
}

actor BailianQwenRerankingProvider: TextRerankingProvider {
    typealias CredentialsProvider = @Sendable () throws -> BailianSearchCredentials
    nonisolated let modelID = LocalSearchConfiguration.rerankerModelID
    nonisolated let revision = LocalSearchConfiguration.rerankerRevision
    private let session: URLSession
    private let credentialsProvider: CredentialsProvider

    init(
        session: URLSession = .shared,
        credentialsProvider: @escaping CredentialsProvider = {
            try BailianSearchConfiguration.credentials()
        }
    ) {
        self.session = session
        self.credentialsProvider = credentialsProvider
    }

    func prepare(progress: @escaping ModelDownloadProgressHandler) async throws {
        progress(.init(completed: 0, total: 1))
        _ = try await scores(query: "文献检索", documents: ["文献检索"])
        progress(.init(completed: 1, total: 1))
    }

    func prepareFromCache() async throws { _ = try credentialsProvider() }

    func scores(query: String, documents: [String]) async throws -> [Float] {
        guard !documents.isEmpty else { return [] }
        guard documents.count <= 500 else {
            throw BailianEmbeddingError.tooManyInputs(maximum: 500, actual: documents.count)
        }
        return try await withBailianRetry {
            try await self.performRequest(query: query, documents: documents)
        }
    }

    func release() async {}

    private func performRequest(query: String, documents: [String]) async throws -> [Float] {
        try Task.checkCancellation()
        let credentials = try credentialsProvider()
        var request = URLRequest(url: try BailianSearchConfiguration.rerankEndpoint(
            workspaceID: credentials.workspaceID
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BailianRerankRequest(
            model: modelID,
            input: .init(query: query, documents: documents),
            parameters: .init(topN: documents.count,
                              instruction: BailianSearchConfiguration.rerankInstruction)
        ))

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw BailianEmbeddingError.invalidResponse("服务器没有返回 HTTP 状态。")
        }
        let envelope = try? JSONDecoder().decode(BailianRerankResponse.self, from: data)
        guard (200...299).contains(http.statusCode) else {
            throw BailianEmbeddingError.httpFailure(
                status: http.statusCode, code: envelope?.code, message: envelope?.message,
                requestID: envelope?.requestID
            )
        }
        guard let results = envelope?.output?.results, results.count == documents.count else {
            throw BailianEmbeddingError.invalidResponse("返回的重排得分数量与候选片段数量不一致。")
        }
        var values = Array(repeating: Float.nan, count: documents.count)
        for result in results {
            guard values.indices.contains(result.index), values[result.index].isNaN,
                  result.relevanceScore.isFinite else {
                throw BailianEmbeddingError.invalidResponse("重排结果的索引或得分无效。")
            }
            values[result.index] = result.relevanceScore
        }
        guard values.allSatisfy(\.isFinite) else {
            throw BailianEmbeddingError.invalidResponse("重排结果不完整。")
        }
        return values
    }
}

private func withBailianRetry<T: Sendable>(
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    for attempt in 0..<3 {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard attempt < 2, isTransientBailianError(error) else { throw error }
            try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
        }
    }
    throw BailianEmbeddingError.invalidResponse("重试后仍未取得有效结果。")
}

private func isTransientBailianError(_ error: Error) -> Bool {
    if let error = error as? BailianEmbeddingError { return error.isTransient }
    guard let error = error as? URLError else { return false }
    return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
}

private struct BailianEmbeddingRequest: Encodable {
    struct Input: Encodable { let texts: [String] }
    struct Parameters: Encodable {
        let dimension: Int
        let outputType: String
        let textType: String
        let instruction: String?
        enum CodingKeys: String, CodingKey {
            case dimension
            case outputType = "output_type"
            case textType = "text_type"
            case instruction = "instruct"
        }
    }
    let model: String
    let input: Input
    let parameters: Parameters
}

private struct BailianEmbeddingResponse: Decodable {
    struct Output: Decodable {
        struct Item: Decodable {
            let textIndex: Int?
            let embedding: [Float]
            enum CodingKeys: String, CodingKey {
                case textIndex = "text_index"
                case embedding
            }
        }
        let embeddings: [Item]
    }
    let output: Output?
    let code: String?
    let message: String?
    let requestID: String?
    enum CodingKeys: String, CodingKey {
        case output, code, message
        case requestID = "request_id"
    }
}

private struct BailianRerankRequest: Encodable {
    struct Input: Encodable { let query: String; let documents: [String] }
    struct Parameters: Encodable {
        let topN: Int
        let instruction: String
        enum CodingKeys: String, CodingKey {
            case topN = "top_n"
            case instruction = "instruct"
        }
    }
    let model: String
    let input: Input
    let parameters: Parameters
}

private struct BailianRerankResponse: Decodable {
    struct Output: Decodable {
        struct Item: Decodable {
            let index: Int
            let relevanceScore: Float
            enum CodingKeys: String, CodingKey {
                case index
                case relevanceScore = "relevance_score"
            }
        }
        let results: [Item]
    }
    let output: Output?
    let code: String?
    let message: String?
    let requestID: String?
    enum CodingKeys: String, CodingKey {
        case output, code, message
        case requestID = "request_id"
    }
}

actor LocalSearchExecutionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked { isLocked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { isLocked = false; return }
        waiters.removeFirst().resume()
    }
}

actor LocalSearchModelRuntime {
    private let gate = LocalSearchExecutionGate()
    private let embedder: any TextEmbeddingProvider
    private let reranker: any TextRerankingProvider

    init(
        embedder: any TextEmbeddingProvider = BailianQwenEmbeddingProvider(),
        reranker: any TextRerankingProvider = BailianQwenRerankingProvider()
    ) {
        self.embedder = embedder
        self.reranker = reranker
    }

    func prepareEmbedding(profile: LocalSearchProfile,
                          progress: @escaping ModelDownloadProgressHandler) async throws {
        try await exclusively { try await self.embedder.prepareFromCache() }
    }

    func downloadEmbedding(profile: LocalSearchProfile,
                           progress: @escaping ModelDownloadProgressHandler) async throws {
        try await exclusively { try await self.embedder.prepare(progress: progress) }
    }

    func embedDocuments(profile: LocalSearchProfile, texts: [String],
                        progress: @escaping ModelDownloadProgressHandler = { _ in }) async throws -> [[Float]] {
        try await exclusively { try await self.embedder.embedDocuments(texts) }
    }

    func embedQuery(profile: LocalSearchProfile, text: String,
                    progress: @escaping ModelDownloadProgressHandler = { _ in }) async throws -> [Float] {
        try await exclusively { try await self.embedder.embedQuery(text) }
    }

    func validateEmbedding(profile: LocalSearchProfile) async throws -> LocalSearchEmbeddingTestReport {
        try await exclusively {
            let query = "企业融资约束如何影响投资决策？"
            let documents = ["融资约束会提高外部融资成本，从而抑制企业投资。",
                             "恒星光谱可以用于分析遥远星系的化学组成。"]
            let queryVector = try await self.embedder.embedQuery(query)
            let vectors = try await self.embedder.embedDocuments(documents)
            guard queryVector.count == profile.dimensions, vectors.count == 2,
                  vectors.allSatisfy({ $0.count == profile.dimensions }) else {
                throw LocalSearchModelError.invalidEmbeddingResponse(profile.title)
            }
            let length = sqrt(queryVector.reduce(Float.zero) { $0 + $1 * $1 })
            let relevant = SearchFusion.cosineSimilarity(queryVector, vectors[0])
            let unrelated = SearchFusion.cosineSimilarity(queryVector, vectors[1])
            guard length.isFinite, (0.8...1.2).contains(length), relevant > unrelated else {
                throw LocalSearchModelError.embeddingSemanticCheckFailed(
                    profile: profile.title, relevant: relevant, unrelated: unrelated
                )
            }
            return .init(profile: profile, relevantSimilarity: relevant,
                         unrelatedSimilarity: unrelated, queryVectorLength: length)
        }
    }

    func downloadAndValidateReranker(progress: @escaping ModelDownloadProgressHandler) async throws {
        try await exclusively { try await self.reranker.prepare(progress: progress) }
    }

    func validateReranker() async throws -> LocalSearchRerankerTestReport {
        try await exclusively {
            let values = try await self.reranker.scores(
                query: "企业融资约束如何影响投资决策？",
                documents: ["融资约束会提高外部融资成本，从而抑制企业投资。",
                            "恒星光谱可以用于分析遥远星系的化学组成。"]
            )
            guard values.count == 2, values.allSatisfy(\.isFinite), values[0] > values[1] else {
                throw LocalSearchModelError.rerankerSemanticCheckFailed(
                    relevant: values.first ?? -.infinity,
                    unrelated: values.count > 1 ? values[1] : -.infinity
                )
            }
            return .init(relevantScore: values[0], unrelatedScore: values[1])
        }
    }

    func rerank(query: String, documents: [String],
                progress: @escaping ModelDownloadProgressHandler = { _ in }) async throws -> [Float] {
        try await exclusively { try await self.reranker.scores(query: query, documents: documents) }
    }

    func releaseAll() async {}
    private func exclusively<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        do {
            let result = try await operation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }
}

enum LegacyLocalModelCacheCleaner {
    static let modelIDs = ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                           "mlx-community/Qwen3-Reranker-0.6B-4bit",
                           "mlx-community/Qwen3-Embedding-4B-4bit-DWQ"]

    static func removeKnownRepositories(
        cacheRoot: URL? = nil, fileManager: FileManager = .default
    ) throws {
        let root = (cacheRoot ?? defaultCacheRoot(fileManager: fileManager)).standardizedFileURL
        for modelID in modelIDs {
            let name = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
            let targets = [root.appending(path: name, directoryHint: .isDirectory),
                           root.appending(path: ".metadata", directoryHint: .isDirectory)
                            .appending(path: name, directoryHint: .isDirectory),
                           root.appending(path: ".locks", directoryHint: .isDirectory)
                            .appending(path: name, directoryHint: .isDirectory)]
            for target in targets {
                try validate(target: target, root: root)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            }
        }
    }

    private static func defaultCacheRoot(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: "hub", directoryHint: .isDirectory)
    }

    private static func validate(target: URL, root: URL) throws {
        let standardized = target.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard standardized.path.hasPrefix(rootPath),
              standardized.lastPathComponent.hasPrefix("models--") else {
            throw LocalSearchModelError.unsafeCachePath(target.path)
        }
    }
}

enum LocalSearchModelError: LocalizedError {
    case invalidEmbeddingResponse(String)
    case embeddingSemanticCheckFailed(profile: String, relevant: Float, unrelated: Float)
    case rerankerSemanticCheckFailed(relevant: Float, unrelated: Float)
    case unsafeCachePath(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEmbeddingResponse(profile):
            return "\(profile)模型返回的向量维度或数值无效。"
        case let .embeddingSemanticCheckFailed(profile, relevant, unrelated):
            return "\(profile)模型未通过语义区分测试：相关文本 \(relevant)，无关文本 \(unrelated)。"
        case let .rerankerSemanticCheckFailed(relevant, unrelated):
            return "重排模型未通过顺序测试：相关文本 \(relevant)，无关文本 \(unrelated)。"
        case let .unsafeCachePath(path):
            return "拒绝删除无法确认的模型缓存路径：\(path)"
        }
    }
}

enum BailianEmbeddingError: LocalizedError {
    case missingCredentials
    case invalidWorkspaceID
    case tooManyInputs(maximum: Int, actual: Int)
    case httpFailure(status: Int, code: String?, message: String?, requestID: String?)
    case invalidDimensions(expected: Int, actual: Int)
    case invalidResponse(String)

    var isTransient: Bool {
        guard case let .httpFailure(status, _, _, _) = self else { return false }
        return [408, 429, 500, 502, 503, 504].contains(status)
    }

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先在设置中保存北京区百炼业务空间编号和 API 密钥。"
        case .invalidWorkspaceID:
            return "北京区百炼业务空间编号格式无效。"
        case let .tooManyInputs(maximum, actual):
            return "单次最多提交 \(maximum) 个片段，当前为 \(actual) 个。"
        case let .httpFailure(status, code, message, requestID):
            let details = [code, message, requestID.map { "请求编号 \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
            return details.isEmpty ? "北京区百炼接口返回 HTTP \(status)。"
                : "北京区百炼接口返回 HTTP \(status)：\(details)"
        case let .invalidDimensions(expected, actual):
            return "北京区百炼接口返回了 \(actual) 维向量，预期为 \(expected) 维。"
        case let .invalidResponse(message):
            return "北京区百炼接口响应无效：\(message)"
        }
    }
}
