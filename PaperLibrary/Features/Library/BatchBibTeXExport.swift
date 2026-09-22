import Foundation
import SwiftUI

@MainActor
final class BatchBibTeXCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var statusText: String?
    @Published var errorText: String?

    private let remoteFetcher: any BibTeXRemoteFetching
    private var task: Task<Void, Never>?

    init(remoteFetcher: any BibTeXRemoteFetching = BibTeXRemoteClient()) {
        self.remoteFetcher = remoteFetcher
    }

    func startOnlinePreparation(
        inputs: [BatchBibTeXInput],
        contactEmail: String?,
        completion: @escaping @MainActor (BatchBibTeXPreparation) -> Void
    ) {
        guard !isWorking, !inputs.isEmpty else { return }
        isWorking = true
        completedCount = 0
        totalCount = inputs.count
        statusText = "正在在线核验 0/\(inputs.count)"
        errorText = nil
        let fetcher = remoteFetcher

        task = Task { [weak self] in
            var outcomes: [BatchBibTeXRemoteOutcome] = []
            var start = 0
            while start < inputs.count {
                guard !Task.isCancelled else {
                    self?.finishCancelled()
                    return
                }
                let end = min(start + 3, inputs.count)
                let batch = Array(inputs[start..<end])
                let results = await withTaskGroup(of: BatchBibTeXRemoteOutcome.self) { group in
                    for input in batch {
                        group.addTask {
                            do {
                                let record = try await fetcher.fetch(
                                    for: input.metadata,
                                    contactEmail: contactEmail
                                )
                                return BatchBibTeXRemoteOutcome(
                                    workID: input.id,
                                    record: record,
                                    failureReason: nil
                                )
                            } catch is CancellationError {
                                return BatchBibTeXRemoteOutcome(
                                    workID: input.id,
                                    record: nil,
                                    failureReason: "已取消在线核验。"
                                )
                            } catch {
                                return BatchBibTeXRemoteOutcome(
                                    workID: input.id,
                                    record: nil,
                                    failureReason: error.localizedDescription
                                )
                            }
                        }
                    }
                    var values: [BatchBibTeXRemoteOutcome] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard !Task.isCancelled else {
                    self?.finishCancelled()
                    return
                }
                outcomes.append(contentsOf: results)
                start = end
                self?.completedCount = end
                self?.statusText = "正在在线核验 \(end)/\(inputs.count)"
            }

            guard let self, !Task.isCancelled else { return }
            let preparation = BatchBibTeXExporter.prepareOnline(inputs, outcomes: outcomes)
            isWorking = false
            statusText = nil
            task = nil
            completion(preparation)
        }
    }

    func cancel() {
        task?.cancel()
        finishCancelled()
    }

    private func finishCancelled() {
        task = nil
        isWorking = false
        statusText = "已取消批量 BibTeX 核验。"
    }
}

enum BatchBibTeXSourceChoice: String, CaseIterable, Identifiable {
    case online
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .online: return "在线记录"
        case .local: return "资料库记录"
        }
    }
}

struct BatchBibTeXReviewSheet: View {
    let preparation: BatchBibTeXPreparation
    let onCancel: () -> Void
    let onExport: ([BatchBibTeXChosenEntry]) -> Void
    @State private var choices: [UUID: BatchBibTeXSourceChoice]

    init(
        preparation: BatchBibTeXPreparation,
        onCancel: @escaping () -> Void,
        onExport: @escaping ([BatchBibTeXChosenEntry]) -> Void
    ) {
        self.preparation = preparation
        self.onCancel = onCancel
        self.onExport = onExport
        _choices = State(initialValue: Dictionary(
            uniqueKeysWithValues: preparation.candidates
                .filter(\.requiresChoice)
                .map { ($0.id, .online) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("集中核对 BibTeX").font(.title2)
            Text("发现 \(preparation.conflictCount) 篇在线记录与资料库不一致。默认使用在线记录，可以逐篇更改。")
                .foregroundStyle(.secondary)

            List(preparation.candidates.filter(\.requiresChoice)) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.workTitle).font(.headline).lineLimit(2)
                    Picker("导出来源", selection: choiceBinding(for: candidate.id)) {
                        ForEach(BatchBibTeXSourceChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(candidate.differences) { difference in
                            GridRow(alignment: .top) {
                                Text(difference.field).foregroundStyle(.secondary)
                                Text(difference.localValue).lineLimit(2)
                                Text(difference.onlineValue).lineLimit(2)
                            }
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 6)
            }

            HStack {
                if !preparation.skipped.isEmpty {
                    Text("将跳过 \(preparation.skipped.count) 篇不可导出的文献。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                Button("继续导出") { onExport(chosenEntries) }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenEntries.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 780, minHeight: 520)
    }

    private var chosenEntries: [BatchBibTeXChosenEntry] {
        preparation.candidates.compactMap { candidate in
            let choice = choices[candidate.id] ?? .online
            let entry = choice == .local
                ? candidate.localEntry
                : candidate.onlineEntry ?? candidate.localEntry
            guard let entry else { return nil }
            return BatchBibTeXChosenEntry(
                workID: candidate.id,
                workTitle: candidate.workTitle,
                entry: entry
            )
        }
    }

    private func choiceBinding(for id: UUID) -> Binding<BatchBibTeXSourceChoice> {
        Binding(
            get: { choices[id] ?? .online },
            set: { choices[id] = $0 }
        )
    }
}

struct BatchBibTeXExportSummary: Identifiable {
    let id = UUID()
    let exportedCount: Int
    let fallbackCount: Int
    let skipped: [BatchBibTeXSkippedItem]
    let filename: String
}

struct BatchBibTeXSummarySheet: View {
    let summary: BatchBibTeXExportSummary
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BibTeX 导出完成").font(.title2)
            if summary.exportedCount > 0 {
                Text("已将 \(summary.exportedCount) 篇文献导出到“\(summary.filename)”。")
            } else {
                Text("没有可导出的文献，未创建文件。")
            }
            if summary.fallbackCount > 0 {
                Text("其中 \(summary.fallbackCount) 篇因在线核验失败而使用资料库记录。")
                    .foregroundStyle(.secondary)
            }
            if !summary.skipped.isEmpty {
                Text("已跳过 \(summary.skipped.count) 篇：").font(.headline)
                List(summary.skipped) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.workTitle)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 150)
            }
            HStack {
                Spacer()
                Button("关闭", action: onClose).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: summary.skipped.isEmpty ? 220 : 380)
    }
}
