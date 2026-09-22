import Foundation

enum BatchTagRules {
    static func add(_ tags: [Tag], to works: [Work]) {
        for work in works {
            for tag in tags where !work.tags.contains(where: { $0.id == tag.id }) {
                work.tags.append(tag)
            }
        }
    }

    static func remove(_ tags: [Tag], from works: [Work]) {
        let ids = Set(tags.map(\.id))
        for work in works {
            work.tags.removeAll { ids.contains($0.id) }
        }
    }
}

enum BatchReviewRules {
    struct Result: Equatable {
        let marked: Int
        let skipped: Int
    }

    static func canMarkReviewed(_ work: Work) -> Bool {
        guard work.duplicateCandidateWorkID == nil else { return false }
        guard !AIAnalysisStateRules.isLatestStatus(
            work,
            oneOf: ["queued", "running", "failed"]
        ) else { return false }
        guard work.metadataConflictNote?.hasPrefix("找不到资料库中的 PDF 文件") != true else {
            return false
        }
        return true
    }

    static func markReviewed(_ works: [Work]) -> Result {
        var marked = 0
        var skipped = 0
        for work in works {
            guard canMarkReviewed(work) else {
                skipped += 1
                continue
            }
            work.needsReview = false
            work.metadataConflictNote = nil
            marked += 1
        }
        return Result(marked: marked, skipped: skipped)
    }
}
