import AppKit
import SwiftData
import SwiftUI

private struct InspectorAnalysisDecodeRequest: Equatable, Sendable {
    let recordID: UUID?
    let resultJSON: String?
}

private struct InspectorStudyNoteCandidate: Equatable, Sendable {
    let id: UUID
    let status: String
    let completedParts: Int
    let totalParts: Int

    var canResume: Bool {
        (status == "failed" || status == "cancelled") &&
            completedParts > 0 &&
            totalParts > completedParts
    }
}

private struct InspectorFileCheckRequest: Equatable, Sendable {
    let preferredVersionID: UUID?
    let relativePath: String?
    let rootURL: URL
    let studyNotes: [InspectorStudyNoteCandidate]
}

private struct InspectorFileCheckResult: Sendable {
    let preferredPDFURL: URL?
    let resumableStudyNoteIDs: Set<UUID>
}

struct WorkInspector: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var searchCoordinator: SearchIndexCoordinator
    @Bindable var work: Work
    let categories: [Category]
    let availableTags: [Tag]
    let availablePersonalMarks: [PersonalMark]
    let rootURL: URL
    let onDelete: (Work) -> Void

    @StateObject private var archiver = ArchiveCoordinator()
    @StateObject private var metadataCoordinator = MetadataCoordinator()
    @StateObject private var openAlexCoordinator = OpenAlexJournalMetricsCoordinator()
    @StateObject private var aiCoordinator = AIAnalysisCoordinator()
    @ObservedObject var studyNoteCoordinator: StudyNoteCoordinator
    @StateObject private var reprocessingCoordinator = WorkReprocessingCoordinator()
    private let fileActor = LibraryFileActor()
    @State private var title: String
    @State private var authorsText: String
    @State private var yearText: String
    @State private var categoryID: UUID?
    @State private var newTagName = ""
    @State private var showingReprocessConfirmation = false
    @State private var showingStudyNoteCreationOptions = false
    @State private var preferredVersionCandidate: FileVersion?
    @State private var isUpdatingFileVersions = false
    @State private var manualMetadataChanged = false
    @State private var localError: String?
    @State private var decodedLatestAnalysis: PaperAnalysis?
    @State private var validatedPreferredPDFURL: URL?
    @State private var resumableStudyNoteIDs: Set<UUID> = []

    init(
        work: Work,
        categories: [Category],
        availableTags: [Tag],
        availablePersonalMarks: [PersonalMark],
        rootURL: URL,
        studyNoteCoordinator: StudyNoteCoordinator,
        onDelete: @escaping (Work) -> Void
    ) {
        self.work = work
        self.categories = categories
        self.availableTags = availableTags
        self.availablePersonalMarks = availablePersonalMarks
        self.rootURL = rootURL
        self.studyNoteCoordinator = studyNoteCoordinator
        self.onDelete = onDelete
        _title = State(initialValue: work.title)
        _authorsText = State(initialValue: work.authorsText)
        _yearText = State(initialValue: work.publicationYear.map(String.init) ?? "")
        _categoryID = State(initialValue: work.primaryCategory?.id)
        _decodedLatestAnalysis = State(initialValue: nil)
    }

    private var presentedErrorText: String? {
        if let value = archiver.errorText { return value }
        if let value = metadataCoordinator.errorText { return value }
        if let value = aiCoordinator.errorText { return value }
        if let value = studyNoteCoordinator.errorText { return value }
        if let value = reprocessingCoordinator.errorText { return value }
        if let value = searchCoordinator.errorText { return value }
        return localError
    }

    private var resumableStudyNote: StudyNoteGeneration? {
        return work.studyNoteGenerations
            .filter { resumableStudyNoteIDs.contains($0.id) }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    private var preferredPDFURL: URL? {
        validatedPreferredPDFURL
    }

    private var unusedTags: [Tag] {
        availableTags.filter { candidate in
            !work.tags.contains(where: { $0.id == candidate.id })
        }
    }

    private var unusedPersonalMarks: [PersonalMark] {
        availablePersonalMarks.filter { candidate in
            !work.personalMarks.contains(where: { $0.id == candidate.id })
        }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var analysisDecodeRequest: InspectorAnalysisDecodeRequest {
        let latest = latestAnalysisRecord
        return InspectorAnalysisDecodeRequest(
            recordID: latest?.id,
            resultJSON: latest?.resultJSON
        )
    }

    private var fileCheckRequest: InspectorFileCheckRequest {
        let preferred = work.preferredFileVersion
        let notes = work.studyNoteGenerations
            .map {
                InspectorStudyNoteCandidate(
                    id: $0.id,
                    status: $0.status,
                    completedParts: $0.completedParts,
                    totalParts: $0.totalParts
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return InspectorFileCheckRequest(
            preferredVersionID: preferred?.id,
            relativePath: preferred?.relativePath,
            rootURL: rootURL,
            studyNotes: notes
        )
    }

    private var openAlexLookupIdentity: String {
        let doi = PDFMetadataExtractor.normalizedDOI(work.doi) ?? ""
        let journal = (work.journal ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(doi)|\(journal)"
    }

    var body: some View {
        Form {
            Section("书目信息") {
                if work.crossrefChecked {
                    Label("Crossref 已核对", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.blue)
                } else {
                    Label("尚未获得 Crossref 核对结果", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                TextField("标题", text: $title, axis: .vertical)
                    .onSubmit { archiveIfNeeded() }
                TextField("作者", text: $authorsText)
                    .onSubmit { archiveIfNeeded() }
                TextField("发表年份", text: $yearText)
                    .onSubmit { archiveIfNeeded() }
                TextField("DOI", text: Binding(
                    get: { work.doi ?? "" },
                    set: {
                        let newValue = $0.isEmpty ? nil : $0
                        if PDFMetadataExtractor.normalizedDOI(work.doi) !=
                            PDFMetadataExtractor.normalizedDOI(newValue) {
                            work.clearOpenAlexJournalMetrics()
                        }
                        work.doi = newValue
                        markManualMetadataChanged()
                    }
                ))
                    .onSubmit {
                        saveManualMetadata()
                        refreshOpenAlex(force: true)
                    }
                if let nber = work.nberNumber { LabeledContent("NBER", value: nber) }
                if let ssrn = work.ssrnID { LabeledContent("SSRN", value: ssrn) }
                if let arxiv = work.arxivID { LabeledContent("arXiv", value: arxiv) }
                if let repec = work.repecHandle { LabeledContent("RePEc", value: repec) }
                TextField("期刊", text: Binding(
                    get: { work.journal ?? "" },
                    set: {
                        let newValue = $0.isEmpty ? nil : $0
                        if work.journal != newValue {
                            work.clearOpenAlexJournalMetrics()
                        }
                        work.journal = newValue
                        markManualMetadataChanged()
                    }
                ))
                    .onSubmit {
                        saveManualMetadata()
                        refreshOpenAlex(force: true)
                    }
                Picker("文献类型", selection: Binding(
                    get: { work.documentTypeRawValue ?? "unknown" },
                    set: {
                        work.documentTypeRawValue = $0 == "unknown" ? nil : $0
                        markManualMetadataChanged()
                        saveManualMetadata()
                    }
                )) {
                    Text("未知").tag("unknown")
                    Text("期刊论文").tag("article")
                    Text("工作论文").tag("workingPaper")
                    Text("书籍").tag("book")
                    Text("书籍章节").tag("bookChapter")
                    Text("研究报告").tag("report")
                    Text("学位论文").tag("thesis")
                    Text("其他").tag("other")
                }
                TextField("ISBN", text: Binding(
                    get: { work.isbn ?? "" },
                    set: {
                        work.isbn = $0.isEmpty ? nil : $0
                        markManualMetadataChanged()
                    }
                ))
                TextField("出版社", text: Binding(
                    get: { work.publisher ?? "" },
                    set: {
                        work.publisher = $0.isEmpty ? nil : $0
                        markManualMetadataChanged()
                    }
                ))
                if let note = work.metadataConflictNote {
                    if WorkReviewRules.hasPageNumberWarning(work),
                       !WorkReviewRules.requiresReview(work) {
                        Label(WorkReviewRules.pageNumberWarning, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if work.needsReview, work.duplicateCandidateWorkID != nil {
                    Label("这篇文献可能与现有记录重复。", systemImage: "doc.on.doc")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("合并到候选记录") { mergeWithCandidate() }
                        Button("确认不是重复") {
                            work.needsReview = false
                            work.duplicateCandidateWorkID = nil
                            saveInspectorChanges("保存重复检查结果")
                        }
                    }
                }
                Picker("主分类", selection: $categoryID) {
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                .onChange(of: categoryID) { _, newValue in
                    if newValue != work.primaryCategory?.id {
                        archive()
                    }
                }

                Button {
                    metadataCoordinator.enrich(work: work, modelContext: modelContext)
                } label: {
                    if metadataCoordinator.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("重新使用 Crossref 核对")
                    }
                }
                .disabled(metadataCoordinator.isLoading)
                .help("导入时会自动核对；此按钮用于手动重试或刷新结果。")
            }

            Section("OpenAlex 期刊评价") {
                if let metrics = work.openAlexJournalMetrics {
                    LabeledContent("期刊", value: metrics.sourceName)
                    if let value = metrics.twoYearMeanCitedness {
                        LabeledContent(
                            "两年平均被引率",
                            value: value.formatted(.number.precision(.fractionLength(2)))
                        )
                    }
                    if let value = metrics.hIndex {
                        LabeledContent("h 指数", value: value.formatted())
                    }
                    if let value = metrics.i10Index {
                        LabeledContent("至少被引 10 次的论文", value: value.formatted())
                    }
                    LabeledContent("收录论文", value: metrics.worksCount.formatted())
                    LabeledContent("总引用", value: metrics.citedByCount.formatted())
                    if !metrics.issns.isEmpty {
                        LabeledContent("ISSN", value: metrics.issns.joined(separator: "、"))
                    }
                    LabeledContent("匹配依据", value: metrics.matchMethod.localizedName)
                    if let value = metrics.sourceUpdatedDate {
                        LabeledContent("OpenAlex 数据更新", value: value)
                    }
                    LabeledContent(
                        "本地获取",
                        value: metrics.fetchedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    if let url = metrics.sourceURL {
                        Link("在 OpenAlex 查看期刊", destination: url)
                    }
                    Text("两年平均被引率是 OpenAlex 的开放指标，不是 JIF；OpenAlex 不提供 JCR 分区。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let message = openAlexCoordinator.lookupMessage {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if !openAlexCoordinator.isLoading {
                    Text("尚未查询 OpenAlex 期刊评价。")
                        .foregroundStyle(.secondary)
                }

                if let error = openAlexCoordinator.errorText {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Button {
                    refreshOpenAlex(force: true)
                } label: {
                    if openAlexCoordinator.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在查询 OpenAlex…")
                        }
                    } else {
                        Text("刷新 OpenAlex 评价")
                    }
                }
                .disabled(openAlexCoordinator.isLoading)
            }

            Section("个人标记") {
                if work.personalMarks.isEmpty {
                    Text("尚无个人标记").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(work.personalMarks.sorted(by: { $0.sortOrder < $1.sortOrder })) { mark in
                            HStack(spacing: 5) {
                                Text(mark.name).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { togglePersonalMark(mark, enabled: false) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .foregroundStyle(Color(hex: mark.colorHex))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                Color(hex: mark.effectiveBackgroundColorHex),
                                in: Capsule()
                            )
                        }
                    }
                }
                if !unusedPersonalMarks.isEmpty {
                    Menu("添加个人标记", systemImage: "bookmark.badge.plus") {
                        ForEach(unusedPersonalMarks) { mark in
                            Button(mark.name) { togglePersonalMark(mark, enabled: true) }
                        }
                    }
                }
            }

            Section("标签") {
                if work.tags.isEmpty {
                    Label("尚无标签", systemImage: "tag")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(work.tags.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { tag in
                            HStack(spacing: 5) {
                                Image(systemName: "tag.fill")
                                Text(tag.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    toggleTag(tag, enabled: false)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("从这篇文献移除标签")
                            }
                            .font(.caption)
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.indigo.opacity(0.09), in: Capsule())
                        }
                    }
                }

                if !unusedTags.isEmpty {
                    Menu("添加已有标签", systemImage: "tag.badge.plus") {
                        ForEach(unusedTags) { tag in
                            Button(tag.name) { toggleTag(tag, enabled: true) }
                        }
                    }
                }

                HStack {
                    TextField("新建标签", text: $newTagName)
                        .onSubmit { addTag() }
                    Button("新建并添加") { addTag() }
                        .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("文件与版本") {
                if isUpdatingFileVersions {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在整理文章文件夹……")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(work.fileVersions) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(file.originalFilename).lineLimit(1)
                            Spacer()
                            if file.isPreferred {
                                Text("主要版本").foregroundStyle(.secondary)
                            } else if file.versionTypeRawValue == "supplement" {
                                Text("附件").foregroundStyle(.secondary)
                            } else {
                                Button("设为主要版本") { setPreferred(file) }
                                    .buttonStyle(.link)
                            }
                            if work.fileVersions.count > 1 {
                                Button("拆分") { splitVersion(file) }
                                    .buttonStyle(.link)
                            }
                        }
                        LabeledContent("页数", value: "\(file.pageCount)")
                        LabeledContent("文件元数据年份", value: file.fileMetadataYear.map(String.init) ?? "未知")
                        if let value = file.bibliographicTitle, value != work.title {
                            LabeledContent("版本标题", value: value)
                        }
                        if let value = file.bibliographicYear, value != work.publicationYear {
                            LabeledContent("版本年份", value: value.formatted())
                        }
                        if let value = file.bibliographicDOI,
                           PDFMetadataExtractor.normalizedDOI(value) != PDFMetadataExtractor.normalizedDOI(work.doi) {
                            LabeledContent("版本 DOI", value: value)
                        }
                        LabeledContent("位置", value: file.relativePath)
                        Picker("版本类型", selection: Binding(
                            get: { file.versionTypeRawValue },
                            set: {
                                updateVersionType(file, to: $0)
                            }
                        )) {
                            Text("未知").tag("unknown")
                            Text("正式发表版").tag("published")
                            Text("工作论文").tag("workingPaper")
                            Text("录用稿").tag("acceptedManuscript")
                            Text("预印本").tag("preprint")
                            Text("补充材料").tag("supplement")
                            Text("带标注副本").tag("annotatedCopy")
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(isUpdatingFileVersions)
                }

                Button("打开主要 PDF") { openPreferred() }
                Button("在 Finder 中显示") { revealPreferred() }
                Divider()
                Button("笔记", systemImage: "square.and.pencil") { createOrOpenRegularNote() }
                Button {
                    openOrOfferStudyNote()
                } label: {
                    Label(
                        studyNoteCoordinator.isGenerating ? "显示精读笔记处理窗口" : "精读笔记",
                        systemImage: studyNoteCoordinator.isGenerating
                            ? "rectangle.on.rectangle" : "text.book.closed"
                    )
                }
            }

            Section("AI 研究卡") {
                HStack {
                    Button("快速提取") { analyze(.extract) }
                        .disabled(aiCoordinator.isAnalyzing || reprocessingCoordinator.isPreparing)
                    Button("深度分析") { analyze(.deep) }
                        .disabled(aiCoordinator.isAnalyzing || reprocessingCoordinator.isPreparing)
                    if aiCoordinator.isAnalyzing {
                        ProgressView().controlSize(.small)
                        Button("取消") { aiCoordinator.cancel() }
                    }
                }

                Button {
                    showingReprocessConfirmation = true
                } label: {
                    if reprocessingCoordinator.isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("按最新规则重新处理", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(aiCoordinator.isAnalyzing || reprocessingCoordinator.isPreparing)
                .help("保留 PDF、用户标签和历史分析，重新提取书目信息、网络核对并分类。")

                if let latest = latestAnalysisRecord {
                    LabeledContent("状态", value: analysisStatus(latest.status, for: work))
                    LabeledContent("模型", value: latest.modelName)
                    if let analyzedVersionID = latest.analyzedFileVersionID,
                       analyzedVersionID != work.preferredFileVersion?.id {
                        Label(
                            "这张研究卡基于旧的主要版本生成，可按需使用当前主要版本重新分析。",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .foregroundStyle(.orange)
                    }
                    if latest.status == "completed",
                       let analysis = decodedLatestAnalysis {
                        AnalysisCardView(analysis: analysis)
                        LabeledContent("总令牌", value: "\(latest.totalTokens)")
                        LabeledContent("估算费用", value: latest.estimatedCostUSD, format: .currency(code: "USD"))
                    } else if latest.status == "completed", latest.resultJSON != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在准备分析结果…").foregroundStyle(.secondary)
                        }
                    } else if let error = latest.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                } else {
                    Text("尚未分析").foregroundStyle(.secondary)
                }
            }

            Section("精读笔记费用") {
                if work.studyNoteGenerations.isEmpty {
                    Text("尚无精读笔记记录").foregroundStyle(.secondary)
                } else {
                    ForEach(work.studyNoteGenerations.sorted(by: { $0.createdAt > $1.createdAt })) { note in
                        DisclosureGroup {
                            LabeledContent("状态", value: analysisStatus(note.status))
                            LabeledContent("模型", value: note.modelName)
                            LabeledContent("输入令牌", value: note.inputTokens.formatted())
                            LabeledContent("其中缓存输入", value: note.cachedInputTokens.formatted())
                            LabeledContent("输出令牌", value: note.outputTokens.formatted())
                            LabeledContent("总令牌", value: note.totalTokens.formatted())
                            LabeledContent("完成部分", value: "\(note.completedParts) / \(note.totalParts)")
                            if let filename = note.downloadedFilename {
                                LabeledContent("笔记文件", value: filename)
                            }
                            if let error = note.errorMessage, !error.isEmpty {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if preferredPDFURL != nil,
                               resumableStudyNoteIDs.contains(note.id) {
                                Button("继续精读", systemImage: "play.fill") {
                                    resumeStudyNote(note)
                                }
                                .disabled(studyNoteCoordinator.isGenerating)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    Text(analysisStatus(note.status))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(note.estimatedCostUSD, format: .currency(code: "USD"))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section("文章操作") {
                Button("删除文章…", systemImage: "trash", role: .destructive) {
                    onDelete(work)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: work.title) { _, value in title = value }
        .onChange(of: work.authorsText) { _, value in authorsText = value }
        .onChange(of: work.publicationYear) { _, value in yearText = value.map(String.init) ?? "" }
        .onChange(of: work.primaryCategory?.id) { _, value in categoryID = value }
        .task(id: analysisDecodeRequest) {
            await loadLatestAnalysis(for: analysisDecodeRequest)
        }
        .task(id: fileCheckRequest) {
            await refreshFileAvailability(for: fileCheckRequest)
        }
        .task(id: openAlexLookupIdentity) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await openAlexCoordinator.refresh(work: work, modelContext: modelContext)
        }
        .onDisappear {
            archiveIfNeeded()
            saveManualMetadata()
        }
        .confirmationDialog(
            "按最新规则重新处理？",
            isPresented: $showingReprocessConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置并重新处理", role: .destructive) { reprocess() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会重置当前自动书目信息和主分类，然后重新运行 AI 提取与网络核对。PDF、用户标签和历史分析不会删除。")
        }
        .confirmationDialog(
            resumableStudyNote == nil ? "创建精读笔记" : "继续精读笔记",
            isPresented: $showingStudyNoteCreationOptions,
            titleVisibility: .visible
        ) {
            if let resumableStudyNote {
                Button("继续未完成的精读") { resumeStudyNote(resumableStudyNote) }
            }
            Button("创建空白精读笔记") { createBlankStudyNote() }
            Button("使用人工智能生成") { generateStudyNote() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                resumableStudyNote == nil
                    ? "这篇文献还没有精读笔记。请选择创建方式。"
                    : "发现保存在论文文件夹中的未完成检查点，可以从下一部分继续。"
            )
        }
        .alert("操作失败", isPresented: Binding(
            get: { presentedErrorText != nil },
            set: {
                if !$0 { dismissPresentedError() }
            }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(presentedErrorText ?? "")
        }
        .sheet(isPresented: $studyNoteCoordinator.isPresenting) {
            StudyNoteProgressView(coordinator: studyNoteCoordinator)
        }
        .sheet(item: $preferredVersionCandidate) { version in
            PreferredVersionSelectionSheet(
                version: version,
                fallbackTitle: work.title,
                fallbackAuthorsText: work.authorsText,
                fallbackYear: work.publicationYear,
                fallbackJournal: work.journal,
                fallbackDOI: work.doi,
                onConfirm: { title, authors, year, journal, doi in
                    preferredVersionCandidate = nil
                    promotePreferredVersion(
                        version,
                        title: title,
                        authorsText: authors,
                        publicationYear: year,
                        journal: journal,
                        doi: doi
                    )
                },
                onCancel: {
                    preferredVersionCandidate = nil
                }
            )
        }
    }

    private func archive() {
        let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let category = categories.first { $0.id == categoryID }
        archiver.archive(
            work: work,
            title: title,
            authorsText: authorsText,
            publicationYear: year,
            category: category,
            in: rootURL,
            modelContext: modelContext
        )
    }

    private func archiveIfNeeded() {
        let parsedYear = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard title != work.title || authorsText != work.authorsText ||
                parsedYear != work.publicationYear || categoryID != work.primaryCategory?.id
        else { return }
        archive()
    }

    private func markManualMetadataChanged() {
        manualMetadataChanged = true
        if work.crossrefVerifiedDOI == nil,
           work.metadataSource.caseInsensitiveCompare("crossref") == .orderedSame {
            work.crossrefVerifiedDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
        }
        work.metadataSource = "manual"
        work.metadataConfirmed = true
    }

    private func saveManualMetadata() {
        guard manualMetadataChanged else { return }
        do {
            try modelContext.save()
            manualMetadataChanged = false
        } catch {
            localError = "保存手动修改失败：\(error.localizedDescription)"
        }
    }

    private func refreshOpenAlex(force: Bool) {
        Task {
            await openAlexCoordinator.refresh(
                work: work,
                modelContext: modelContext,
                force: force
            )
        }
    }

    private func dismissPresentedError() {
        if archiver.errorText != nil { archiver.errorText = nil; return }
        if metadataCoordinator.errorText != nil { metadataCoordinator.errorText = nil; return }
        if aiCoordinator.errorText != nil { aiCoordinator.errorText = nil; return }
        if studyNoteCoordinator.errorText != nil { studyNoteCoordinator.errorText = nil; return }
        if reprocessingCoordinator.errorText != nil { reprocessingCoordinator.errorText = nil; return }
        if searchCoordinator.errorText != nil { searchCoordinator.dismissError(); return }
        localError = nil
    }

    private func saveInspectorChanges(_ action: String) {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            localError = "\(action)失败：\(error.localizedDescription)"
        }
    }

    private var latestAnalysisRecord: AIAnalysis? {
        work.analyses.max(by: { $0.createdAt < $1.createdAt })
    }

    nonisolated private static func decodeAnalysis(_ json: String?) -> PaperAnalysis? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PaperAnalysis.self, from: data)
    }

    private func loadLatestAnalysis(for request: InspectorAnalysisDecodeRequest) async {
        decodedLatestAnalysis = nil
        guard request.recordID != nil, request.resultJSON != nil else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeAnalysis(request.resultJSON)
        }.value
        guard !Task.isCancelled, analysisDecodeRequest == request else { return }
        decodedLatestAnalysis = decoded
    }

    private func refreshFileAvailability(for request: InspectorFileCheckRequest) async {
        validatedPreferredPDFURL = nil
        resumableStudyNoteIDs.removeAll()
        let result = await Task.detached(priority: .userInitiated) {
            Self.checkFileAvailability(for: request)
        }.value
        guard !Task.isCancelled, fileCheckRequest == request else { return }
        validatedPreferredPDFURL = result.preferredPDFURL
        resumableStudyNoteIDs = result.resumableStudyNoteIDs
    }

    nonisolated private static func checkFileAvailability(
        for request: InspectorFileCheckRequest
    ) -> InspectorFileCheckResult {
        guard let relativePath = request.relativePath,
              let pdfURL = try? LibraryPathSafety.url(
                for: relativePath,
                inside: request.rootURL,
                requirePDF: true,
                requireExistingRegularFile: true
              )
        else {
            return InspectorFileCheckResult(
                preferredPDFURL: nil,
                resumableStudyNoteIDs: []
            )
        }
        let resumableIDs: Set<UUID> = Set(request.studyNotes.compactMap { note -> UUID? in
            guard note.canResume,
                  StudyNoteCheckpointStore.hasRecoverableCheckpoint(
                    taskID: note.id,
                    pdfURL: pdfURL
                  )
            else { return nil }
            return note.id
        })
        return InspectorFileCheckResult(
            preferredPDFURL: pdfURL,
            resumableStudyNoteIDs: resumableIDs
        )
    }

    private func toggleTag(_ tag: Tag, enabled: Bool) {
        if enabled {
            if !work.tags.contains(where: { $0.id == tag.id }) {
                work.tags.append(tag)
            }
        } else {
            work.tags.removeAll { $0.id == tag.id }
        }
        do {
            _ = try TagMaintenance.deleteOrphans(modelContext: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            localError = "修改标签失败：\(error.localizedDescription)"
        }
    }

    private func togglePersonalMark(_ mark: PersonalMark, enabled: Bool) {
        if enabled {
            if !work.personalMarks.contains(where: { $0.id == mark.id }) {
                work.personalMarks.append(mark)
            }
        } else {
            work.personalMarks.removeAll { $0.id == mark.id }
        }
        saveInspectorChanges("修改个人标记")
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let tag = availableTags.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        } ?? Tag(name: name)
        if tag.modelContext == nil {
            modelContext.insert(tag)
        }
        if !work.tags.contains(where: { $0.id == tag.id }) {
            work.tags.append(tag)
        }
        saveInspectorChanges("添加标签")
        newTagName = ""
    }

    private func setPreferred(_ selected: FileVersion) {
        guard !isUpdatingFileVersions else { return }
        guard selected.versionTypeRawValue != "supplement" else {
            localError = "补充材料不能设为主要版本。"
            return
        }
        preferredVersionCandidate = selected
    }

    private func updateVersionType(_ file: FileVersion, to newValue: String) {
        guard !isUpdatingFileVersions else { return }
        guard file.versionTypeRawValue != newValue else { return }
        guard !file.isPreferred || newValue != "supplement" else {
            localError = "主要版本不能改为补充材料；请先选择另一个主要版本。"
            return
        }
        file.versionTypeRawValue = newValue
        guard let request = ArchiveRules.articleRelocationRequest(for: work) else {
            saveInspectorChanges("保存文件版本类型")
            return
        }
        isUpdatingFileVersions = true
        Task {
            defer { isUpdatingFileVersions = false }
            do {
                let batch = try await fileActor.relocateArticles([request], in: rootURL)
                let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                    ($0.fileVersionID, $0.destinationRelativePath)
                })
                for version in work.fileVersions where paths[version.id] != nil {
                    version.relativePath = paths[version.id]!
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
                    localError = "版本类型已保存，文件事务记录将在下次启动时清理。"
                }
            } catch {
                modelContext.rollback()
                localError = "修改版本类型失败：\(error.localizedDescription)"
            }
        }
    }

    private func promotePreferredVersion(
        _ selected: FileVersion,
        title newTitle: String,
        authorsText newAuthorsText: String,
        publicationYear newPublicationYear: Int?,
        journal newJournal: String?,
        doi newDOI: String?
    ) {
        guard selected.work?.id == work.id || work.fileVersions.contains(where: { $0.id == selected.id }) else {
            localError = "要设置的文件版本已经不属于这篇文献。"
            return
        }
        guard let request = ArchiveRules.articleRelocationRequest(
            for: work,
            title: newTitle,
            authorsText: newAuthorsText,
            publicationYear: newPublicationYear,
            categoryName: work.primaryCategory?.name,
            metadataConfirmed: true,
            preferredVersion: selected
        ) else {
            localError = "无法根据所选版本建立文件整理计划。"
            return
        }

        isUpdatingFileVersions = true
        Task {
            defer { isUpdatingFileVersions = false }
            do {
                let batch = try await fileActor.relocateArticles([request], in: rootURL)
                let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                    ($0.fileVersionID, $0.destinationRelativePath)
                })
                let previousDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
                let previousJournal = work.journal
                let previousPreferredID = work.preferredFileVersion?.id
                let crossrefConfirmed = selected.bibliographicMetadataConfirmed &&
                    selected.bibliographicMetadataSource?.caseInsensitiveCompare("crossref") == .orderedSame &&
                    PDFMetadataExtractor.normalizedDOI(selected.bibliographicDOI) == newDOI

                for file in work.fileVersions {
                    file.isPreferred = file.id == selected.id
                    if let path = paths[file.id] { file.relativePath = path }
                }
                if let previousPreferredID, previousPreferredID != selected.id {
                    for analysis in work.analyses where analysis.analyzedFileVersionID == nil {
                        analysis.analyzedFileVersionID = previousPreferredID
                    }
                }
                selected.bibliographicTitle = newTitle
                selected.bibliographicAuthorsText = newAuthorsText.isEmpty ? nil : newAuthorsText
                selected.bibliographicYear = newPublicationYear
                selected.bibliographicJournal = newJournal
                selected.bibliographicDOI = newDOI
                selected.bibliographicMetadataSource = crossrefConfirmed ? "crossref" : "manual"
                selected.bibliographicMetadataConfirmed = true

                work.title = newTitle
                work.authorsText = newAuthorsText
                work.publicationYear = newPublicationYear
                work.journal = newJournal
                work.doi = newDOI
                switch selected.versionTypeRawValue {
                case "published", "acceptedManuscript", "preprint":
                    work.documentTypeRawValue = "article"
                case "workingPaper":
                    work.documentTypeRawValue = "workingPaper"
                default:
                    break
                }
                work.metadataSource = crossrefConfirmed ? "crossref" : "manual"
                work.crossrefVerifiedDOI = crossrefConfirmed ? newDOI : nil
                work.metadataConfirmed = true
                if previousDOI != newDOI || previousJournal != newJournal {
                    work.clearOpenAlexJournalMetrics()
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
                    localError = "主要版本已更新，文件事务记录将在下次启动时清理。"
                }
                title = work.title
                authorsText = work.authorsText
                yearText = work.publicationYear.map(String.init) ?? ""
            } catch {
                localError = "设置主要版本失败：\(error.localizedDescription)"
            }
        }
    }

    private func openPreferred() {
        guard let path = work.preferredFileVersion?.relativePath else { return }
        guard let url = try? LibraryPathSafety.url(
            for: path,
            inside: rootURL,
            requirePDF: true,
            requireExistingRegularFile: true
        ) else {
            localError = "PDF 路径无效或文件已丢失。"
            return
        }
        ExternalPDFOpener.open(url) { error in
            if let error {
                localError = error
            } else {
                work.lastOpenedAt = .now
                saveInspectorChanges("记录打开时间")
            }
        }
    }

    private func revealPreferred() {
        guard let path = work.preferredFileVersion?.relativePath else { return }
        guard let url = try? LibraryPathSafety.url(
            for: path,
            inside: rootURL,
            requirePDF: true,
            requireExistingRegularFile: true
        ) else {
            localError = "PDF 路径无效或文件已丢失。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func analyze(_ mode: AnalysisMode) {
        guard let file = work.preferredFileVersion else { return }
        guard let pdfURL = try? LibraryPathSafety.url(
            for: file.relativePath,
            inside: rootURL,
            requirePDF: true,
            requireExistingRegularFile: true
        ) else {
            localError = "PDF 路径无效或文件已丢失。"
            return
        }
        aiCoordinator.analyze(
            work: work,
            pdfURL: pdfURL,
            pageCount: file.pageCount,
            mode: mode,
            categories: categories,
            rootURL: rootURL,
            modelContext: modelContext
        )
    }

    private func generateStudyNote() {
        guard let file = work.preferredFileVersion,
              let pdfURL = try? LibraryPathSafety.url(
                for: file.relativePath,
                inside: rootURL,
                requirePDF: true,
                requireExistingRegularFile: true
              )
        else {
            localError = "PDF 路径无效或文件已丢失。"
            return
        }
        studyNoteCoordinator.generate(work: work, pdfURL: pdfURL, modelContext: modelContext)
    }

    private func resumeStudyNote(_ record: StudyNoteGeneration) {
        guard let file = work.preferredFileVersion,
              let pdfURL = try? LibraryPathSafety.url(
                for: file.relativePath,
                inside: rootURL,
                requirePDF: true,
                requireExistingRegularFile: true
              )
        else {
            localError = "PDF 路径无效或文件已丢失。"
            return
        }
        studyNoteCoordinator.resume(
            work: work,
            record: record,
            pdfURL: pdfURL,
            modelContext: modelContext
        )
    }

    private func createOrOpenRegularNote() {
        guard let path = work.preferredFileVersion?.relativePath else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                let result = try await fileActor.createLiteratureNote(
                    forPDFAt: path,
                    title: work.title,
                    in: rootURL
                )
                if NSWorkspace.shared.open(result.url) {
                    work.lastOpenedAt = .now
                    saveInspectorChanges("记录笔记打开时间")
                } else {
                    localError = "笔记已准备好，但系统找不到可打开 Markdown 文件的应用。"
                }
            } catch {
                localError = "创建笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private func openOrOfferStudyNote() {
        guard let path = work.preferredFileVersion?.relativePath else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                if let url = try await fileActor.existingLiteratureNote(
                    forPDFAt: path,
                    kind: .study,
                    in: rootURL
                ) {
                    if NSWorkspace.shared.open(url) {
                        work.lastOpenedAt = .now
                        saveInspectorChanges("记录精读笔记打开时间")
                    } else {
                        localError = "精读笔记存在，但系统找不到可打开 Markdown 文件的应用。"
                    }
                } else if studyNoteCoordinator.isGenerating {
                    studyNoteCoordinator.isPresenting = true
                } else {
                    showingStudyNoteCreationOptions = true
                }
            } catch {
                localError = "打开精读笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private func createBlankStudyNote() {
        guard let path = work.preferredFileVersion?.relativePath else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                let result = try await fileActor.createLiteratureNote(
                    forPDFAt: path,
                    title: work.title,
                    kind: .study,
                    in: rootURL
                )
                if NSWorkspace.shared.open(result.url) {
                    work.lastOpenedAt = .now
                    saveInspectorChanges("记录精读笔记打开时间")
                } else {
                    localError = "精读笔记已准备好，但系统找不到可打开 Markdown 文件的应用。"
                }
            } catch {
                localError = "创建精读笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private func reprocess() {
        guard LocalAPIKeyStore.shared.readIfAvailable()?.isEmpty == false else {
            reprocessingCoordinator.errorText = "请先在设置中保存 Gemini API 密钥。"
            return
        }
        let defaults = UserDefaults.standard
        let budget = defaults.double(forKey: "monthlyAIBudgetUSD")
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        let spent = (try? modelContext.fetch(FetchDescriptor<AIAnalysis>()))?
            .filter { $0.createdAt >= monthStart }
            .reduce(0) { $0 + $1.estimatedCostUSD } ?? 0
        guard budget <= 0 || spent < budget else {
            reprocessingCoordinator.errorText = "本月 AI 费用预算已经用完，文献没有被重置。"
            return
        }
        guard let uncategorized = categories.first(where: { $0.isSystemCategory })
                ?? categories.first(where: { $0.name == "Uncategorized" })
        else {
            reprocessingCoordinator.errorText = "找不到系统未分类目录。"
            return
        }
        guard let preferredFile = work.preferredFileVersion else {
            reprocessingCoordinator.errorText = "这条文献没有可重新处理的 PDF。"
            return
        }
        let thresholdValue = defaults.integer(forKey: "longDocumentPageThreshold")
        let threshold = thresholdValue > 0 ? thresholdValue : 200
        let longDocumentPolicy = defaults.string(forKey: "longDocumentPolicy") ?? "excerpt"
        if preferredFile.pageCount > threshold, longDocumentPolicy == "skip" {
            reprocessingCoordinator.errorText = "这份文献超过长文档阈值，当前设置为不自动分析；文献没有被重置。"
            return
        }
        guard let pdfURL = try? LibraryPathSafety.url(
            for: preferredFile.relativePath,
            inside: rootURL,
            requirePDF: true,
            requireExistingRegularFile: true
        ) else {
            reprocessingCoordinator.errorText = "PDF 路径无效或文件已丢失。"
            return
        }
        let excerptValue = defaults.integer(forKey: "longDocumentExcerptPages")
        let excerptPages = max(1, excerptValue > 0 ? excerptValue : 60)
        aiCoordinator.analyze(
            work: work,
            pdfURL: pdfURL,
            pageCount: preferredFile.pageCount,
            mode: .extract,
            categories: categories,
            rootURL: rootURL,
            pageLimit: preferredFile.pageCount > threshold ? excerptPages : nil,
            resetBeforeApplying: uncategorized,
            modelContext: modelContext
        )
    }

    private func analysisStatus(_ rawValue: String) -> String {
        switch rawValue {
        case "queued": return "排队中"
        case "running": return "分析中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return rawValue
        }
    }

    private func analysisStatus(_ rawValue: String, for work: Work) -> String {
        let status = analysisStatus(rawValue)
        guard rawValue == "completed", WorkReviewRules.hasPageNumberWarning(work) else { return status }
        return "\(status)（\(WorkReviewRules.pageNumberWarning)）"
    }

    private func mergeWithCandidate() {
        guard !isUpdatingFileVersions else { return }
        guard let candidateID = work.duplicateCandidateWorkID,
              let candidate = try? modelContext.fetch(FetchDescriptor<Work>()).first(where: { $0.id == candidateID })
        else { return }
        guard let primaryVersion = candidate.preferredFileVersion ?? work.preferredFileVersion else {
            localError = "待合并文献没有可用的 PDF。"
            return
        }

        let removedWorkID = work.id
        isUpdatingFileVersions = true
        Task {
            defer { isUpdatingFileVersions = false }
            let sourceFiles = Array(work.fileVersions)
            let allFiles = Array(candidate.fileVersions) + sourceFiles
            let canUseStructuredFilename = ArchiveRules.canUseStructuredFilename(
                for: candidate,
                version: primaryVersion
            )
            let request = ArticleRelocationRequest(
                workID: candidate.id,
                files: allFiles.map { version in
                    ArticleFileRelocationRequest(
                        fileVersionID: version.id,
                        sourceRelativePath: version.relativePath,
                        preferredFilename: ArchiveRules.filename(
                        title: candidate.title,
                        authorsText: candidate.authorsText,
                        publicationYear: candidate.publicationYear,
                        metadataConfirmed: canUseStructuredFilename,
                        version: version,
                        includeVersionSuffix: allFiles.count > 1 && version.id != primaryVersion.id
                        )
                    )
                },
                categoryFolder: ArchiveRules.categoryFolderName(candidate.primaryCategory?.name),
                yearFolder: ArchiveRules.yearFolderName(candidate.publicationYear),
                preferredFolderName: ArchiveRules.articleFolderName(for: candidate)
            )
            do {
                let batch = try await fileActor.relocateArticles([request], in: rootURL)
                let paths = Dictionary(uniqueKeysWithValues: batch.fileDestinations.map {
                    ($0.fileVersionID, $0.destinationRelativePath)
                })
                let sourcePreferredID = work.preferredFileVersion?.id
                work.fileVersions.removeAll()
                for file in sourceFiles {
                    file.relativePath = paths[file.id] ?? file.relativePath
                    file.isPreferred = file.id == primaryVersion.id
                    candidate.fileVersions.append(file)
                }
                for file in candidate.fileVersions where paths[file.id] != nil {
                    file.relativePath = paths[file.id]!
                    file.isPreferred = file.id == primaryVersion.id
                }
                let analyses = Array(work.analyses)
                work.analyses.removeAll()
                for analysis in analyses {
                    if analysis.analyzedFileVersionID == nil {
                        analysis.analyzedFileVersionID = sourcePreferredID
                    }
                    candidate.analyses.append(analysis)
                }
                let studyNotes = Array(work.studyNoteGenerations)
                work.studyNoteGenerations.removeAll()
                for note in studyNotes { candidate.studyNoteGenerations.append(note) }
                for tag in work.tags where !candidate.tags.contains(where: { $0.id == tag.id }) {
                    candidate.tags.append(tag)
                }
                for project in work.projects {
                    let sourcePriority = project.priority(for: work.id)
                    let candidatePriority = project.priority(for: candidate.id)
                    if !candidate.projects.contains(where: { $0.id == project.id }) {
                        candidate.projects.append(project)
                    }
                    project.setPriority(
                        ProjectWorkPriority.merged(sourcePriority, candidatePriority),
                        for: candidate.id
                    )
                    project.setPriority(.none, for: work.id)
                }
                if candidate.doi == nil { candidate.doi = work.doi }
                if candidate.publicationYear == nil { candidate.publicationYear = work.publicationYear }
                candidate.needsReview = false
                candidate.duplicateCandidateWorkID = nil
                let allWorks = try modelContext.fetch(FetchDescriptor<Work>())
                for other in allWorks where other.duplicateCandidateWorkID == work.id {
                    other.duplicateCandidateWorkID = candidate.id
                }
                modelContext.delete(work)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    try await fileActor.rollbackArticleRelocations(batch, in: rootURL)
                    throw error
                }
                DeletedWorkRegistry.record(removedWorkID)
                await searchCoordinator.removeDocuments(workIDs: [removedWorkID])
                do {
                    try await fileActor.commitArticleRelocations(batch, in: rootURL)
                } catch {
                    localError = "文献已合并，事务记录将在下次启动时清理。"
                }
            } catch {
                localError = "合并文献失败：\(error.localizedDescription)"
            }
        }
    }

    private func splitVersion(_ file: FileVersion) {
        guard !isUpdatingFileVersions else { return }
        guard !file.isPreferred else {
            localError = "请先把另一个版本设为主要版本，再拆分当前版本。"
            return
        }
        guard work.fileVersions.count > 1,
              let uncategorized = categories.first(where: { $0.isSystemCategory })
                ?? categories.first(where: { $0.name == "Uncategorized" })
        else { return }
        isUpdatingFileVersions = true
        Task {
            defer { isUpdatingFileVersions = false }
            let request = FileRelocationRequest(
                fileVersionID: file.id,
                sourceRelativePath: file.relativePath,
                categoryFolder: ArchiveRules.categoryFolderName(uncategorized.name),
                yearFolder: "Unknown Year",
                preferredFilename: file.originalFilename,
                articleFolderName: URL(fileURLWithPath: file.originalFilename)
                    .deletingPathExtension()
                    .lastPathComponent
            )
            do {
                let batch = try await fileActor.relocateFiles([request], in: rootURL)
                guard let newPath = batch.relocations.first?.destinationRelativePath else {
                    throw CocoaError(.fileNoSuchFile)
                }
                work.fileVersions.removeAll { $0.id == file.id }
                if !work.fileVersions.contains(where: \.isPreferred) {
                    work.fileVersions.first?.isPreferred = true
                }
                file.relativePath = newPath
                file.isPreferred = true
                let versionTitle = file.bibliographicTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = (versionTitle?.isEmpty == false ? versionTitle : nil)
                    ?? URL(fileURLWithPath: file.originalFilename).deletingPathExtension().lastPathComponent
                let versionMetadataConfirmed = file.bibliographicMetadataConfirmed
                let documentType: String?
                switch file.versionTypeRawValue {
                case "published", "acceptedManuscript", "preprint": documentType = "article"
                case "workingPaper": documentType = "workingPaper"
                default: documentType = nil
                }
                let newWork = Work(
                    title: resolvedTitle,
                    authorsText: file.bibliographicAuthorsText ?? "",
                    publicationYear: file.bibliographicYear,
                    journal: file.bibliographicJournal,
                    doi: file.bibliographicDOI,
                    documentTypeRawValue: documentType,
                    metadataConfirmed: versionMetadataConfirmed,
                    needsReview: !versionMetadataConfirmed,
                    metadataSource: file.bibliographicMetadataSource ?? "pendingAI",
                    metadataConflictNote: versionMetadataConfirmed
                        ? nil
                        : "这个文件版本已拆分为独立文献，请重新处理以确认书目信息。",
                    primaryCategory: uncategorized,
                    tags: work.tags,
                    projects: work.projects
                )
                newWork.fileVersions.append(file)
                modelContext.insert(newWork)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    try await fileActor.rollbackRelocations(batch, in: rootURL)
                    throw error
                }
                do {
                    try await fileActor.commitRelocations(batch, in: rootURL)
                } catch {
                    localError = "文件版本已拆分，事务记录将在下次启动时清理。"
                }
                do {
                    try await ArchiveMaintenance.normalizeStructuredFilenames(
                        works: [work, newWork],
                        rootURL: rootURL,
                        modelContext: modelContext
                    )
                } catch {
                    localError = "文件版本已拆分，但后续文件名整理失败：\(error.localizedDescription)"
                }
            } catch {
                localError = "拆分文件版本失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct AnalysisCardView: View {
    let analysis: PaperAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let documentType = analysis.documentType {
                field("文献类型", localizedDocumentType(documentType))
            }
            if let isbn = analysis.bibliographicISBN {
                field("ISBN", isbn)
            }
            if let publisher = analysis.bibliographicPublisher {
                field("出版社", publisher)
            }
            field("一句话摘要", analysis.oneSentenceSummary)
            field("研究问题", analysis.researchQuestion)
            field("研究类型", analysis.paperType)
            field("数据来源", analysis.dataSources)
            field("样本", analysis.sample)
            field("识别策略", analysis.identificationStrategy)
            field("识别假设", analysis.identificationAssumptions)
            field("主要结果", analysis.mainResults)
            field("机制", analysis.mechanisms)
            field("异质性", analysis.heterogeneity)
            field("稳健性", analysis.robustness)
            field("局限", analysis.limitations)
            if !analysis.suggestedTags.isEmpty {
                LabeledContent("建议标签", value: analysis.suggestedTags.joined(separator: "、"))
            }
            if !analysis.suggestedCategory.isEmpty {
                LabeledContent("建议分类", value: analysis.suggestedCategory)
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ field: AnalysisField) -> some View {
        if field.status != "unknown", !field.value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(field.value)
                if !field.pages.isEmpty {
                    Text("PDF 页码：\(field.pages.map(String.init).joined(separator: "、")) · 置信度：\(field.confidence, format: .percent.precision(.fractionLength(0)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func localizedDocumentType(_ field: AnalysisField) -> AnalysisField {
        let value: String
        switch field.value {
        case "article": value = "期刊论文"
        case "workingPaper": value = "工作论文"
        case "book": value = "书籍"
        case "bookChapter": value = "书籍章节"
        case "report": value = "研究报告"
        case "thesis": value = "学位论文"
        case "other": value = "其他"
        default: value = field.value
        }
        return AnalysisField(
            value: value,
            status: field.status,
            confidence: field.confidence,
            pages: field.pages,
            evidence: field.evidence
        )
    }
}
