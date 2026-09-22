import Foundation
import SwiftData

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var sortOrder: Int
    var colorHex: String
    var isSystemCategory: Bool

    @Relationship(deleteRule: .nullify, inverse: \Work.primaryCategory)
    var works: [Work]

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        colorHex: String = "#808080",
        isSystemCategory: Bool = false,
        works: [Work] = []
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorHex = colorHex
        self.isSystemCategory = isSystemCategory
        self.works = works
    }
}
