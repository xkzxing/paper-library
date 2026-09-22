import SwiftUI

struct StudyNoteProgressView: View {
    @ObservedObject var coordinator: StudyNoteCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("生成精读笔记").font(.title2.bold())
            if coordinator.isGenerating {
                ProgressView()
                Text(coordinator.statusText ?? "正在准备…")
                if coordinator.totalParts > 0 {
                    Text("已完成 \(coordinator.completedParts) / \(coordinator.totalParts) 部分")
                        .foregroundStyle(.secondary)
                }
                if let cacheStatus = coordinator.cacheStatusText {
                    Text(cacheStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if coordinator.cachedInputTokens > 0 {
                    Text("已复用缓存输入 \(coordinator.cachedInputTokens.formatted()) 个令牌")
                        .foregroundStyle(.secondary)
                }
                if coordinator.estimatedCostUSD > 0 {
                    Text("当前估算费用：\(coordinator.estimatedCostUSD, format: .currency(code: "USD"))")
                        .foregroundStyle(.secondary)
                }
            } else if let status = coordinator.statusText {
                Text(status).foregroundStyle(.secondary)
            }

            if !coordinator.previewText.isEmpty {
                Divider()
                Text("已完成章节预览").font(.headline)
                ScrollView {
                    Text(coordinator.previewText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 360)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = coordinator.errorText {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                if coordinator.isGenerating {
                    Button("取消", role: .destructive) { coordinator.cancel() }
                }
                Spacer()
                if coordinator.downloadedURL != nil {
                    Button("打开") { coordinator.openDownload() }
                    Button("在 Finder 中显示") { coordinator.revealDownload() }
                }
                Button(coordinator.isGenerating ? "隐藏（处理会继续）" : "关闭") {
                    coordinator.isPresenting = false
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(coordinator.isGenerating)
    }
}

struct PreferredVersionSelectionSheet: View {
    let version: FileVersion
    let fallbackTitle: String
    let fallbackAuthorsText: String
    let fallbackYear: Int?
    let fallbackJournal: String?
    let fallbackDOI: String?
    let onConfirm: (String, String, Int?, String?, String?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var authorsText: String
    @State private var yearText: String
    @State private var journal: String
    @State private var doi: String

    init(
        version: FileVersion,
        fallbackTitle: String,
        fallbackAuthorsText: String,
        fallbackYear: Int?,
        fallbackJournal: String?,
        fallbackDOI: String?,
        onConfirm: @escaping (String, String, Int?, String?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.version = version
        self.fallbackTitle = fallbackTitle
        self.fallbackAuthorsText = fallbackAuthorsText
        self.fallbackYear = fallbackYear
        self.fallbackJournal = fallbackJournal
        self.fallbackDOI = fallbackDOI
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _title = State(initialValue: version.bibliographicTitle ?? fallbackTitle)
        _authorsText = State(initialValue: version.bibliographicAuthorsText ?? fallbackAuthorsText)
        _yearText = State(initialValue: (version.bibliographicYear ?? fallbackYear).map(String.init) ?? "")
        _journal = State(initialValue: version.bibliographicJournal ?? fallbackJournal ?? "")
        _doi = State(initialValue: version.bibliographicDOI ?? fallbackDOI ?? "")
    }

    private var parsedYear: Int? {
        let value = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Int(value)
    }

    private var yearIsValid: Bool {
        let value = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        guard let year = Int(value) else { return false }
        return (1900...(Calendar.current.component(.year, from: .now) + 1)).contains(year)
    }

    private var journalValue: String? {
        let value = journal.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置主要版本")
                .font(.title2)
            Text("确认主要版本采用的书目信息。文章文件夹、受管理的 PDF、笔记和资源文件会在保存时一起整理。")
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("文件", value: version.originalFilename)
                LabeledContent("版本类型", value: localizedVersionType(version.versionTypeRawValue))
                TextField("标题", text: $title, axis: .vertical)
                TextField("作者", text: $authorsText)
                TextField("年份", text: $yearText)
                TextField("期刊", text: $journal)
                TextField("DOI", text: $doi)
                if !yearIsValid {
                    Label("年份应为 1900 年至明年之间的整数。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Text("现有研究卡不会自动重新生成；如它基于旧版本，详情页会提示你重新分析。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("设为主要版本") {
                    onConfirm(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        authorsText.trimmingCharacters(in: .whitespacesAndNewlines),
                        parsedYear,
                        journalValue,
                        PDFMetadataExtractor.normalizedDOI(doi)
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !yearIsValid)
            }
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled()
    }

    private func localizedVersionType(_ rawValue: String) -> String {
        switch rawValue {
        case "published": return "正式发表版"
        case "workingPaper": return "工作论文"
        case "acceptedManuscript": return "录用稿"
        case "preprint": return "预印本"
        case "supplement": return "补充材料"
        case "annotatedCopy": return "带标注副本"
        default: return "未知"
        }
    }
}
