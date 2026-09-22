import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @EnvironmentObject private var reconciliationCoordinator: FileReconciliationCoordinator
    @EnvironmentObject private var searchCoordinator: SearchIndexCoordinator
    @Query(sort: \Work.dateAdded, order: .reverse) private var works: [Work]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \PersonalMark.sortOrder) private var personalMarks: [PersonalMark]
    @Query(sort: \ReadingProject.name) private var projects: [ReadingProject]
    @AppStorage("crossrefContactEmail") private var crossrefEmail = ""
    @AppStorage("geminiModel") private var geminiModel = "gemini-3.5-flash-lite"
    @AppStorage("monthlyAIBudgetUSD") private var monthlyBudget = 0.0
    @AppStorage("aiInputPricePerMillionUSD") private var inputPrice = 0.30
    @AppStorage("aiCachedInputPricePerMillionUSD") private var cachedInputPrice = 0.03
    @AppStorage("aiOutputPricePerMillionUSD") private var outputPrice = 2.50
    @AppStorage("studyNoteRegularInputPricePerMillionUSD") private var studyNoteRegularInputPrice = 2.0
    @AppStorage("studyNoteRegularOutputPricePerMillionUSD") private var studyNoteRegularOutputPrice = 12.0
    @AppStorage("studyNoteInputPricePerMillionUSD") private var studyNoteInputPrice = 4.0
    @AppStorage("studyNoteOutputPricePerMillionUSD") private var studyNoteOutputPrice = 18.0
    @AppStorage("studyNoteRegularCachedInputPricePerMillionUSD") private var studyNoteRegularCachedInputPrice = 0.20
    @AppStorage("studyNoteCachedInputPricePerMillionUSD") private var studyNoteCachedInputPrice = 0.40
    @AppStorage("studyNoteCacheStoragePricePerMillionTokenHoursUSD") private var studyNoteCacheStoragePrice = 4.50
    @AppStorage("longDocumentPageThreshold") private var longDocumentPageThreshold = 200
    @AppStorage("longDocumentExcerptPages") private var longDocumentExcerptPages = 60
    @AppStorage("longDocumentPolicy") private var longDocumentPolicy = "excerpt"
    @AppStorage(AuthorYearReferencePreferences.authorLimitKey)
    private var authorYearReferenceAuthorLimit = AuthorYearReferencePreferences.defaultAuthorLimit
    @AppStorage(LocalSearchConfiguration.smartSearchDepthKey)
    private var smartSearchDepth: SmartSearchDepth = .balanced
    @AppStorage(LocalSearchConfiguration.smartSearchResultLimitKey)
    private var smartSearchResultLimit = 10
    @State private var apiKey = LocalAPIKeyStore.shared.readIfAvailable() ?? ""
    @State private var bailianAPIKey = BailianAPIKeyStore.shared.readIfAvailable() ?? ""
    @State private var bailianWorkspaceID = UserDefaults.standard.string(
        forKey: LocalSearchConfiguration.bailianWorkspaceIDKey
    ) ?? ""
    @State private var readerName = ExternalPDFOpener.selectedReaderName ?? "系统默认"
    @State private var statusText: String?
    @State private var bailianStatusText: String?
    @State private var searchProfilePendingRebuild: LocalSearchProfile?
    @State private var personalMarkPendingDeletion: PersonalMark?
    @StateObject private var manifestCoordinator = ManifestCoordinator()

    var body: some View {
        Form {
            Section("Crossref") {
                TextField("联系邮箱", text: $crossrefEmail)
                Text("AI 先提取书目信息，然后才使用 Crossref 核对。优先使用 DOI，缺少 DOI 时使用 AI 返回的标题和作者。邮箱仅作为礼貌请求参数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("复制作者与年份") {
                Stepper(
                    "最多显示的作者姓氏：\(authorYearReferenceAuthorLimit)",
                    value: $authorYearReferenceAuthorLimit,
                    in: AuthorYearReferencePreferences.allowedAuthorLimits
                )
                Text("作者人数超过上限时，只复制前 \(authorYearReferenceAuthorLimit) 位作者的姓氏，并在后面添加“et al”。默认上限为 4。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("智能搜索") {
                TextField("北京区百炼业务空间编号", text: $bailianWorkspaceID)
                    .textContentType(.none)
                SecureField("北京区百炼 API 密钥", text: $bailianAPIKey)
                HStack {
                    Button("保存百炼配置") { saveBailianConfiguration() }
                        .disabled(searchCoordinator.maintenanceState.isActive)
                    if let bailianStatusText {
                        Text(bailianStatusText)
                            .font(.caption)
                            .foregroundStyle(
                                searchCoordinator.isBailianConfigured ? .green : .secondary
                            )
                    }
                }
                Text("向量生成和候选重排均固定使用北京区百炼 Qwen3.7。建立索引时会发送文献片段，智能搜索时会发送查询和受搜索深度、文本预算限制的候选片段；API 密钥只保存在应用的本地私有目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("搜索深度", selection: $smartSearchDepth) {
                    ForEach(SmartSearchDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                Text(smartSearchDepth.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("最多显示文献", selection: $smartSearchResultLimit) {
                    ForEach(SmartSearchPreferences.allowedResultLimits, id: \.self) { limit in
                        Text("\(limit) 篇").tag(limit)
                    }
                }
                Text("数量表示显示上限；相关候选不足时可能少于该数量。更改这些选项不需要重建语义索引，并从下一次搜索开始生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                localSearchProfileStatus(.balanced)

                HStack {
                    Label(
                        "重排模型",
                        systemImage: searchCoordinator.isRerankerVerified
                            ? "checkmark.circle.fill" : "network"
                    )
                    Spacer()
                    Text(searchCoordinator.isRerankerVerified ? "接口已验证" : "接口未验证")
                        .foregroundStyle(.secondary)
                }
                Text("北京区百炼 Qwen3.7 重排服务；深度模式最多处理 120 个候选片段，并始终受输入文本预算限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("模型：\(LocalSearchConfiguration.rerankerModelID)\n版本：\(LocalSearchConfiguration.rerankerRevision)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Text("接口验证和语义测试只使用固定样例，不读取文献或写入向量；只有点击建立索引后，才会处理文献片段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label(
                        searchCoordinator.modelsTested ? "实际推理测试已通过" : "尚未进行实际推理测试",
                        systemImage: searchCoordinator.modelsTested
                            ? "checkmark.shield.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(searchCoordinator.modelsTested ? .green : .orange)
                    Spacer()
                }

                if !searchCoordinator.modelTestResults.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(searchCoordinator.modelTestResults) { result in
                            LocalSearchModelTestResultRow(result: result)
                        }
                    }
                }

                if searchCoordinator.allModelsVerified, !searchCoordinator.modelsTested {
                    Text("云端语义服务未通过实际推理测试，请重新验证并检查报告。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let progress = searchCoordinator.maintenanceProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.message).font(.caption)
                        if let fraction = progress.fractionCompleted {
                            ProgressView(value: fraction)
                            Text("\(progress.completed.formatted()) / \(progress.total.formatted())")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let completionDate = progress.estimatedCompletionDate {
                                Text(
                                    "预计当前向量任务完成时间：" +
                                    completionDate.formatted(date: .omitted, time: .shortened)
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                HStack {
                    Button(searchCoordinator.modelDownloadButtonTitle) {
                        searchCoordinator.downloadAllModels()
                    }
                    .disabled(
                        !searchCoordinator.isBailianConfigured ||
                        searchCoordinator.maintenanceState.isActive
                    )

                    Button("复制测试报告") {
                        copyLocalSearchModelTestReport()
                    }
                    .disabled(
                        searchCoordinator.modelTestResults.isEmpty ||
                        searchCoordinator.maintenanceState.isActive
                    )

                    Button(searchCoordinator.vectorMaintenanceButtonTitle) {
                        searchCoordinator.updateMissingVectors()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        libraryAccess.libraryID == nil ||
                        !searchCoordinator.modelsReadyForIndexing ||
                        searchCoordinator.maintenanceState.isActive
                    )

                    if searchCoordinator.maintenanceState == .running ||
                        searchCoordinator.maintenanceState == .pausing {
                        Button("暂停") { searchCoordinator.pauseMaintenance() }
                    } else if searchCoordinator.maintenanceState == .paused {
                        Button("继续") { searchCoordinator.resumeMaintenance() }
                    }
                    if searchCoordinator.maintenanceState.isActive {
                        Button("取消", role: .destructive) {
                            searchCoordinator.cancelMaintenance()
                        }
                    }
                }

                HStack {
                    Button("重试失败项") { searchCoordinator.retryFailedItems() }
                        .disabled(
                            searchCoordinator.failures.isEmpty ||
                            !searchCoordinator.modelsReadyForIndexing ||
                            searchCoordinator.maintenanceState.isActive
                        )
                    Button("重建语义索引") {
                        searchProfilePendingRebuild = .balanced
                    }
                    .disabled(
                        libraryAccess.libraryID == nil ||
                        !searchCoordinator.modelsReadyForIndexing ||
                        searchCoordinator.maintenanceState.isActive
                    )
                }

                if !searchCoordinator.failures.isEmpty {
                    DisclosureGroup("错误详情（\(searchCoordinator.failures.count)）") {
                        ForEach(searchCoordinator.failures) { failure in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(searchFailureTitle(failure)).font(.caption.weight(.semibold))
                                Text(failure.message).font(.caption).foregroundStyle(.red)
                                Text(failure.occurredAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if searchCoordinator.pendingCleanupCount > 0 {
                    Text("有 \(searchCoordinator.pendingCleanupCount) 篇已删除文献的搜索缓存等待下次对账清理。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorText = searchCoordinator.errorText {
                    HStack(alignment: .top) {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("关闭") { searchCoordinator.dismissError() }
                            .font(.caption)
                    }
                }

                Text("普通搜索会自动建立正文索引。语义向量只会在这里手动批量生成；新增文献不会在搜索时自动建立语义索引。向量和重排由北京区百炼处理，正文与向量数据库仍保存在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("长文献") {
                TextField("页数阈值", value: $longDocumentPageThreshold, format: .number)
                Picker("超过阈值时", selection: $longDocumentPolicy) {
                    Text("仅上传前部分页面").tag("excerpt")
                    Text("跳过自动 AI 分析").tag("skip")
                }
                TextField("上传前多少页", value: $longDocumentExcerptPages, format: .number)
                    .disabled(longDocumentPolicy != "excerpt")
                Text("默认超过 200 页时只上传前 60 页。该设置只影响自动分析；手动分析仍由用户主动触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gemini") {
                SecureField("API 密钥", text: $apiKey)
                TextField("模型", text: $geminiModel)
                Text("导入后会自动进入处理队列：先提取信息和分类，再使用 Crossref 核对。处理失败的文献会出现在“有问题”中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("保存密钥") { saveAPIKey() }
                    Button("验证模型") { validateModel() }
                }
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("个人标记") {
                Text("个人标记只用于你的阅读判断，不会提供给 AI，也不会由 AI 自动创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if personalMarks.isEmpty {
                    Text("尚无个人标记").foregroundStyle(.secondary)
                }
                ForEach(personalMarks) { mark in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("标记名称", text: Binding(
                            get: { mark.name },
                            set: { mark.name = $0 }
                        ))
                        HStack(spacing: 14) {
                            ColorPicker(
                                "文字颜色",
                                selection: personalMarkTextColorBinding(mark),
                                supportsOpacity: false
                            )
                            ColorPicker(
                                "底色",
                                selection: personalMarkBackgroundColorBinding(mark),
                                supportsOpacity: false
                            )
                            Text(mark.name)
                                .font(.caption)
                                .foregroundStyle(Color(hex: mark.colorHex))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Color(hex: mark.effectiveBackgroundColorHex),
                                    in: Capsule()
                                )
                            Spacer()
                            Button {
                                movePersonalMark(mark, offset: -1)
                            } label: { Image(systemName: "arrow.up") }
                            .disabled(mark.sortOrder == 0)
                            Button {
                                movePersonalMark(mark, offset: 1)
                            } label: { Image(systemName: "arrow.down") }
                            .disabled(mark.sortOrder >= personalMarks.count - 1)
                            Button(role: .destructive) {
                                personalMarkPendingDeletion = mark
                            } label: { Image(systemName: "trash") }
                        }
                    }
                    .onSubmit { savePersonalMarks() }
                }
                Button("新增个人标记", systemImage: "plus") {
                    modelContext.insert(PersonalMark(
                        name: uniquePersonalMarkName(),
                        sortOrder: personalMarks.count
                    ))
                    savePersonalMarks()
                }
            }

            Section("费用") {
                TextField("每月预算（美元，0 表示不限制）", value: $monthlyBudget, format: .number)
                LabeledContent("今日费用", value: todayExpenseUSD, format: .currency(code: "USD"))
                LabeledContent("本月费用", value: currentMonthExpenseUSD, format: .currency(code: "USD"))
                DisclosureGroup("每日费用记录") {
                    if dailyExpenses.isEmpty {
                        Text("尚无费用记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(dailyExpenses) { expense in
                            VStack(alignment: .leading, spacing: 3) {
                                LabeledContent {
                                    Text(expense.totalCostUSD, format: .currency(code: "USD"))
                                } label: {
                                    Text(expense.date, format: .dateTime.year().month().day())
                                }
                                Text(
                                    "研究卡 \(expense.researchCardCostUSD, format: .currency(code: "USD")) · 精读笔记 \(expense.studyNoteCostUSD, format: .currency(code: "USD"))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                TextField("快速模型每百万输入令牌价格（美元）", value: $inputPrice, format: .number)
                TextField("快速模型每百万缓存输入令牌价格（美元）", value: $cachedInputPrice, format: .number)
                TextField("快速模型每百万输出令牌价格（美元）", value: $outputPrice, format: .number)
                TextField("精读笔记 20 万令牌内输入价格（美元）", value: $studyNoteRegularInputPrice, format: .number)
                TextField("精读笔记 20 万令牌内缓存输入价格（美元）", value: $studyNoteRegularCachedInputPrice, format: .number)
                TextField("精读笔记 20 万令牌内输出价格（美元）", value: $studyNoteRegularOutputPrice, format: .number)
                TextField("精读笔记超过 20 万令牌输入价格（美元）", value: $studyNoteInputPrice, format: .number)
                TextField("精读笔记超过 20 万令牌缓存输入价格（美元）", value: $studyNoteCachedInputPrice, format: .number)
                TextField("精读笔记超过 20 万令牌输出价格（美元）", value: $studyNoteOutputPrice, format: .number)
                TextField("精读缓存每百万令牌小时存储价格（美元）", value: $studyNoteCacheStoragePrice, format: .number)
                Text("精读笔记固定使用 gemini-3.1-pro-preview。PDF 会建立一小时显式缓存，各章节共用；费用按普通输入、缓存输入、输出与最长缓存存储时间分别估算。价格需按供应商公告更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外部阅读器") {
                LabeledContent("当前阅读器", value: readerName)
                HStack {
                    Button("选择应用") { chooseReader() }
                    Button("使用系统默认") {
                        ExternalPDFOpener.clearSelectedReader()
                        readerName = "系统默认"
                    }
                }
            }

            Section("资料库维护") {
                if let rootURL = libraryAccess.rootURL {
                    LabeledContent("当前资料库", value: rootURL.lastPathComponent)
                    HStack {
                        Button("重新关联资料库") {
                            libraryAccess.chooseLibraryFolder()
                        }
                        Button("立即备份清单") {
                            exportManifest()
                        }
                        Button("立即检查资料库") {
                            runLibraryHealthCheck(rootURL: rootURL)
                        }
                        .disabled(reconciliationCoordinator.isChecking)
                    }
                    if reconciliationCoordinator.isChecking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检查文件、恢复中断操作并修复本地元数据……")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if let report = reconciliationCoordinator.lastReport {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                            GridRow {
                                Text("最近检查").foregroundStyle(.secondary)
                                Text(report.checkedAt, format: .dateTime.year().month().day().hour().minute())
                            }
                            GridRow {
                                Text("已检查文件").foregroundStyle(.secondary)
                                Text(report.checkedFileCount.formatted())
                            }
                            GridRow {
                                Text("自动重新定位").foregroundStyle(.secondary)
                                Text(report.relocatedFileCount.formatted())
                            }
                            GridRow {
                                Text("修复元数据").foregroundStyle(.secondary)
                                Text(report.repairedMetadataCount.formatted())
                            }
                            GridRow {
                                Text("仍然缺失").foregroundStyle(.secondary)
                                Text(report.missingFileCount.formatted())
                                    .foregroundStyle(report.missingFileCount == 0 ? Color.secondary : Color.red)
                            }
                            if !report.transactionWarnings.isEmpty {
                                GridRow {
                                    Text("事务警告").foregroundStyle(.secondary)
                                    Text(report.transactionWarnings.count.formatted())
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    Text("可恢复清单会记录文献、分类、标签、项目、文件版本和分析状态，用于资料库移动或数据库损坏后的恢复。应用会自动更新它；通常不需要手动备份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("选择资料库文件夹") {
                        libraryAccess.chooseLibraryFolder()
                    }
                }
                if let errorText = manifestCoordinator.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let errorText = reconciliationCoordinator.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 720)
        .alert(
            "删除个人标记",
            isPresented: Binding(
                get: { personalMarkPendingDeletion != nil },
                set: { if !$0 { personalMarkPendingDeletion = nil } }
            )
        ) {
            Button("取消", role: .cancel) { personalMarkPendingDeletion = nil }
            Button("删除", role: .destructive) {
                if let mark = personalMarkPendingDeletion {
                    modelContext.delete(mark)
                    savePersonalMarks()
                }
                personalMarkPendingDeletion = nil
            }
        } message: {
            Text("删除“\(personalMarkPendingDeletion?.name ?? "")”只会移除这个个人标记，不会删除文章。")
        }
        .alert(
            "重建语义索引",
            isPresented: Binding(
                get: { searchProfilePendingRebuild != nil },
                set: { if !$0 { searchProfilePendingRebuild = nil } }
            )
        ) {
            Button("取消", role: .cancel) { searchProfilePendingRebuild = nil }
            Button("清除并重建", role: .destructive) {
                if let profile = searchProfilePendingRebuild {
                    searchCoordinator.rebuild(profile: profile)
                }
                searchProfilePendingRebuild = nil
            }
        } message: {
            Text("只会清除并重建“\(searchProfilePendingRebuild?.title ?? "")”的向量，另一套向量和正文索引不受影响。")
        }
        .task(id: "\(libraryAccess.libraryID?.uuidString ?? "")|\(searchIndexRevision)") {
            guard let rootURL = libraryAccess.rootURL,
                  let libraryID = libraryAccess.libraryID else { return }
            searchCoordinator.configure(
                libraryID: libraryID,
                rootURL: rootURL,
                snapshots: searchSnapshots
            )
        }
    }

    private var searchSnapshots: [SearchDocumentSnapshot] {
        works.compactMap { work in
            guard let version = work.preferredFileVersion else { return nil }
            return SearchDocumentSnapshot(
                workID: work.id,
                title: work.title,
                authors: work.authorsText,
                abstractText: work.abstractText,
                publicationYear: work.publicationYear,
                doi: work.doi,
                duplicateCandidateWorkID: work.duplicateCandidateWorkID,
                fileVersionID: version.id,
                relativePath: version.relativePath,
                sha256: version.sha256
            )
        }
    }

    private var searchIndexRevision: String {
        searchSnapshots.map {
            "\($0.workID.uuidString):\($0.fileVersionID.uuidString):\($0.sha256):\($0.relativePath):\($0.title):\($0.authors):\($0.publicationYear.map(String.init) ?? ""):\($0.doi ?? ""):\($0.duplicateCandidateWorkID?.uuidString ?? "")"
        }.sorted().joined(separator: "|")
    }

    @ViewBuilder
    private func localSearchProfileStatus(_ profile: LocalSearchProfile) -> some View {
        let statistics = searchCoordinator.profileStatistics[profile] ?? .empty(profile)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    profile.title,
                    systemImage: searchCoordinator.isModelVerified(profile)
                        ? "checkmark.circle.fill" : "network"
                )
                Spacer()
                Text(
                    searchCoordinator.isModelVerified(profile)
                        ? "接口已验证" : "接口未验证"
                )
                    .foregroundStyle(.secondary)
            }
            Text(profile.modelDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("接口模型：\(profile.modelID)\n版本：\(profile.revision)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if statistics.totalChunks > 0 {
                ProgressView(
                    value: Double(statistics.embeddedChunks),
                    total: Double(statistics.totalChunks)
                )
            }
            HStack {
                Text("向量 \(statistics.embeddedChunks)/\(statistics.totalChunks)")
                Text("·")
                Text("失败 \(statistics.failedChunks)")
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: statistics.storedBytes, countStyle: .file))
            }
            .font(.caption2)
            .foregroundStyle(statistics.failedChunks > 0 ? .red : .secondary)
        }
        .padding(.vertical, 3)
    }

    private func searchFailureTitle(_ failure: LocalSearchFailure) -> String {
        let workTitle = failure.workID.flatMap { id in
            works.first(where: { $0.id == id })?.title
        }
        let page: String
        if let start = failure.startPage, let end = failure.endPage {
            page = start == end ? "第 \(start) 页" : "第 \(start)–\(end) 页"
        } else {
            page = ""
        }
        let model = failure.modelSignature.flatMap { signature -> String? in
            if signature == LocalSearchConfiguration.rerankerSignature { return "重排模型" }
            return LocalSearchProfile.allCases.first {
                $0.vectorSpaceSignature == signature
            }?.title
        }
        return [failure.stage.title, model, workTitle, page]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var expenseItems: [AIExpenseItem] {
        works.flatMap { work in
            work.analyses.map {
                AIExpenseItem(createdAt: $0.createdAt, costUSD: $0.estimatedCostUSD, kind: .researchCard)
            } + work.studyNoteGenerations.map {
                AIExpenseItem(createdAt: $0.createdAt, costUSD: $0.estimatedCostUSD, kind: .studyNote)
            }
        }
    }

    private var dailyExpenses: [DailyAIExpense] {
        AIExpenseSummary.dailyTotals(for: expenseItems)
    }

    private var todayExpenseUSD: Double {
        dailyExpenses.first(where: { Calendar.current.isDateInToday($0.date) })?.totalCostUSD ?? 0
    }

    private var currentMonthExpenseUSD: Double {
        guard let interval = Calendar.current.dateInterval(of: .month, for: .now) else { return 0 }
        return expenseItems
            .filter { interval.contains($0.createdAt) }
            .reduce(0) { $0 + max($1.costUSD, 0) }
    }

    private func saveAPIKey() {
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try LocalAPIKeyStore.shared.delete()
                statusText = "密钥已删除。"
            } else {
                try LocalAPIKeyStore.shared.save(trimmed)
                statusText = "密钥已保存到应用的本地私有目录。"
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func saveBailianConfiguration() {
        do {
            try searchCoordinator.saveBailianConfiguration(
                workspaceID: bailianWorkspaceID,
                apiKey: bailianAPIKey
            )
            bailianWorkspaceID = searchCoordinator.bailianWorkspaceID
            if searchCoordinator.isBailianConfigured {
                bailianStatusText = "配置已保存，请继续验证云端语义服务。"
            } else {
                bailianAPIKey = ""
                bailianStatusText = "百炼配置已删除。"
            }
        } catch {
            bailianStatusText = error.localizedDescription
        }
    }

    private func uniquePersonalMarkName() -> String {
        var number = 1
        while personalMarks.contains(where: { $0.name == "新标记\(number)" }) {
            number += 1
        }
        return "新标记\(number)"
    }

    private func movePersonalMark(_ mark: PersonalMark, offset: Int) {
        let ordered = personalMarks.sorted { $0.sortOrder < $1.sortOrder }
        guard let index = ordered.firstIndex(where: { $0.id == mark.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        let other = ordered[target]
        (mark.sortOrder, other.sortOrder) = (other.sortOrder, mark.sortOrder)
        savePersonalMarks()
    }

    private func savePersonalMarks() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            statusText = "保存个人标记失败：\(error.localizedDescription)"
        }
    }

    private func personalMarkTextColorBinding(_ mark: PersonalMark) -> Binding<Color> {
        Binding(
            get: { Color(hex: mark.colorHex) },
            set: { color in
                mark.colorHex = color.hexString
                savePersonalMarks()
            }
        )
    }

    private func personalMarkBackgroundColorBinding(_ mark: PersonalMark) -> Binding<Color> {
        Binding(
            get: { Color(hex: mark.effectiveBackgroundColorHex) },
            set: { color in
                mark.backgroundColorHex = color.hexString
                savePersonalMarks()
            }
        )
    }

    private func validateModel() {
        guard let key = LocalAPIKeyStore.shared.readIfAvailable(), !key.isEmpty else {
            statusText = "请先保存密钥。"
            return
        }
        statusText = "正在验证……"
        Task {
            do {
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
                guard let encoded = geminiModel.addingPercentEncoding(withAllowedCharacters: allowed),
                      let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded)")
                else { return }
                var request = URLRequest(url: url)
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                statusText = "模型可用。"
            } catch {
                statusText = "验证失败：\(error.localizedDescription)"
            }
        }
    }

    private func copyLocalSearchModelTestReport() {
        let report = searchCoordinator.modelTestReportText
        guard !report.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func chooseReader() {
        let panel = NSOpenPanel()
        panel.title = "选择 PDF 阅读器"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExternalPDFOpener.setSelectedReader(url)
            readerName = url.deletingPathExtension().lastPathComponent
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func exportManifest() {
        guard let rootURL = libraryAccess.rootURL, let libraryID = libraryAccess.libraryID else { return }
        Task {
            await manifestCoordinator.export(
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

    private func runLibraryHealthCheck(rootURL: URL) {
        Task {
            let report = await reconciliationCoordinator.reconcile(
                rootURL: rootURL,
                modelContext: modelContext
            )
            if report != nil { exportManifest() }
        }
    }
}

private struct LocalSearchModelTestResultRow: View {
    let result: LocalSearchModelTestResult

    private var statusColor: Color {
        result.passed ? .green : .red
    }

    private var statusIcon: String {
        result.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: statusIcon)
                Text(result.title + "：" + result.statusTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f 秒", result.duration))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(statusColor)
            Text(result.detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(result.passed ? Color.secondary : Color.red)
        }
    }
}

enum ExternalPDFOpener {
    private static let bookmarkKey = "externalPDFReaderBookmark"

    static var selectedReaderName: String? {
        guard let url = selectedReaderURL() else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func setSelectedReader(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func clearSelectedReader() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    @MainActor
    static func open(
        _ pdfURL: URL,
        completion: (@MainActor @Sendable (String?) -> Void)? = nil
    ) {
        guard let applicationURL = selectedReaderURL() else {
            let opened = NSWorkspace.shared.open(pdfURL)
            completion?(opened ? nil : "系统无法打开这份 PDF。")
            return
        }
        let hasAccess = applicationURL.startAccessingSecurityScopedResource()
        NSWorkspace.shared.open(
            [pdfURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if hasAccess { applicationURL.stopAccessingSecurityScopedResource() }
            Task { @MainActor in
                guard error != nil else {
                    completion?(nil)
                    return
                }
                let fallbackOpened = NSWorkspace.shared.open(pdfURL)
                completion?(fallbackOpened ? nil : "指定的阅读器不可用，系统默认阅读器也无法打开这份 PDF。")
            }
        }
    }

    private static func selectedReaderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale { try? setSelectedReader(url) }
        return url
    }
}
