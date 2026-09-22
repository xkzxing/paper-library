import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkRow: View {
    let work: Work
    let isSelected: Bool
    let projectPriority: ProjectWorkPriority?
    let searchMatch: SearchWorkMatch?

    private var requiresReview: Bool {
        WorkReviewRules.requiresReview(work)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 5) {
                Image(systemName: requiresReview ? "exclamationmark.triangle.fill" : "doc.text")
                    .foregroundStyle(requiresReview ? .orange : .red)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                if let projectPriority, projectPriority != .none {
                    Text(projectPriority.marker)
                        .font(.system(size: 16))
                        .accessibilityLabel(projectPriority.title)
                }
            }
            .frame(width: 32, alignment: .top)
            VStack(alignment: .leading, spacing: 7) {
                Text(work.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(work.authorsText.isEmpty ? "未知作者" : work.authorsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let searchMatch {
                    Label(searchMatch.reason, systemImage: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(
                            !searchMatch.passages.isEmpty && searchMatch.passages.allSatisfy {
                                $0.relevance == .marginal
                            } ? Color.orange : Color.accentColor
                        )
                        .lineLimit(1)
                    if let passage = searchMatch.primaryPassage {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(passage.pageDescription)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(passage.snippet)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if searchMatch.passages.count > 1 {
                        let additionalPassage = searchMatch.passages[1]
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("另有 1 处")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(additionalPassage.pageDescription)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(additionalPassage.snippet)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 6) {
                    RowBadge(work.publicationYear.map(String.init) ?? "年份未知", systemImage: "calendar")
                    if let category = work.primaryCategory {
                        RowBadge(category.name, systemImage: "folder")
                    }
                    if let value = work.openAlexJournalMetrics?.twoYearMeanCitedness {
                        RowBadge(
                            "OpenAlex \(value.formatted(.number.precision(.fractionLength(2))))",
                            systemImage: "chart.bar.xaxis",
                            tint: .teal
                        )
                    }
                    if work.crossrefChecked {
                        RowBadge("Crossref", systemImage: "checkmark.seal.fill", tint: .blue)
                    }
                    if work.fileVersions.count > 1 {
                        RowBadge("\(work.fileVersions.count) 个版本", systemImage: "doc.on.doc")
                    }
                    if let lastOpenedAt = work.lastOpenedAt {
                        RowBadge(
                            "上次 \(lastOpenedAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
                .lineLimit(1)

                if !work.tags.isEmpty || !work.personalMarks.isEmpty {
                    HStack(spacing: 5) {
                        let marks = work.personalMarks.sorted { $0.sortOrder < $1.sortOrder }
                        let normalTags = work.tags.sorted { $0.name < $1.name }
                        ForEach(Array(marks.prefix(3))) { mark in
                            Text(mark.name)
                                .font(.caption2)
                                .foregroundStyle(Color(hex: mark.colorHex))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color(hex: mark.effectiveBackgroundColorHex),
                                    in: Capsule()
                                )
                        }
                        ForEach(Array(normalTags.prefix(max(0, 3 - marks.count)))) { tag in
                            Text(tag.name)
                                .font(.caption2)
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.indigo.opacity(0.09), in: Capsule())
                        }
                        if marks.count + normalTags.count > 3 {
                            Text("+\(marks.count + normalTags.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("已选择")
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.05 : 0.025), radius: 4, y: 1)
    }
}

private struct RowBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.08), in: Capsule())
    }
}

enum AIAnalysisStateRules {
    static func latestStatus(for work: Work) -> String? {
        work.analyses.max(by: { $0.createdAt < $1.createdAt })?.status
    }

    static func isLatestStatus(_ work: Work, oneOf statuses: Set<String>) -> Bool {
        guard let status = latestStatus(for: work) else { return false }
        return statuses.contains(status)
    }
}

struct WorkRowDragPayload: Codable {
    let workID: UUID
}

enum WorkRowDragProvider {
    static let typeIdentifier = "com.paperlibrary.work-row"

    static func make(workID: UUID, pdfURL: URL?) -> NSItemProvider {
        let provider = pdfURL.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let payload = WorkRowDragPayload(workID: workID)
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .all
        ) { completion in
            completion(try? JSONEncoder().encode(payload), nil)
            return nil
        }
        if let pdfURL {
            provider.suggestedName = PDFDragExportRules.suggestedFilenameBase(for: pdfURL)
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.pdf.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(pdfURL, true, nil)
                return nil
            }
        }
        return provider
    }
}

enum LibraryFileDropRules {
    static func externalURLProviders(from providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
                !$0.hasItemConformingToTypeIdentifier(WorkRowDragProvider.typeIdentifier)
        }
    }
}

extension NSItemProvider {
    @MainActor
    func loadDroppedURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }
}

enum PDFDragExportRules {
    static func suggestedFilenameBase(for pdfURL: URL) -> String {
        pdfURL.deletingPathExtension().lastPathComponent
    }
}

enum WorkSelectionRules {
    static func selection(
        afterClicking id: UUID,
        current: Set<UUID>,
        commandModified: Bool
    ) -> Set<UUID> {
        guard commandModified else { return [id] }
        var result = current
        if result.contains(id) {
            result.remove(id)
        } else {
            result.insert(id)
        }
        return result
    }
}
