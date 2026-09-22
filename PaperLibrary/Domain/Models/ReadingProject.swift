import Foundation
import SwiftData

enum ProjectWorkPriority: Int, CaseIterable, Codable, Identifiable {
    case none = 0
    case one = 1
    case two = 2
    case three = 3
    case completed = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "无优先级"
        case .one: return "一级：❗️"
        case .two: return "二级：‼️"
        case .three: return "三级：🚩"
        case .completed: return "已读：✅"
        }
    }

    var marker: String {
        switch self {
        case .none: return ""
        case .one: return "❗️"
        case .two: return "‼️"
        case .three: return "🚩"
        case .completed: return "✅"
        }
    }

    /// 优先级从高到低排列，已读文献始终放在最后。
    var sortRank: Int {
        self == .completed ? -1 : rawValue
    }

    static let menuOrder: [ProjectWorkPriority] = [
        .three, .two, .one, .none, .completed
    ]

    static func merged(_ left: ProjectWorkPriority, _ right: ProjectWorkPriority) -> ProjectWorkPriority {
        if left == .completed || right == .completed { return .completed }
        return left.sortRank >= right.sortRank ? left : right
    }
}

/// A virtual collection of works. Project membership never changes a PDF's location.
@Model
final class ReadingProject {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var dateCreated: Date
    var priorityData: Data?
    var sortFieldRawValue: String?
    var sortDirectionRawValue: String?

    @Relationship(deleteRule: .nullify, inverse: \Work.projects)
    var works: [Work]

    init(
        id: UUID = UUID(),
        name: String,
        dateCreated: Date = .now,
        priorityData: Data? = nil,
        sortFieldRawValue: String? = nil,
        sortDirectionRawValue: String? = nil,
        works: [Work] = []
    ) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.priorityData = priorityData
        self.sortFieldRawValue = sortFieldRawValue
        self.sortDirectionRawValue = sortDirectionRawValue
        self.works = works
    }

    func priority(for workID: UUID) -> ProjectWorkPriority {
        ProjectWorkPriority(rawValue: priorityValues[workID.uuidString] ?? 0) ?? .none
    }

    func setPriority(_ priority: ProjectWorkPriority, for workID: UUID) {
        var values = priorityValues
        if priority == .none {
            values.removeValue(forKey: workID.uuidString)
        } else {
            values[workID.uuidString] = priority.rawValue
        }
        priorityData = try? JSONEncoder().encode(values)
    }

    var priorityValues: [String: Int] {
        guard let priorityData else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: priorityData)) ?? [:]
    }

    func restorePriorityValues(_ values: [String: Int]) {
        let validValues = values.filter {
            ProjectWorkPriority(rawValue: $0.value) != nil && $0.value != 0
        }
        priorityData = try? JSONEncoder().encode(validValues)
    }
}
