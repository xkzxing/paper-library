import Foundation

enum BatchBibTeXExportMode: String, Identifiable, Sendable {
    case local
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "使用资料库记录"
        case .online: return "在线核验"
        }
    }
}

struct BatchBibTeXInput: Identifiable, Sendable, Equatable {
    let id: UUID
    let workTitle: String
    let metadata: BibliographicSnapshot
    let localEntry: BibTeXEntry?
    let localFailureReason: String?
}

struct BatchBibTeXRemoteOutcome: Sendable, Equatable {
    let workID: UUID
    let record: RemoteBibTeXRecord?
    let failureReason: String?
}

struct BatchBibTeXCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let workTitle: String
    let localEntry: BibTeXEntry?
    let onlineEntry: BibTeXEntry?
    let onlineSourceName: String?
    let differences: [BibTeXDifference]
    let usedLocalFallback: Bool

    var requiresChoice: Bool {
        localEntry != nil && onlineEntry != nil && !differences.isEmpty
    }

    var defaultEntry: BibTeXEntry? { onlineEntry ?? localEntry }
}

struct BatchBibTeXSkippedItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let workTitle: String
    let reason: String
}

struct BatchBibTeXPreparation: Sendable, Equatable {
    let candidates: [BatchBibTeXCandidate]
    let skipped: [BatchBibTeXSkippedItem]

    var conflictCount: Int { candidates.filter(\.requiresChoice).count }
    var fallbackCount: Int { candidates.filter(\.usedLocalFallback).count }
}

struct BatchBibTeXChosenEntry: Sendable, Equatable {
    let workID: UUID
    let workTitle: String
    let entry: BibTeXEntry
}

enum BatchBibTeXDocumentError: LocalizedError, Equatable {
    case invalidEntry(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEntry(title):
            return "“\(title)”的 BibTeX 内容无法合并。"
        }
    }
}

enum BatchBibTeXExporter {
    static func prepareLocal(_ inputs: [BatchBibTeXInput]) -> BatchBibTeXPreparation {
        var candidates: [BatchBibTeXCandidate] = []
        var skipped: [BatchBibTeXSkippedItem] = []
        for input in inputs {
            if let entry = input.localEntry {
                candidates.append(BatchBibTeXCandidate(
                    id: input.id,
                    workTitle: input.workTitle,
                    localEntry: entry,
                    onlineEntry: nil,
                    onlineSourceName: nil,
                    differences: [],
                    usedLocalFallback: false
                ))
            } else {
                skipped.append(BatchBibTeXSkippedItem(
                    id: input.id,
                    workTitle: input.workTitle,
                    reason: input.localFailureReason ?? "资料库记录不完整。"
                ))
            }
        }
        return BatchBibTeXPreparation(candidates: candidates, skipped: skipped)
    }

    static func prepareOnline(
        _ inputs: [BatchBibTeXInput],
        outcomes: [BatchBibTeXRemoteOutcome]
    ) -> BatchBibTeXPreparation {
        let outcomeByID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.workID, $0) })
        var candidates: [BatchBibTeXCandidate] = []
        var skipped: [BatchBibTeXSkippedItem] = []

        for input in inputs {
            let outcome = outcomeByID[input.id]
            if let online = outcome?.record {
                let differences = BibTeXComparisonRules.differences(
                    local: input.metadata,
                    online: online.metadata
                )
                candidates.append(BatchBibTeXCandidate(
                    id: input.id,
                    workTitle: input.workTitle,
                    localEntry: input.localEntry,
                    onlineEntry: online.entry,
                    onlineSourceName: online.sourceName,
                    differences: differences,
                    usedLocalFallback: false
                ))
            } else if let local = input.localEntry {
                candidates.append(BatchBibTeXCandidate(
                    id: input.id,
                    workTitle: input.workTitle,
                    localEntry: local,
                    onlineEntry: nil,
                    onlineSourceName: nil,
                    differences: [],
                    usedLocalFallback: true
                ))
            } else {
                let reasons = [outcome?.failureReason, input.localFailureReason]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                skipped.append(BatchBibTeXSkippedItem(
                    id: input.id,
                    workTitle: input.workTitle,
                    reason: reasons.isEmpty ? "本地和在线记录均不可用。" : reasons.joined(separator: "；")
                ))
            }
        }
        return BatchBibTeXPreparation(candidates: candidates, skipped: skipped)
    }

    static func makeDocument(from chosen: [BatchBibTeXChosenEntry]) throws -> String {
        let keyCounts = Dictionary(grouping: chosen, by: { $0.entry.citationKey.lowercased() })
            .mapValues(\.count)
        var keyOffsets: [String: Int] = [:]
        var usedKeys: Set<String> = []
        var contents: [String] = []

        for item in chosen {
            let normalizedKey = item.entry.citationKey.lowercased()
            var entry = item.entry
            var newKey = item.entry.citationKey
            if keyCounts[normalizedKey, default: 0] > 1 {
                var offset = keyOffsets[normalizedKey, default: 0]
                repeat {
                    newKey = item.entry.citationKey + citationSuffix(for: offset)
                    offset += 1
                } while usedKeys.contains(newKey.lowercased())
                keyOffsets[normalizedKey] = offset
            } else if usedKeys.contains(normalizedKey) {
                var offset = 0
                repeat {
                    newKey = item.entry.citationKey + citationSuffix(for: offset)
                    offset += 1
                } while usedKeys.contains(newKey.lowercased())
            }

            if newKey != item.entry.citationKey {
                do {
                    let parsed = try BibTeXRecordParser.parse(item.entry.content)
                    entry = BibTeXEntry(
                        citationKey: newKey,
                        content: BibTeXRecordParser.replacingCitationKey(
                            in: item.entry.content,
                            parsed: parsed,
                            with: newKey
                        )
                    )
                } catch {
                    throw BatchBibTeXDocumentError.invalidEntry(item.workTitle)
                }
            }
            usedKeys.insert(entry.citationKey.lowercased())
            contents.append(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !contents.isEmpty else { return "" }
        return contents.joined(separator: "\n\n") + "\n"
    }

    private static func citationSuffix(for offset: Int) -> String {
        var value = offset
        var result = ""
        repeat {
            let scalar = UnicodeScalar(97 + value % 26)!
            result.insert(Character(scalar), at: result.startIndex)
            value = value / 26 - 1
        } while value >= 0
        return result
    }
}
