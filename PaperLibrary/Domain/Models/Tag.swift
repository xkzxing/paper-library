import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var colorHex: String

    var works: [Work]

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#808080",
        works: [Work] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.works = works
    }
}

/// 用户手动维护的阅读标记。它与 AI 关键词完全独立，因此允许名称相同。
@Model
final class PersonalMark {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    /// 文字颜色。保留原字段名以兼容已有资料库。
    var colorHex: String
    /// 旧资料库没有此字段时使用柔和的默认底色。
    var backgroundColorHex: String?
    var sortOrder: Int

    var works: [Work]

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#B65C75",
        backgroundColorHex: String? = "#FCE4EC",
        sortOrder: Int = 0,
        works: [Work] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.backgroundColorHex = backgroundColorHex
        self.sortOrder = sortOrder
        self.works = works
    }

    var effectiveBackgroundColorHex: String {
        backgroundColorHex ?? "#FCE4EC"
    }
}
