import Combine
import Foundation

@MainActor
final class SearchIndexCoordinator: ObservableObject {
    @Published private(set) var resultVersion: UInt64 = 0
    @Published private(set) var keywordMatches: [UUID: SearchWorkMatch] = [:] {
        didSet { resultVersion &+= 1 }
    }
    @Published private(set) var smartMatches: [UUID: SearchWorkMatch] = [:] {
        didSet { resultVersion &+= 1 }
    }
    @Published private(set) var isSmartMode = false
    @Published private(set) var isSearching = false
    @Published private(set) var status: SearchIndexStatus = .idle
    @Published private(set) var profileStatistics: [LocalSearchProfile: LocalSearchProfileStatistics] = [
        .balanced: .empty(.balanced),
    ]
    @Published private(set) var maintenanceState: LocalSearchMaintenanceState = .idle
    @Published private(set) var maintenanceProgress: LocalSearchProgress?
    @Published private(set) var failures: [LocalSearchFailure] = []
    @Published private(set) var pendingCleanupCount = 0
    @Published private(set) var smartSearchNotice: String?
    @Published private(set) var smartSearchResultLimit = 10
    @Published private(set) var smartSearchQuery = ""
    @Published private(set) var smartSearchScopeRevision: UInt64?
    @Published private(set) var verifiedModelSignatures: Set<String>
    @Published private(set) var modelsTested: Bool
    @Published private(set) var modelTestResults: [LocalSearchModelTestResult] = []
    @Published private(set) var bailianWorkspaceID = ""
    @Published var errorText: String?
    @Published private(set) var selectedProfile = LocalSearchProfile.balanced

    private struct RerankedCandidate: Sendable {
        let candidate: SmartSearchRerankCandidate
        let rawScore: Double
        let relativeScore: Double
        let fusionScore: Double
    }

    private var store: SearchIndexStore?
    private var configuredLibraryID: UUID?
    private var rootURL: URL?
    private var snapshots: [SearchDocumentSnapshot] = []
    private var textIndexTask: Task<Void, Never>?
    private var keywordTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var smartRequestID: UUID?
    private var maintenanceTask: Task<Void, Never>?
    private var legacyCacheCleanupTask: Task<Void, Never>?
    private var pauseRequested = false
    private var pendingCleanupWorkIDs: Set<UUID> = []
    private var embeddingTimingEstimators: [LocalSearchProfile: LocalSearchTimingEstimator] = [
        .balanced: LocalSearchTimingEstimator(),
    ]
    private let modelRuntime: LocalSearchModelRuntime
    private let defaults: UserDefaults
    private let bailianKeyStore: BailianAPIKeyStore

    init(
        modelRuntime: LocalSearchModelRuntime = LocalSearchModelRuntime(),
        defaults: UserDefaults? = nil,
        bailianKeyStore: BailianAPIKeyStore = .shared
    ) {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else if AppRuntimeEnvironment.isRunningTests {
            resolvedDefaults = UserDefaults(
                suiteName: "dev.paperlibrary.PaperLibrary.SearchTests.\(ProcessInfo.processInfo.processIdentifier)"
            )!
        } else {
            resolvedDefaults = .standard
        }
        self.defaults = resolvedDefaults
        self.modelRuntime = modelRuntime
        self.bailianKeyStore = bailianKeyStore
        bailianWorkspaceID = resolvedDefaults.string(
            forKey: LocalSearchConfiguration.bailianWorkspaceIDKey
        ) ?? ""
        let needsLegacyCacheCleanup = !AppRuntimeEnvironment.isRunningTests &&
            !resolvedDefaults.bool(forKey: LocalSearchConfiguration.localModelCacheCleanupKey)
        if needsLegacyCacheCleanup {
            resolvedDefaults.removeObject(forKey: LocalSearchConfiguration.obsoleteSelectedProfileKey)
            resolvedDefaults.removeObject(forKey: LocalSearchConfiguration.obsoleteModelMemoryLimitGiBKey)
            resolvedDefaults.removeObject(forKey: LocalSearchConfiguration.obsoleteBatchSizeKeyPrefix + "fast")
            resolvedDefaults.removeObject(forKey: LocalSearchConfiguration.obsoleteBatchSizeKeyPrefix + "balanced")
        }
        let savedSignatures = Set(
            resolvedDefaults.stringArray(forKey: LocalSearchConfiguration.verifiedModelsKey) ?? []
        )
        let availableSignatures = savedSignatures.filter { signature in
            let isRequired = signature == LocalSearchConfiguration.rerankerSignature ||
                signature == LocalSearchProfile.balanced.vectorSpaceSignature
            return isRequired && BailianSearchConfiguration.isConfigured(
                defaults: resolvedDefaults,
                keyStore: bailianKeyStore
            )
        }
        verifiedModelSignatures = availableSignatures
        let requiredSignatures = Set(
            LocalSearchProfile.allCases.map(\.vectorSpaceSignature) +
                [LocalSearchConfiguration.rerankerSignature]
        )
        modelsTested = requiredSignatures.isSubset(of: availableSignatures) &&
            resolvedDefaults.string(
                forKey: LocalSearchConfiguration.modelTestReceiptKey
            ) == LocalSearchConfiguration.currentModelTestReceipt
        persistVerifiedModels()
        if needsLegacyCacheCleanup {
            legacyCacheCleanupTask = Task { [weak self] in
                do {
                    try await Task.detached(priority: .utility) {
                        try LegacyLocalModelCacheCleaner.removeKnownRepositories()
                    }.value
                    guard let self else { return }
                    self.defaults.set(
                        true,
                        forKey: LocalSearchConfiguration.localModelCacheCleanupKey
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.errorText = "旧本地模型缓存删除失败，将在下次打开应用时重试：\(error.localizedDescription)"
                }
            }
        }
    }

    deinit {
        textIndexTask?.cancel()
        keywordTask?.cancel()
        smartTask?.cancel()
        maintenanceTask?.cancel()
        legacyCacheCleanupTask?.cancel()
    }

    var isRerankerVerified: Bool {
        verifiedModelSignatures.contains(LocalSearchConfiguration.rerankerSignature)
    }

    var allModelsVerified: Bool {
        LocalSearchProfile.allCases.allSatisfy {
            verifiedModelSignatures.contains($0.vectorSpaceSignature)
        } && isRerankerVerified
    }

    var modelsReadyForIndexing: Bool {
        LocalSearchWorkflowPolicy.canBuildSemanticIndex(
            allModelsVerified: allModelsVerified,
            modelsTested: modelsTested
        )
    }

    var modelDownloadButtonTitle: String {
        allModelsVerified ? "重新验证云端语义服务" : "验证云端语义服务"
    }

    var isBailianConfigured: Bool {
        BailianSearchConfiguration.isConfigured(
            defaults: defaults,
            keyStore: bailianKeyStore
        )
    }

    func saveBailianConfiguration(workspaceID: String, apiKey: String) throws {
        guard !maintenanceState.isActive else { return }
        let trimmedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWorkspaceID.isEmpty && trimmedAPIKey.isEmpty {
            try bailianKeyStore.delete()
            defaults.removeObject(forKey: LocalSearchConfiguration.bailianWorkspaceIDKey)
            bailianWorkspaceID = ""
        } else {
            guard !trimmedWorkspaceID.isEmpty, !trimmedAPIKey.isEmpty else {
                throw BailianEmbeddingError.missingCredentials
            }
            guard BailianSearchConfiguration.isValidWorkspaceID(trimmedWorkspaceID) else {
                throw BailianEmbeddingError.invalidWorkspaceID
            }
            try bailianKeyStore.save(trimmedAPIKey)
            defaults.set(
                trimmedWorkspaceID,
                forKey: LocalSearchConfiguration.bailianWorkspaceIDKey
            )
            bailianWorkspaceID = trimmedWorkspaceID
        }
        verifiedModelSignatures.remove(LocalSearchProfile.balanced.vectorSpaceSignature)
        verifiedModelSignatures.remove(LocalSearchConfiguration.rerankerSignature)
        modelsTested = false
        modelTestResults = []
        defaults.removeObject(forKey: LocalSearchConfiguration.modelTestReceiptKey)
        persistVerifiedModels()
    }

    var vectorMaintenanceButtonTitle: String {
        return profileStatistics.values.contains(where: { $0.embeddedChunks > 0 })
            ? "补齐缺失向量"
            : "建立全部语义索引"
    }

    var modelTestReportText: String {
        guard !modelTestResults.isEmpty else { return "" }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "未知"
        var lines = [
            "文献库智能搜索模型测试报告",
            "应用版本：\(version)（\(build)）",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "总体结果：\(modelsTested ? "通过" : "未通过")",
            "测试签名：\(LocalSearchConfiguration.currentModelTestReceipt)",
            "",
        ]
        for result in modelTestResults {
            lines.append("[\(result.statusTitle)] \(result.title)")
            lines.append(result.detail)
            lines.append(String(format: "耗时：%.2f 秒", result.duration))
            lines.append("时间：\(result.finishedAt.formatted(date: .numeric, time: .standard))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func isModelVerified(_ profile: LocalSearchProfile) -> Bool {
        verifiedModelSignatures.contains(profile.vectorSpaceSignature)
    }

    func configure(
        libraryID: UUID,
        rootURL: URL,
        snapshots: [SearchDocumentSnapshot]
    ) {
        do {
            let standardizedRoot = rootURL.standardizedFileURL
            if configuredLibraryID == libraryID,
               self.rootURL?.standardizedFileURL == standardizedRoot,
               self.snapshots == snapshots {
                Task { await refreshPublishedState(message: nil, isWorking: false) }
                return
            }
            if configuredLibraryID != libraryID {
                textIndexTask?.cancel()
                keywordTask?.cancel()
                smartTask?.cancel()
                smartTask = nil
                smartRequestID = nil
                maintenanceTask?.cancel()
                store = try SearchIndexStore(libraryID: libraryID)
                configuredLibraryID = libraryID
                pendingCleanupWorkIDs = Set(
                    (defaults.stringArray(
                        forKey: Self.pendingCleanupKey(libraryID: libraryID)
                    ) ?? []).compactMap(UUID.init(uuidString:))
                )
                pendingCleanupCount = pendingCleanupWorkIDs.count
                keywordMatches = [:]
                smartMatches = [:]
                smartSearchQuery = ""
                smartSearchScopeRevision = nil
                isSmartMode = false
                maintenanceState = .idle
                maintenanceProgress = nil
            }
            self.rootURL = standardizedRoot
            self.snapshots = snapshots
            scheduleTextIndex()
        } catch {
            errorText = "无法创建搜索索引：\(error.localizedDescription)"
        }
    }

    func searchKeywords(
        _ query: String,
        matchMode: LibrarySearchMatchMode = .allTerms
    ) {
        keywordTask?.cancel()
        guard let store else {
            keywordMatches = [:]
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keywordMatches = [:]
            smartMatches = [:]
            smartSearchNotice = nil
            isSmartMode = false
            return
        }
        keywordTask = Task {
            do {
                let retrievalMode: LibrarySearchMatchMode = matchMode == .allTerms
                    ? .anyTerm
                    : matchMode
                let retrieved = try await store.keywordSearch(
                    trimmed,
                    matchMode: retrievalMode,
                    limit: matchMode == .allTerms ? 240 : 100
                )
                let hits = matchMode == .allTerms
                    ? Self.hitsContainingAllTerms(retrieved, query: trimmed)
                    : retrieved
                try Task.checkCancellation()
                keywordMatches = Self.groupKeywordHits(hits, query: trimmed)
                if isSmartMode {
                    isSmartMode = false
                    smartMatches = [:]
                    smartSearchNotice = nil
                }
            } catch is CancellationError {
                return
            } catch {
                errorText = "搜索正文失败：\(error.localizedDescription)"
            }
        }
    }

    func runSmartSearch(
        _ query: String,
        scope: SmartSearchScope,
        preferences: SmartSearchPreferences
    ) {
        smartTask?.cancel()
        smartTask = nil
        smartRequestID = nil
        keywordTask?.cancel()
        guard let store else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        smartSearchResultLimit = preferences.resultLimit
        smartSearchQuery = trimmed
        smartSearchScopeRevision = scope.revision
        smartMatches = [:]
        smartSearchNotice = nil
        guard !scope.allowedWorkIDs.isEmpty else {
            isSmartMode = true
            isSearching = false
            smartSearchNotice = "当前范围没有可搜索的文献。"
            return
        }
        guard isModelVerified(selectedProfile), isRerankerVerified else {
            errorText = "请先在设置的“智能搜索”中验证云端语义服务。"
            return
        }
        guard modelsTested else {
            errorText = "云端语义服务尚未通过实际推理测试，请在设置中重新验证。"
            return
        }
        let profile = selectedProfile
        guard (profileStatistics[profile]?.embeddedChunks ?? 0) > 0 else {
            errorText = "\(profile.title)模式还没有可用向量，请在设置中执行“补齐缺失向量”。"
            return
        }

        isSearching = true
        isSmartMode = true
        smartSearchNotice = nil
        let requestID = UUID()
        smartRequestID = requestID
        smartTask = Task {
            do {
                if let textIndexTask { await textIndexTask.value }
                try Task.checkCancellation()
                let missingDocuments = try await store.documentsMissingEmbeddings(
                    signature: profile.vectorSpaceSignature,
                    allowedWorkIDs: scope.allowedWorkIDs
                )
                status = makeStatus(
                    profile: profile,
                    message: "正在理解查询…",
                    isWorking: true
                )

                async let keywordHitsRequest = store.keywordSearch(
                    trimmed,
                    matchMode: .anyTerm,
                    limit: preferences.depth.channelLimit,
                    allowedWorkIDs: scope.allowedWorkIDs,
                    maximumHitsPerWork: 2
                )
                let queryVector = try await modelRuntime.embedQuery(profile: profile, text: trimmed)
                async let semanticRequest = store.topSemanticCandidates(
                    queryVector: queryVector,
                    signature: profile.vectorSpaceSignature,
                    limit: preferences.depth.channelLimit,
                    allowedWorkIDs: scope.allowedWorkIDs,
                    maximumHitsPerWork: 2
                )
                let metadataWorkIDs = metadataWorkRanking(
                    query: trimmed,
                    allowedWorkIDs: scope.allowedWorkIDs,
                    limit: preferences.depth.channelLimit
                )
                let (keywordHits, semantic) = try await (
                    keywordHitsRequest,
                    semanticRequest
                )
                try Task.checkCancellation()

                let keywordWorkRanking = SmartSearchCandidateBuilder.uniqueWorkRanking(
                    keywordHits.map(\.chunk.workID)
                )
                let semanticWorkRanking = SmartSearchCandidateBuilder.uniqueWorkRanking(
                    semantic.map(\.workID)
                )
                let fusedWorks = SmartSearchCandidateBuilder.fusedWorkRanking(
                    keyword: keywordWorkRanking,
                    semantic: semanticWorkRanking,
                    metadata: metadataWorkIDs,
                    limit: preferences.depth.fusedWorkLimit
                )
                let firstChunkIDs = try await store.firstChunkIDs(
                    workIDs: Set(fusedWorks.map(\.workID))
                )
                let requiredChunkIDs = Set(
                    keywordHits.map(\.chunk.id) +
                        semantic.map(\.chunkID) +
                        Array(firstChunkIDs.values)
                )
                let candidateChunks = try await store.chunks(ids: requiredChunkIDs)
                var chunksByID = Dictionary(uniqueKeysWithValues: candidateChunks.map { ($0.id, $0) })
                let vectorsByID = Dictionary(uniqueKeysWithValues: semantic.map { ($0.chunkID, $0.vector) })
                for hit in keywordHits { chunksByID[hit.chunk.id] = hit.chunk }
                let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.workID, $0) })
                let keywordByWork = Dictionary(grouping: keywordHits, by: { $0.chunk.workID })
                let semanticByWork = Dictionary(grouping: semantic, by: \.workID)
                let workCandidates = fusedWorks.compactMap { ranked -> SmartSearchWorkCandidate? in
                    guard let snapshot = snapshotByID[ranked.workID] else { return nil }
                    let keywordIDs = keywordByWork[ranked.workID, default: []].map(\.chunk.id)
                    let semanticIDs = semanticByWork[ranked.workID, default: []].map(\.chunkID)
                    let passageScores = SearchFusion.reciprocalRankFusion(
                        rankings: [keywordIDs, semanticIDs]
                    )
                    var passageIDs = passageScores.sorted {
                        if $0.value == $1.value { return $0.key < $1.key }
                        return $0.value > $1.value
                    }.prefix(2).map(\.key)
                    if let firstChunkID = firstChunkIDs[ranked.workID],
                       !passageIDs.contains(firstChunkID) {
                        // 保留最强召回段落作为首选，紧随其后补充文章开头作为阅读入口候选。
                        passageIDs.insert(firstChunkID, at: min(1, passageIDs.count))
                    }
                    var passages = passageIDs.compactMap { chunkID -> SmartSearchRerankCandidate? in
                        guard let chunk = chunksByID[chunkID] else { return nil }
                        return SmartSearchRerankCandidate(
                            id: chunk.id,
                            workID: ranked.workID,
                            chunk: chunk,
                            vector: vectorsByID[chunk.id],
                            fusionScore: ranked.score,
                            documentText: Self.rerankDocumentText(snapshot: snapshot, chunk: chunk)
                        )
                    }
                    if passages.isEmpty {
                        passages = [SmartSearchRerankCandidate(
                            id: "metadata:\(ranked.workID.uuidString)",
                            workID: ranked.workID,
                            chunk: nil,
                            vector: nil,
                            fusionScore: ranked.score,
                            documentText: Self.rerankDocumentText(snapshot: snapshot, chunk: nil)
                        )]
                    }
                    return SmartSearchWorkCandidate(
                        workID: ranked.workID,
                        fusionScore: ranked.score,
                        passages: passages
                    )
                }
                let candidates = SmartSearchCandidateBuilder.selectRerankCandidates(
                    works: workCandidates,
                    passageLimit: preferences.depth.rerankPassageLimit,
                    characterBudget: preferences.depth.characterBudget,
                    prioritySecondaryCount: preferences.resultLimit
                )

                guard !candidates.isEmpty else {
                    guard smartRequestID == requestID else { return }
                    smartMatches = [:]
                    smartSearchNotice = missingDocuments > 0
                        ? "尚有 \(missingDocuments) 篇文献未纳入语义搜索。"
                        : "未找到可供重排的文献。"
                    finishSmartSearch(profile: profile)
                    return
                }

                status = makeStatus(profile: profile, message: "正在重排候选段落…", isWorking: true)
                let reranked = try await modelRuntime.rerank(
                    query: trimmed,
                    documents: candidates.map(\.documentText)
                )
                try Task.checkCancellation()
                guard reranked.count == candidates.count else {
                    throw SearchCoordinatorError.invalidRerankerCount
                }

                let relativeScores = Self.relativeRerankScores(reranked)
                let scored = zip(zip(candidates, reranked), relativeScores).map {
                    candidateAndRawScore, relativeScore in
                    RerankedCandidate(
                        candidate: candidateAndRawScore.0,
                        rawScore: Double(candidateAndRawScore.1),
                        relativeScore: Double(relativeScore),
                        fusionScore: candidateAndRawScore.0.fusionScore
                    )
                }
                let matches = makeSmartMatches(
                    scored,
                    query: trimmed,
                    resultLimit: preferences.resultLimit,
                    snapshots: snapshotByID
                )
                guard smartRequestID == requestID else { return }
                smartMatches = matches

                var notices: [String] = []
                if matches.isEmpty {
                    notices.append("未找到可用的候选内容。")
                }
                if missingDocuments > 0 {
                    notices.append("尚有 \(missingDocuments) 篇文献未纳入语义搜索。")
                }
                smartSearchNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
                finishSmartSearch(profile: profile)
            } catch is CancellationError {
                guard smartRequestID == requestID else { return }
                smartRequestID = nil
                smartTask = nil
                isSearching = false
                status = makeStatus(profile: profile, message: nil, isWorking: false)
            } catch {
                guard smartRequestID == requestID else { return }
                smartRequestID = nil
                smartTask = nil
                isSearching = false
                isSmartMode = false
                errorText = "智能搜索失败：\(error.localizedDescription)"
                status = makeStatus(profile: profile, message: nil, isWorking: false)
            }
        }
    }

    func cancelSmartSearch() {
        smartTask?.cancel()
        smartTask = nil
        smartRequestID = nil
        smartSearchQuery = ""
        smartSearchScopeRevision = nil
        isSearching = false
        isSmartMode = false
        smartMatches = [:]
        smartSearchNotice = nil
    }

    func invalidateSmartSearchForScopeChange() {
        let hadSearch = isSearching || isSmartMode || !smartMatches.isEmpty
        smartTask?.cancel()
        smartTask = nil
        smartRequestID = nil
        smartSearchQuery = ""
        smartSearchScopeRevision = nil
        isSearching = false
        isSmartMode = false
        smartMatches = [:]
        if hadSearch {
            smartSearchNotice = "搜索范围已变化，请重新搜索。"
        }
    }

    func downloadAllModels() {
        guard isBailianConfigured else {
            errorText = "请先保存北京区百炼业务空间编号和 API 密钥。"
            return
        }
        startModelDownload()
    }

    func updateMissingVectors() {
        guard allModelsVerified else {
            errorText = "请先验证云端语义服务，再建立语义索引。"
            return
        }
        guard modelsTested else {
            errorText = "云端语义服务尚未通过实际推理测试，请重新验证。"
            return
        }
        startMaintenance(profiles: [.balanced], clearProfiles: [])
    }

    func pauseMaintenance() {
        guard maintenanceState == .running else { return }
        pauseRequested = true
        maintenanceState = .pausing
    }

    func resumeMaintenance() {
        guard maintenanceState == .paused || maintenanceState == .pausing else { return }
        pauseRequested = false
        maintenanceState = .running
    }

    func cancelMaintenance() {
        guard maintenanceState.isActive else { return }
        maintenanceState = .cancelling
        pauseRequested = false
        maintenanceTask?.cancel()
    }

    func retryFailedItems() {
        guard let store, !maintenanceState.isActive else { return }
        guard modelsReadyForIndexing else {
            errorText = "请先验证云端语义服务，再重试失败项。"
            return
        }
        Task {
            do {
                try await store.prepareFailuresForRetry()
                scheduleTextIndex()
                updateMissingVectors()
            } catch {
                errorText = "重置失败项失败：\(error.localizedDescription)"
            }
        }
    }

    func rebuild(profile: LocalSearchProfile) {
        guard modelsReadyForIndexing else {
            errorText = "请先验证云端语义服务，再重建语义索引。"
            return
        }
        startMaintenance(profiles: [profile], clearProfiles: [profile])
    }

    func removeDocuments(workIDs: Set<UUID>) async {
        guard let store, !workIDs.isEmpty else { return }
        do {
            try await store.removeDocuments(workIDs: workIDs)
            pendingCleanupWorkIDs.subtract(workIDs)
            persistPendingCleanup()
            if !maintenanceState.isActive, !isSearching {
                try await store.compactIfNeeded()
            }
            await refreshPublishedState(message: nil, isWorking: false)
        } catch {
            pendingCleanupWorkIDs.formUnion(workIDs)
            persistPendingCleanup()
            errorText = "文献已删除，但搜索缓存清理失败，已安排下次打开资料库时重试：\(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorText = nil
    }

    private func startModelDownload() {
        guard !maintenanceState.isActive else { return }
        let revalidateAllModels = allModelsVerified
        maintenanceTask?.cancel()
        pauseRequested = false
        errorText = nil
        modelsTested = false
        modelTestResults = []
        defaults.removeObject(forKey: LocalSearchConfiguration.modelTestReceiptKey)
        maintenanceState = .running
        maintenanceTask = Task {
            do {
                if revalidateAllModels || !isModelVerified(.balanced) {
                    try await downloadEmbeddingModel(profile: .balanced)
                    await modelRuntime.releaseAll()
                    try await maintenanceCheckpoint()
                }

                if revalidateAllModels || !isRerankerVerified {
                    try await downloadReranker()
                    await modelRuntime.releaseAll()
                }

                maintenanceProgress = nil
                maintenanceState = .idle
                maintenanceTask = nil
                startModelTests()
            } catch is CancellationError {
                await modelRuntime.releaseAll()
                maintenanceProgress = nil
                maintenanceState = .idle
                maintenanceTask = nil
            } catch {
                await modelRuntime.releaseAll()
                maintenanceProgress = nil
                maintenanceState = .failed(error.localizedDescription)
                maintenanceTask = nil
                errorText = "云端语义服务验证失败：\(error.localizedDescription)"
            }
        }
    }

    private func startModelTests() {
        guard !maintenanceState.isActive else { return }
        maintenanceTask?.cancel()
        pauseRequested = false
        errorText = nil
        modelsTested = false
        modelTestResults = []
        defaults.removeObject(forKey: LocalSearchConfiguration.modelTestReceiptKey)
        maintenanceState = .running
        maintenanceTask = Task {
            do {
                var allPassed = true
                var completed: Int64 = 0
                let total: Int64 = 2

                for profile in [LocalSearchProfile.balanced] {
                    try await maintenanceCheckpoint()
                    maintenanceProgress = LocalSearchProgress(
                        stage: .modelValidation,
                        profile: profile,
                        message: "正在测试\(profile.title)模型的向量输出与语义区分能力…",
                        completed: completed,
                        total: total
                    )
                    let startedAt = Date()
                    do {
                        let report = try await modelRuntime.validateEmbedding(profile: profile)
                        modelTestResults.append(
                            LocalSearchModelTestResult(
                                id: profile.rawValue,
                                title: "\(profile.title)嵌入模型",
                                detail: String(
                                    format: "维度 %d，相关相似度 %.4f，无关相似度 %.4f，向量长度 %.4f",
                                    profile.dimensions,
                                    report.relevantSimilarity,
                                    report.unrelatedSimilarity,
                                    report.queryVectorLength
                                ),
                                passed: true,
                                duration: Date().timeIntervalSince(startedAt),
                                finishedAt: Date()
                            )
                        )
                    } catch is CancellationError {
                        await modelRuntime.releaseAll()
                        throw CancellationError()
                    } catch {
                        allPassed = false
                        modelTestResults.append(
                            LocalSearchModelTestResult(
                                id: profile.rawValue,
                                title: "\(profile.title)嵌入模型",
                                detail: error.localizedDescription,
                                passed: false,
                                duration: Date().timeIntervalSince(startedAt),
                                finishedAt: Date()
                            )
                        )
                    }
                    await modelRuntime.releaseAll()
                    completed += 1
                }

                try await maintenanceCheckpoint()
                maintenanceProgress = LocalSearchProgress(
                    stage: .modelValidation,
                    profile: nil,
                    message: "正在测试重排模型的相关性顺序…",
                    completed: completed,
                    total: total
                )
                let rerankerStartedAt = Date()
                do {
                    let rerankerReport = try await modelRuntime.validateReranker()
                    modelTestResults.append(
                        LocalSearchModelTestResult(
                            id: "reranker",
                            title: "重排模型",
                            detail: String(
                                format: "相关得分 %.4f，无关得分 %.4f",
                                rerankerReport.relevantScore,
                                rerankerReport.unrelatedScore
                            ),
                            passed: true,
                            duration: Date().timeIntervalSince(rerankerStartedAt),
                            finishedAt: Date()
                        )
                    )
                } catch is CancellationError {
                    await modelRuntime.releaseAll()
                    throw CancellationError()
                } catch {
                    allPassed = false
                    modelTestResults.append(
                        LocalSearchModelTestResult(
                            id: "reranker",
                            title: "重排模型",
                            detail: error.localizedDescription,
                            passed: false,
                            duration: Date().timeIntervalSince(rerankerStartedAt),
                            finishedAt: Date()
                        )
                    )
                }
                await modelRuntime.releaseAll()
                completed += 1

                maintenanceProgress = nil
                maintenanceTask = nil
                if allPassed {
                    modelsTested = true
                    defaults.set(
                        LocalSearchConfiguration.currentModelTestReceipt,
                        forKey: LocalSearchConfiguration.modelTestReceiptKey
                    )
                    maintenanceState = .completed
                    await refreshPublishedState(
                        message: "两项云端语义服务均已通过测试，可手动建立语义索引。",
                        isWorking: false
                    )
                } else {
                    let failedCount = modelTestResults.filter { !$0.passed }.count
                    let message = "有 \(failedCount) 项云端语义测试未通过，未开始建立语义索引。"
                    maintenanceState = .failed(message)
                    errorText = "\(message)请复制测试报告后发给我检查。"
                }
            } catch is CancellationError {
                await modelRuntime.releaseAll()
                maintenanceProgress = nil
                maintenanceState = .idle
                maintenanceTask = nil
            } catch {
                await modelRuntime.releaseAll()
                modelsTested = false
                defaults.removeObject(
                    forKey: LocalSearchConfiguration.modelTestReceiptKey
                )
                maintenanceProgress = nil
                maintenanceState = .failed(error.localizedDescription)
                maintenanceTask = nil
                errorText = "云端语义测试失败：\(error.localizedDescription)"
            }
        }
    }

    private func startMaintenance(
        profiles: [LocalSearchProfile],
        clearProfiles: Set<LocalSearchProfile>
    ) {
        guard let store, !maintenanceState.isActive else { return }
        guard modelsReadyForIndexing else {
            errorText = "请先验证云端语义服务，再建立语义索引。"
            return
        }
        maintenanceTask?.cancel()
        pauseRequested = false
        embeddingTimingEstimators = [
            .balanced: LocalSearchTimingEstimator(),
        ]
        maintenanceState = .running
        maintenanceTask = Task {
            do {
                if let textIndexTask {
                    maintenanceProgress = LocalSearchProgress(
                        stage: .textExtraction,
                        profile: nil,
                        message: "正在等待正文索引完成…",
                        completed: Int64(status.indexedDocuments),
                        total: Int64(status.totalDocuments)
                    )
                    await textIndexTask.value
                }
                for profile in profiles {
                    try await maintenanceCheckpoint()
                    if clearProfiles.contains(profile) {
                        try await store.removeVectors(profile: profile)
                    }
                    try await buildMissingVectors(profile: profile, store: store)
                }
                await modelRuntime.releaseAll()
                await refreshPublishedState(message: "语义索引已核对完成。", isWorking: false)
                maintenanceProgress = nil
                maintenanceState = .completed
            } catch is CancellationError {
                await modelRuntime.releaseAll()
                maintenanceProgress = nil
                maintenanceState = .idle
                await refreshPublishedState(message: nil, isWorking: false)
            } catch {
                let currentProgress = maintenanceProgress
                try? await store.recordGlobalFailure(
                    stage: currentProgress?.stage ?? .embedding,
                    modelSignature: currentProgress?.profile?.vectorSpaceSignature,
                    message: error.localizedDescription
                )
                await modelRuntime.releaseAll()
                await refreshPublishedState(message: nil, isWorking: false)
                maintenanceState = .failed(error.localizedDescription)
                errorText = "智能搜索建库失败：\(error.localizedDescription)"
            }
        }
    }

    private func buildMissingVectors(
        profile: LocalSearchProfile,
        store: SearchIndexStore
    ) async throws {
        maintenanceProgress = LocalSearchProgress(
            stage: .embedding,
            profile: profile,
            message: "正在连接北京区百炼\(profile.title)模型…",
            completed: 0,
            total: 0
        )
        try await modelRuntime.prepareEmbedding(profile: profile) { _ in }

        var consecutiveFailures = 0
        while true {
            try await maintenanceCheckpoint()
            while isSearching {
                maintenanceProgress = LocalSearchProgress(
                    stage: .embedding,
                    profile: profile,
                    message: "已暂停后台向量生成，正在优先完成当前搜索…",
                    completed: maintenanceProgress?.completed ?? 0,
                    total: maintenanceProgress?.total ?? 0,
                    estimatedCompletionDate: nil
                )
                try await Task.sleep(for: .milliseconds(100))
                try await maintenanceCheckpoint()
            }
            let chunks = try await store.chunksNeedingEmbedding(
                signature: profile.vectorSpaceSignature,
                limit: profile.batchSize
            )
            guard !chunks.isEmpty else { break }
            let statistics = try await store.statistics(profile: profile, totalDocuments: snapshots.count)
            maintenanceProgress = LocalSearchProgress(
                stage: .embedding,
                profile: profile,
                message: "正在使用\(profile.title)模式生成向量（文献 \(statistics.indexedDocuments)/\(statistics.totalDocuments)，片段 \(statistics.embeddedChunks)/\(statistics.totalChunks)）…",
                completed: Int64(statistics.embeddedChunks),
                total: Int64(statistics.totalChunks),
                estimatedCompletionDate: estimatedEmbeddingCompletionDate(
                    profile: profile,
                    completedChunks: statistics.embeddedChunks,
                    totalChunks: statistics.totalChunks
                )
            )
            let batchStartedAt = Date()
            do {
                let vectors = try await modelRuntime.embedDocuments(
                    profile: profile,
                    texts: chunks.map(\.text)
                )
                try await store.saveEmbeddings(vectors, for: chunks, profile: profile)
                recordEmbeddingDuration(
                    Date().timeIntervalSince(batchStartedAt),
                    completedChunks: chunks.count,
                    profile: profile
                )
                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SearchCoordinatorError {
                throw error
            } catch {
                for chunk in chunks {
                    try await maintenanceCheckpoint()
                    let chunkStartedAt = Date()
                    do {
                        let vectors = try await modelRuntime.embedDocuments(
                            profile: profile,
                            texts: [chunk.text]
                        )
                        try await store.saveEmbeddings(vectors, for: [chunk], profile: profile)
                        recordEmbeddingDuration(
                            Date().timeIntervalSince(chunkStartedAt),
                            completedChunks: 1,
                            profile: profile
                        )
                        consecutiveFailures = 0
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as SearchCoordinatorError {
                        throw error
                    } catch {
                        consecutiveFailures += 1
                        try await store.recordEmbeddingFailure(
                            profile: profile,
                            chunk: chunk,
                            message: error.localizedDescription
                        )
                        if consecutiveFailures >= 3 {
                            throw SearchCoordinatorError.repeatedEmbeddingFailures(
                                profile: profile,
                                underlying: error.localizedDescription
                            )
                        }
                    }
                }
            }
            await refreshPublishedState(message: maintenanceProgress?.message, isWorking: true)
        }
        await refreshPublishedState(message: nil, isWorking: false)
    }

    private func downloadEmbeddingModel(profile: LocalSearchProfile) async throws {
        try await maintenanceCheckpoint()
        maintenanceProgress = LocalSearchProgress(
            stage: .modelDownload,
            profile: profile,
            message: "正在连接并验证北京区百炼向量接口…",
            completed: 0,
            total: 0
        )
        try await modelRuntime.downloadEmbedding(profile: profile) { [weak self] value in
            Task { @MainActor in
                self?.maintenanceProgress = LocalSearchProgress(
                    stage: .modelDownload,
                    profile: profile,
                    message: "正在连接并验证北京区百炼向量接口…",
                    completed: value.completed,
                    total: value.total
                )
            }
        }
        markModelVerified(profile.vectorSpaceSignature)
    }

    private func downloadReranker() async throws {
        maintenanceProgress = LocalSearchProgress(
            stage: .rerankerValidation,
            profile: nil,
            message: "正在连接并验证北京区百炼重排接口…",
            completed: 0,
            total: 0
        )
        try await modelRuntime.downloadAndValidateReranker { [weak self] value in
            Task { @MainActor in
                self?.maintenanceProgress = LocalSearchProgress(
                    stage: .rerankerValidation,
                    profile: nil,
                    message: "正在连接并验证北京区百炼重排接口…",
                    completed: value.completed,
                    total: value.total
                )
            }
        }
        markModelVerified(LocalSearchConfiguration.rerankerSignature)
    }

    private func maintenanceCheckpoint() async throws {
        try Task.checkCancellation()
        var releasedForPause = false
        while pauseRequested {
            if !releasedForPause {
                await modelRuntime.releaseAll()
                releasedForPause = true
            }
            maintenanceState = .paused
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
        }
        if maintenanceState == .paused || maintenanceState == .pausing {
            maintenanceState = .running
        }
    }

    private func recordEmbeddingDuration(
        _ duration: TimeInterval,
        completedChunks: Int,
        profile: LocalSearchProfile
    ) {
        var estimator = embeddingTimingEstimators[profile] ?? LocalSearchTimingEstimator()
        estimator.record(batchDuration: duration, completedItems: completedChunks)
        embeddingTimingEstimators[profile] = estimator
    }

    private func estimatedEmbeddingCompletionDate(
        profile: LocalSearchProfile,
        completedChunks: Int,
        totalChunks: Int
    ) -> Date? {
        let remainingChunks = max(0, totalChunks - completedChunks)
        return embeddingTimingEstimators[profile]?.estimatedCompletionDate(
            remainingItems: remainingChunks
        )
    }

    private func markModelVerified(_ signature: String) {
        verifiedModelSignatures.insert(signature)
        persistVerifiedModels()
    }

    private func persistVerifiedModels() {
        defaults.set(
            verifiedModelSignatures.sorted(),
            forKey: LocalSearchConfiguration.verifiedModelsKey
        )
    }

    private func scheduleTextIndex() {
        textIndexTask?.cancel()
        guard let store, let rootURL, let configuredLibraryID else { return }
        let currentSnapshots = snapshots
        textIndexTask = Task {
            do {
                let migrationKey = LocalSearchConfiguration.localVectorCleanupKey(
                    libraryID: configuredLibraryID
                )
                if !defaults.bool(forKey: migrationKey) {
                    do {
                        let removedFastVectors = try await store.removeVectors(
                            signature: LocalSearchConfiguration.legacyFastVectorSpaceSignature
                        )
                        let removedBalancedVectors = try await store.removeVectors(
                            signature: LocalSearchConfiguration.legacyBalancedVectorSpaceSignature
                        )
                        if removedFastVectors || removedBalancedVectors {
                            try await store.compactIfNeeded(force: true)
                        }
                        defaults.set(true, forKey: migrationKey)
                    } catch {
                        errorText = "旧本地语义向量删除失败，将在下次打开资料库时重试：\(error.localizedDescription)"
                    }
                }
                try await store.removeDocuments(notIn: Set(currentSnapshots.map(\.workID)))
                if !pendingCleanupWorkIDs.isEmpty {
                    try await store.removeDocuments(workIDs: pendingCleanupWorkIDs)
                    pendingCleanupWorkIDs.removeAll()
                    persistPendingCleanup()
                }
                let snapshotsToIndex = try await store.snapshotsNeedingTextIndex(currentSnapshots)
                for (index, snapshot) in snapshotsToIndex.enumerated() {
                    try Task.checkCancellation()
                    status = SearchIndexStatus(
                        indexedDocuments: status.indexedDocuments,
                        totalDocuments: currentSnapshots.count,
                        embeddedChunks: status.embeddedChunks,
                        totalChunks: status.totalChunks,
                        message: "正在更新正文索引（\(index + 1)/\(snapshotsToIndex.count)）…",
                        isWorking: true
                    )
                    do {
                        let url = try LibraryPathSafety.url(
                            for: snapshot.relativePath,
                            inside: rootURL,
                            requirePDF: true,
                            requireExistingRegularFile: true
                        )
                        let chunks = try await Task.detached(priority: .utility) {
                            try PDFTextExtractor.extract(
                                from: url,
                                workID: snapshot.workID,
                                fileVersionID: snapshot.fileVersionID
                            )
                        }.value
                        try await store.replaceDocument(snapshot, chunks: chunks)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try await store.markUnindexable(snapshot, message: error.localizedDescription)
                    }
                }
                try await store.clearGlobalFailures(stage: .textExtraction)
                try await store.compactIfNeeded()
                await refreshPublishedState(message: nil, isWorking: false)
            } catch is CancellationError {
                return
            } catch {
                try? await store.recordGlobalFailure(
                    stage: .textExtraction,
                    modelSignature: nil,
                    message: error.localizedDescription
                )
                await refreshPublishedState(message: nil, isWorking: false)
                errorText = "更新正文索引失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshPublishedState(message: String?, isWorking: Bool) async {
        guard let store else { return }
        for profile in LocalSearchProfile.allCases {
            if let statistics = try? await store.statistics(
                profile: profile,
                totalDocuments: snapshots.count
            ) {
                profileStatistics[profile] = statistics
            }
        }
        failures = (try? await store.failures()) ?? []
        status = makeStatus(profile: selectedProfile, message: message, isWorking: isWorking)
    }

    private func makeStatus(
        profile: LocalSearchProfile,
        message: String?,
        isWorking: Bool
    ) -> SearchIndexStatus {
        let statistics = profileStatistics[profile] ?? .empty(profile)
        return SearchIndexStatus(
            indexedDocuments: statistics.indexedDocuments,
            totalDocuments: statistics.totalDocuments,
            embeddedChunks: statistics.embeddedChunks,
            totalChunks: statistics.totalChunks,
            message: message,
            isWorking: isWorking
        )
    }

    private func finishSmartSearch(profile: LocalSearchProfile) {
        smartRequestID = nil
        smartTask = nil
        isSearching = false
        status = makeStatus(profile: profile, message: nil, isWorking: false)
    }

    private func metadataWorkRanking(
        query: String,
        allowedWorkIDs: Set<UUID>,
        limit: Int
    ) -> [UUID] {
        let normalizedQuery = LibrarySearchRules.normalize(query)
        let terms = LibrarySearchRules.queryTerms(query)
        return snapshots.lazy.compactMap { snapshot -> (UUID, Int)? in
            guard allowedWorkIDs.contains(snapshot.workID) else { return nil }
            let title = LibrarySearchRules.normalize(snapshot.title)
            let metadata = LibrarySearchRules.normalize(snapshot.metadataText)
            let matches = terms.filter { metadata.contains($0) }.count
            guard matches > 0 else { return nil }
            let score = matches * 10 + (title.contains(normalizedQuery) ? 100 : 0)
            return (snapshot.workID, score)
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0.uuidString < $1.0.uuidString }
            return $0.1 > $1.1
        }
        .map(\.0)
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func rerankDocumentText(
        snapshot: SearchDocumentSnapshot,
        chunk: SearchTextChunk?
    ) -> String {
        var sections = ["题名：\(snapshot.title)"]
        if !snapshot.authors.isEmpty { sections.append("作者：\(snapshot.authors)") }
        if let year = snapshot.publicationYear { sections.append("年份：\(year)") }
        if let doi = snapshot.doi, !doi.isEmpty { sections.append("DOI：\(doi)") }
        if let chunk {
            sections.append("正文：\n\(chunk.text)")
        } else if let abstract = snapshot.abstractText, !abstract.isEmpty {
            sections.append("摘要：\n\(abstract)")
        } else {
            sections.append("仅有书目信息。")
        }
        return sections.joined(separator: "\n")
    }

    private static func pendingCleanupKey(libraryID: UUID) -> String {
        LocalSearchConfiguration.pendingCleanupKeyPrefix + libraryID.uuidString
    }

    private func persistPendingCleanup() {
        pendingCleanupCount = pendingCleanupWorkIDs.count
        guard let configuredLibraryID else { return }
        defaults.set(
            pendingCleanupWorkIDs.map(\.uuidString).sorted(),
            forKey: Self.pendingCleanupKey(libraryID: configuredLibraryID)
        )
    }

    static func areDuplicateVersions(
        _ left: SearchDocumentSnapshot,
        _ right: SearchDocumentSnapshot
    ) -> Bool {
        if let leftDOI = PDFMetadataExtractor.normalizedDOI(left.doi),
           let rightDOI = PDFMetadataExtractor.normalizedDOI(right.doi),
           leftDOI == rightDOI {
            return true
        }
        if left.duplicateCandidateWorkID == right.workID ||
            right.duplicateCandidateWorkID == left.workID {
            return true
        }
        guard let leftYear = left.publicationYear,
              let rightYear = right.publicationYear,
              abs(leftYear - rightYear) <= 1 else { return false }
        let leftTitle = LibrarySearchRules.normalize(left.title)
        let rightTitle = LibrarySearchRules.normalize(right.title)
        return !leftTitle.isEmpty && leftTitle == rightTitle
    }

    static func uniqueVersionWorkIDs(
        rankedWorkIDs: [UUID],
        snapshots: [UUID: SearchDocumentSnapshot],
        limit: Int
    ) -> [UUID] {
        guard limit > 0 else { return [] }
        var retainedIDs: [UUID] = []
        var retainedSnapshots: [SearchDocumentSnapshot] = []
        for workID in rankedWorkIDs {
            guard retainedIDs.count < limit else { break }
            if let snapshot = snapshots[workID] {
                if retainedSnapshots.contains(where: {
                    areDuplicateVersions(snapshot, $0)
                }) {
                    continue
                }
                retainedSnapshots.append(snapshot)
            }
            retainedIDs.append(workID)
        }
        return retainedIDs
    }

    /// 百炼重排得分只能在同一次请求内比较，不应使用跨请求的固定阈值。
    static func relativeRerankScores(_ scores: [Float]) -> [Float] {
        guard let minimum = scores.min(), let maximum = scores.max() else { return [] }
        let range = maximum - minimum
        guard range.isFinite, range > Float.ulpOfOne else {
            return Array(repeating: 1, count: scores.count)
        }
        return scores.map { min(1, max(0, ($0 - minimum) / range)) }
    }

    private func makeSmartMatches(
        _ candidates: [RerankedCandidate],
        query: String,
        resultLimit: Int,
        snapshots: [UUID: SearchDocumentSnapshot]
    ) -> [UUID: SearchWorkMatch] {
        let grouped = Dictionary(grouping: candidates, by: { $0.candidate.workID })
        let rankedWorks = grouped.compactMap { workID, workCandidates
            -> (UUID, RerankedCandidate, [RerankedCandidate])? in
            let ordered = workCandidates.sorted {
                if $0.rawScore == $1.rawScore { return $0.fusionScore > $1.fusionScore }
                return $0.rawScore > $1.rawScore
            }
            guard let best = ordered.first else { return nil }
            return (workID, best, ordered)
        }.sorted {
            if $0.1.rawScore == $1.1.rawScore {
                if $0.1.fusionScore == $1.1.fusionScore {
                    return $0.0.uuidString < $1.0.uuidString
                }
                return $0.1.fusionScore > $1.1.fusionScore
            }
            return $0.1.rawScore > $1.1.rawScore
        }

        let selectedWorkIDs = Self.uniqueVersionWorkIDs(
            rankedWorkIDs: rankedWorks.map(\.0),
            snapshots: snapshots,
            limit: resultLimit
        )
        let selectedWorkIDSet = Set(selectedWorkIDs)
        let terms = LibrarySearchRules.queryTerms(query)
        var matches: [UUID: SearchWorkMatch] = [:]
        for (workID, best, ordered) in rankedWorks where selectedWorkIDSet.contains(workID) {
            let passageCandidates = ordered.filter { $0.candidate.chunk != nil }
            let displayOrder = SmartSearchPassageSelector.displayOrder(
                passageCandidates.compactMap { scored in
                    guard let chunk = scored.candidate.chunk else { return nil }
                    return SmartSearchPassageScore(
                        id: scored.candidate.id,
                        rawScore: scored.rawScore,
                        startPage: chunk.startPage
                    )
                }
            )
            let scoredByID = Dictionary(uniqueKeysWithValues: passageCandidates.map {
                ($0.candidate.id, $0)
            })
            let passages = displayOrder.compactMap { candidateID -> SearchPassageHit? in
                guard let scored = scoredByID[candidateID],
                      let chunk = scored.candidate.chunk else { return nil }
                return SearchPassageHit(
                    id: "semantic:\(chunk.id)",
                    chunkID: chunk.id,
                    workID: workID,
                    kind: .semantic,
                    score: scored.relativeScore,
                    relevance: SearchRelevanceTier.classify(score: scored.relativeScore),
                    snippet: SearchFusion.excerpt(chunk.text, matching: terms),
                    startPage: chunk.startPage,
                    endPage: chunk.endPage
                )
            }.prefix(LocalSearchConfiguration.maximumPassagesPerWork).map { $0 }

            let kind: SearchMatchKind = passages.isEmpty ? .metadata : .semantic
            let isMarginal = !passages.isEmpty && passages.allSatisfy {
                $0.relevance == .marginal
            }
            let reason = passages.isEmpty
                ? "匹配书目信息"
                : (isMarginal ? "相关性较弱" : "匹配语义相关内容")
            matches[workID] = SearchWorkMatch(
                workID: workID,
                score: best.rawScore + best.fusionScore * 0.000_001,
                kind: kind,
                reason: reason,
                passages: passages
            )
        }
        return matches
    }

    private static func groupKeywordHits(
        _ hits: [SearchStoreHit],
        query: String
    ) -> [UUID: SearchWorkMatch] {
        let terms = LibrarySearchRules.queryTerms(query)
        let grouped = Dictionary(grouping: hits, by: { $0.chunk.workID })
        return grouped.mapValues { workHits in
            let passages = workHits.prefix(3).map { hit in
                SearchPassageHit(
                    id: "keyword:\(hit.chunk.id)",
                    chunkID: hit.chunk.id,
                    workID: hit.chunk.workID,
                    kind: .fullText,
                    score: hit.rank,
                    relevance: .solid,
                    snippet: SearchFusion.excerpt(hit.chunk.text, matching: terms),
                    startPage: hit.chunk.startPage,
                    endPage: hit.chunk.endPage
                )
            }
            let best = passages.first?.score ?? 0
            return SearchWorkMatch(
                workID: workHits[0].chunk.workID,
                score: best,
                kind: .fullText,
                reason: "匹配正文",
                passages: passages
            )
        }
    }

    private static func hitsContainingAllTerms(
        _ hits: [SearchStoreHit],
        query: String
    ) -> [SearchStoreHit] {
        let terms = LibrarySearchRules.queryTerms(query)
        guard !terms.isEmpty else { return [] }
        let grouped = Dictionary(grouping: hits, by: { $0.chunk.workID })
        let matchingWorkIDs = Set(grouped.compactMap { workID, workHits in
            let searchable = workHits.map(\.chunk.searchableText).joined(separator: " ")
            return terms.allSatisfy { searchable.contains($0) } ? workID : nil
        })
        return hits.filter { matchingWorkIDs.contains($0.chunk.workID) }
    }

}

enum SearchCoordinatorError: LocalizedError {
    case invalidRerankerCount
    case repeatedEmbeddingFailures(profile: LocalSearchProfile, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidRerankerCount:
            return "重排模型返回的分数数量与候选段落不一致。"
        case let .repeatedEmbeddingFailures(profile, underlying):
            return "\(profile.title)模式连续三个片段生成向量失败：\(underlying)"
        }
    }
}
