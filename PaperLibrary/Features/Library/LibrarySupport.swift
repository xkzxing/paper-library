import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Swift 5 的完整并发检查尚未给不可变 KeyPath 提供 Sendable 一致性，
// 导致 SwiftData 的 #Predicate 宏在严格检查下产生误报。KeyPath 本身不可变，
// 可安全跨并发边界；待标准库提供原生一致性后可移除此兼容声明。
extension KeyPath: @retroactive @unchecked Sendable {}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(value, radix: 16) ?? 0x808080
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(
            format: "#%02X%02X%02X",
            Int((resolved.redComponent * 255).rounded()),
            Int((resolved.greenComponent * 255).rounded()),
            Int((resolved.blueComponent * 255).rounded())
        )
    }
}

enum DeletedWorkRegistry {
    private static let key = "deletedWorkIDs"

    static func record(_ id: UUID) {
        var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        values.insert(id.uuidString)
        UserDefaults.standard.set(Array(values), forKey: key)
    }

    static func contains(_ id: UUID) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static var all: [UUID] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func record(_ ids: [UUID]) {
        var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        values.formUnion(ids.map(\.uuidString))
        UserDefaults.standard.set(Array(values), forKey: key)
    }
}

enum SidebarSelection: Hashable {
    case all
    case needsReview
    case possibleDuplicates
    case aiQueue
    case recent
    case multipleVersions
    case missingDOI
    case unanalyzed
    case category(UUID)
    case project(UUID)

    var persistenceValue: String {
        switch self {
        case .all: return "all"
        case .needsReview: return "needsReview"
        case .possibleDuplicates: return "possibleDuplicates"
        case .aiQueue: return "aiQueue"
        case .recent: return "recent"
        case .multipleVersions: return "multipleVersions"
        case .missingDOI: return "missingDOI"
        case .unanalyzed: return "unanalyzed"
        case let .category(id): return "category:\(id.uuidString)"
        case let .project(id): return "project:\(id.uuidString)"
        }
    }

    static func fromPersistenceValue(_ value: String) -> Self? {
        switch value {
        case "all": return .all
        case "needsReview": return .needsReview
        case "possibleDuplicates": return .possibleDuplicates
        case "aiQueue": return .aiQueue
        case "recent": return .recent
        case "multipleVersions": return .multipleVersions
        case "missingDOI": return .missingDOI
        case "unanalyzed": return .unanalyzed
        default:
            if value.hasPrefix("category:"),
               let id = UUID(uuidString: String(value.dropFirst("category:".count))) {
                return .category(id)
            }
            if value.hasPrefix("project:"),
               let id = UUID(uuidString: String(value.dropFirst("project:".count))) {
                return .project(id)
            }
            return nil
        }
    }
}

enum LibrarySortField: String, CaseIterable, Identifiable {
    case title
    case dateAdded
    case lastOpened
    case publicationYear
    case authors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "名称"
        case .dateAdded: return "加入时间"
        case .lastOpened: return "上次打开时间"
        case .publicationYear: return "发表年份"
        case .authors: return "作者"
        }
    }
}

enum LibrarySortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }
}

enum LibrarySortRules {
    static func sorted(
        _ works: [Work],
        by field: LibrarySortField,
        direction: LibrarySortDirection,
        priority: ((Work) -> ProjectWorkPriority)? = nil
    ) -> [Work] {
        works.sorted { left, right in
            if let priority {
                let leftPriority = priority(left).sortRank
                let rightPriority = priority(right).sortRank
                if leftPriority != rightPriority { return leftPriority > rightPriority }
            }
            let leftMissing = isMissing(left, for: field)
            let rightMissing = isMissing(right, for: field)
            if leftMissing != rightMissing { return !leftMissing }
            let comparison = compare(left, right, by: field)
            if comparison == .orderedSame {
                let titleComparison = left.title.localizedStandardCompare(right.title)
                if titleComparison == .orderedSame {
                    return left.id.uuidString < right.id.uuidString
                }
                return titleComparison == .orderedAscending
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    static func sorted(
        _ snapshots: [LibraryWorkSnapshot],
        by field: LibrarySortField,
        direction: LibrarySortDirection,
        priorityValues: [String: Int] = [:]
    ) -> [LibraryWorkSnapshot] {
        snapshots.sorted { left, right in
            let leftPriority = ProjectWorkPriority(
                rawValue: priorityValues[left.workID.uuidString] ?? 0
            )?.sortRank ?? 0
            let rightPriority = ProjectWorkPriority(
                rawValue: priorityValues[right.workID.uuidString] ?? 0
            )?.sortRank ?? 0
            if leftPriority != rightPriority { return leftPriority > rightPriority }

            let leftMissing = isMissing(left, for: field)
            let rightMissing = isMissing(right, for: field)
            if leftMissing != rightMissing { return !leftMissing }
            let comparison = compare(left, right, by: field)
            if comparison == .orderedSame {
                let titleComparison = left.title.localizedStandardCompare(right.title)
                if titleComparison == .orderedSame {
                    return left.workID.uuidString < right.workID.uuidString
                }
                return titleComparison == .orderedAscending
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func isMissing(_ work: Work, for field: LibrarySortField) -> Bool {
        switch field {
        case .lastOpened: return work.lastOpenedAt == nil
        case .publicationYear: return work.publicationYear == nil
        default: return false
        }
    }

    private static func isMissing(
        _ snapshot: LibraryWorkSnapshot,
        for field: LibrarySortField
    ) -> Bool {
        switch field {
        case .lastOpened: return snapshot.lastOpenedAt == nil
        case .publicationYear: return snapshot.publicationYear == nil
        default: return false
        }
    }

    private static func compare(
        _ left: Work,
        _ right: Work,
        by field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .title:
            return left.title.localizedStandardCompare(right.title)
        case .dateAdded:
            return compare(left.dateAdded, right.dateAdded)
        case .lastOpened:
            return compareOptional(left.lastOpenedAt, right.lastOpenedAt)
        case .publicationYear:
            return compareOptional(left.publicationYear, right.publicationYear)
        case .authors:
            return left.authorsText.localizedStandardCompare(right.authorsText)
        }
    }

    private static func compare(
        _ left: LibraryWorkSnapshot,
        _ right: LibraryWorkSnapshot,
        by field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .title:
            return left.title.localizedStandardCompare(right.title)
        case .dateAdded:
            return compare(left.dateAdded, right.dateAdded)
        case .lastOpened:
            return compareOptional(left.lastOpenedAt, right.lastOpenedAt)
        case .publicationYear:
            return compareOptional(left.publicationYear, right.publicationYear)
        case .authors:
            return left.authorsText.localizedStandardCompare(right.authorsText)
        }
    }

    private static func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private static func compareOptional<T: Comparable>(
        _ left: T?,
        _ right: T?
    ) -> ComparisonResult {
        switch (left, right) {
        case let (.some(left), .some(right)):
            return compare(left, right)
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }
}

struct PendingBibTeXReview: Identifiable {
    let id = UUID()
    let workTitle: String
    let sourceName: String
    let differences: [BibTeXDifference]
    let onlineEntry: BibTeXEntry
    let localEntry: BibTeXEntry?
    let suggestedDirectory: URL?
}

enum LibrarySearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case title
    case authors
    case bibliographic
    case research
    case identifiers
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .title: return "题名"
        case .authors: return "作者"
        case .bibliographic: return "书目信息"
        case .research: return "摘要与研究内容"
        case .identifiers: return "标识符"
        case .files: return "文件与版本"
        }
    }
}

enum LibrarySearchMatchMode: String, CaseIterable, Identifiable, Sendable {
    case allTerms
    case anyTerm
    case exactPhrase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTerms: return "包含所有关键词"
        case .anyTerm: return "包含任一关键词"
        case .exactPhrase: return "完整词组"
        }
    }
}

enum LibrarySearchMode: String, CaseIterable, Identifiable, Sendable {
    case keyword
    case smart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyword: return "关键词"
        case .smart: return "智能"
        }
    }

    var systemImage: String {
        switch self {
        case .keyword: return "text.magnifyingglass"
        case .smart: return "sparkle.magnifyingglass"
        }
    }
}

struct LibrarySearchOptions: Hashable, Sendable {
    var scope: LibrarySearchScope = .all
    var matchMode: LibrarySearchMatchMode = .allTerms
    var minimumYearText = ""
    var maximumYearText = ""
    var onlyNeedsReview = false
    var onlyAnalyzed = false
    var onlyWithAbstract = false
    var onlyAnnotated = false
    var onlyMultipleVersions = false
    var onlyMissingDOI = false

    var minimumYear: Int? { Int(minimumYearText.trimmingCharacters(in: .whitespaces)) }
    var maximumYear: Int? { Int(maximumYearText.trimmingCharacters(in: .whitespaces)) }

    var activeOptionCount: Int {
        var count = scope == .all ? 0 : 1
        if matchMode != .allTerms { count += 1 }
        if minimumYear != nil { count += 1 }
        if maximumYear != nil { count += 1 }
        count += [
            onlyNeedsReview, onlyAnalyzed, onlyWithAbstract,
            onlyAnnotated, onlyMultipleVersions, onlyMissingDOI,
        ].filter { $0 }.count
        return count
    }

    mutating func reset() {
        self = LibrarySearchOptions()
    }
}

struct LibrarySearchFieldGroupSnapshot: Sendable {
    let name: String
    let weight: Int
    let normalizedValues: [String]
    let scopes: Set<LibrarySearchScope>
}

/// 与 SwiftData 关系解耦的列表工作快照。分析 JSON、标签和文件关系只在
/// 数据成功保存后读取一次，后续筛选、计分和匹配原因共享同一份结果。
struct LibraryWorkSnapshot: Sendable {
    let workID: UUID
    let title: String
    let authorsText: String
    let dateAdded: Date
    let lastOpenedAt: Date?
    let publicationYear: Int?
    let primaryCategoryID: UUID?
    let tagIDs: Set<UUID>
    let personalMarkIDs: Set<UUID>
    let projectIDs: Set<UUID>
    let duplicateCandidateWorkID: UUID?
    let normalizedFields: [LibrarySearchScope: [String]]
    let fieldGroups: [LibrarySearchFieldGroupSnapshot]
    let needsReview: Bool
    let latestAnalysisStatus: String?
    let hasAbstract: Bool
    let hasAnnotations: Bool
    let fileVersionCount: Int
    let isMissingDOI: Bool
}

struct LibraryListRequestKey: Hashable {
    let snapshotVersion: UInt64
    let sidebarSelection: SidebarSelection?
    let query: String
    let searchMode: LibrarySearchMode
    let searchOptions: LibrarySearchOptions
    let selectedTagIDs: Set<UUID>
    let selectedPersonalMarkIDs: Set<UUID>
    let sortField: LibrarySortField
    let sortDirection: LibrarySortDirection
    let projectID: UUID?
    let projectPriorityData: Data?
    let searchResultVersion: UInt64
}

@MainActor
final class LibraryListController: ObservableObject {
    @Published private(set) var version: UInt64 = 0
    private(set) var snapshots: [UUID: LibraryWorkSnapshot] = [:]
    private(set) var orderedSnapshots: [LibraryWorkSnapshot] = []
    private var cachedRequest: LibraryListRequestKey?
    private var cachedWorkIDs: [UUID] = []

    func rebuild(from works: [Work]) {
        orderedSnapshots = works.map(LibrarySearchRules.snapshot)
        snapshots = Dictionary(uniqueKeysWithValues: orderedSnapshots.map { ($0.workID, $0) })
        cachedRequest = nil
        cachedWorkIDs = []
        version &+= 1
    }

    func snapshot(for workID: UUID) -> LibraryWorkSnapshot? {
        snapshots[workID]
    }

    func workIDs(
        for request: LibraryListRequestKey,
        build: () -> [UUID]
    ) -> [UUID] {
        if cachedRequest == request { return cachedWorkIDs }
        let result = build()
        cachedRequest = request
        cachedWorkIDs = result
        return result
    }
}

struct LibraryChangeSet: Sendable, Equatable {
    var workIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    var tagIDs: Set<UUID> = []
    var fileVersionIDs: Set<UUID> = []
    var projectIDs: Set<UUID> = []
    var affectsManifest = true
    var affectsSearchMetadata = true

    static let catalog = LibraryChangeSet()
}

@MainActor
final class LibraryMutationStore: ObservableObject {
    @Published private(set) var version: UInt64 = 0
    @Published private(set) var latestChanges = LibraryChangeSet.catalog

    func save(changes: LibraryChangeSet, using modelContext: ModelContext) throws {
        do {
            try modelContext.save()
            latestChanges = changes
            version &+= 1
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

enum LibrarySearchRules {
    static func snapshot(for work: Work) -> LibraryWorkSnapshot {
        let researchValues = [work.abstractText ?? ""] + work.analyses.compactMap(\.resultJSON)
            .compactMap { json -> PaperAnalysis? in
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(PaperAnalysis.self, from: data)
            }
            .flatMap { analysis in
                analysis.evidenceFields.flatMap { [$0.value, $0.evidence] }
                    + [analysis.suggestedCategory]
                    + analysis.suggestedTags
            }
        let bibliographic = [
            work.title, work.authorsText, work.publicationYear.map(String.init) ?? "",
            work.journal ?? "", work.abstractText ?? "", work.publisher ?? "",
            localizedDocumentType(work.documentTypeRawValue), work.primaryCategory?.name ?? "",
            work.tags.map(\.name).joined(separator: " "),
        ]
        let identifiers = [
            work.doi ?? "", work.nberNumber ?? "", work.ssrnID ?? "",
            work.arxivID ?? "", work.repecHandle ?? "", work.isbn ?? "",
        ]
        let files = work.fileVersions.flatMap { version in
            [version.originalFilename, version.relativePath, localizedVersionType(version.versionTypeRawValue)]
        }
        let notes = [work.metadataConflictNote ?? ""]
        func normalized(_ values: [String]) -> [String] {
            values.map(normalize).filter { !$0.isEmpty }
        }
        let normalizedBibliographic = normalized(bibliographic)
        let normalizedIdentifiers = normalized(identifiers)
        let normalizedFiles = normalized(files)
        let normalizedResearch = normalized(researchValues)
        let normalizedNotes = normalized(notes)
        let fields: [LibrarySearchScope: [String]] = [
            .all: normalizedBibliographic + normalizedIdentifiers + normalizedFiles + normalizedResearch + normalizedNotes,
            .title: normalized([work.title]),
            .authors: normalized([work.authorsText]),
            .bibliographic: normalizedBibliographic,
            .research: normalizedResearch,
            .identifiers: normalizedIdentifiers,
            .files: normalizedFiles,
        ]
        let groups: [(String, Int, [String], Set<LibrarySearchScope>)] = [
            ("题名", 100, [work.title], [.all, .title, .bibliographic]),
            ("标识符", 90, identifiers, [.all, .identifiers]),
            ("作者", 80, [work.authorsText], [.all, .authors, .bibliographic]),
            ("发表年份", 70, [work.publicationYear.map(String.init) ?? ""], [.all, .bibliographic]),
            ("书目信息", 55, [work.journal ?? "", work.publisher ?? "",
                localizedDocumentType(work.documentTypeRawValue), work.primaryCategory?.name ?? "",
                work.tags.map(\.name).joined(separator: " ")], [.all, .bibliographic]),
            ("文件名或版本", 45, files, [.all, .files]),
            ("摘要", 35, [work.abstractText ?? ""], [.all, .bibliographic, .research]),
            ("检查备注", 10, notes, [.all]),
        ]
        return LibraryWorkSnapshot(
            workID: work.id,
            title: work.title,
            authorsText: work.authorsText,
            dateAdded: work.dateAdded,
            lastOpenedAt: work.lastOpenedAt,
            publicationYear: work.publicationYear,
            primaryCategoryID: work.primaryCategory?.id,
            tagIDs: Set(work.tags.map(\.id)),
            personalMarkIDs: Set(work.personalMarks.map(\.id)),
            projectIDs: Set(work.projects.map(\.id)),
            duplicateCandidateWorkID: work.duplicateCandidateWorkID,
            normalizedFields: fields,
            fieldGroups: groups.map {
                LibrarySearchFieldGroupSnapshot(
                    name: $0.0,
                    weight: $0.1,
                    normalizedValues: normalized($0.2),
                    scopes: $0.3
                )
            },
            needsReview: WorkReviewRules.requiresReview(work),
            latestAnalysisStatus: AIAnalysisStateRules.latestStatus(for: work),
            hasAbstract: !(work.abstractText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasAnnotations: work.fileVersions.contains(where: \.hasAnnotations),
            fileVersionCount: work.fileVersions.count,
            isMissingDOI: (work.doi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    static func matches(_ work: Work, query: String, options: LibrarySearchOptions) -> Bool {
        guard matchesSpecialFilters(work, options: options) else { return false }
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        return matches(snapshot(for: work), query: query, options: options)
    }

    static func matches(
        _ snapshot: LibraryWorkSnapshot,
        query: String,
        options: LibrarySearchOptions
    ) -> Bool {
        guard matchesSpecialFilters(snapshot, options: options) else { return false }
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        // 构造搜索字段会读取关系并解析分析 JSON。空查询是列表的常态，
        // 必须在这些昂贵工作之前返回。
        let fields = snapshot.normalizedFields[options.scope] ?? []

        switch options.matchMode {
        case .allTerms:
            let terms = queryTerms(query)
            return !terms.isEmpty && terms.allSatisfy { term in
                fields.contains { $0.contains(term) }
            }
        case .anyTerm:
            let terms = queryTerms(query)
            return terms.contains { term in fields.contains { $0.contains(term) } }
        case .exactPhrase:
            let phrase = normalizedQuery.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            return !phrase.isEmpty && fields.contains { $0.contains(phrase) }
        }
    }

    static func queryTerms(_ query: String) -> [String] {
        let value = query
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        var terms: [String] = []
        var buffer = ""
        var insideQuotes = false

        func appendBuffer() {
            let term = normalize(buffer)
            if !term.isEmpty { terms.append(term) }
            buffer = ""
        }

        for character in value {
            if character == "\"" {
                if insideQuotes { appendBuffer() }
                else if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appendBuffer() }
                insideQuotes.toggle()
            } else if character.isWhitespace && !insideQuotes {
                appendBuffer()
            } else {
                buffer.append(character)
            }
        }
        appendBuffer()
        return terms
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func relevanceScore(
        for work: Work,
        query: String,
        options: LibrarySearchOptions
    ) -> Int {
        relevanceScore(for: snapshot(for: work), query: query, options: options)
    }

    static func relevanceScore(
        for snapshot: LibraryWorkSnapshot,
        query: String,
        options: LibrarySearchOptions
    ) -> Int {
        let terms = scoringTerms(query, mode: options.matchMode)
        guard !terms.isEmpty else { return 0 }
        return snapshot.fieldGroups.filter { $0.scopes.contains(options.scope) }.reduce(0) { total, group in
            let hits = terms.filter { term in
                group.normalizedValues.contains { $0.contains(term) }
            }.count
            return total + hits * group.weight
        }
    }

    static func primaryMatchReason(
        for work: Work,
        query: String,
        options: LibrarySearchOptions
    ) -> String? {
        primaryMatchReason(for: snapshot(for: work), query: query, options: options)
    }

    static func primaryMatchReason(
        for snapshot: LibraryWorkSnapshot,
        query: String,
        options: LibrarySearchOptions
    ) -> String? {
        let terms = scoringTerms(query, mode: options.matchMode)
        guard !terms.isEmpty else { return nil }
        let visibleGroups = snapshot.fieldGroups.filter { $0.scopes.contains(options.scope) }
        if let group = visibleGroups
            .sorted(by: { $0.weight > $1.weight })
            .first(where: { group in
                terms.contains { term in group.normalizedValues.contains { $0.contains(term) } }
            }) {
            return "匹配\(group.name)"
        }
        if options.scope == .research || options.scope == .all {
            return "匹配智能分析内容"
        }
        return nil
    }

    private static func scoringTerms(
        _ query: String,
        mode: LibrarySearchMatchMode
    ) -> [String] {
        if mode == .exactPhrase {
            let phrase = normalize(query).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"“”")
            )
            return phrase.isEmpty ? [] : [phrase]
        }
        return queryTerms(query)
    }

    private static func matchesSpecialFilters(
        _ work: Work,
        options: LibrarySearchOptions
    ) -> Bool {
        if let minimumYear = options.minimumYear,
           (work.publicationYear ?? Int.min) < minimumYear { return false }
        if let maximumYear = options.maximumYear,
           (work.publicationYear ?? Int.max) > maximumYear { return false }
        if options.onlyNeedsReview, !WorkReviewRules.requiresReview(work) { return false }
        if options.onlyAnalyzed,
           AIAnalysisStateRules.latestStatus(for: work) != "completed" { return false }
        if options.onlyWithAbstract,
           (work.abstractText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if options.onlyAnnotated, !work.fileVersions.contains(where: \.hasAnnotations) { return false }
        if options.onlyMultipleVersions, work.fileVersions.count < 2 { return false }
        if options.onlyMissingDOI,
           !(work.doi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    private static func matchesSpecialFilters(
        _ snapshot: LibraryWorkSnapshot,
        options: LibrarySearchOptions
    ) -> Bool {
        if let minimumYear = options.minimumYear,
           (snapshot.publicationYear ?? Int.min) < minimumYear { return false }
        if let maximumYear = options.maximumYear,
           (snapshot.publicationYear ?? Int.max) > maximumYear { return false }
        if options.onlyNeedsReview, !snapshot.needsReview { return false }
        if options.onlyAnalyzed, snapshot.latestAnalysisStatus != "completed" { return false }
        if options.onlyWithAbstract, !snapshot.hasAbstract { return false }
        if options.onlyAnnotated, !snapshot.hasAnnotations { return false }
        if options.onlyMultipleVersions, snapshot.fileVersionCount < 2 { return false }
        if options.onlyMissingDOI, !snapshot.isMissingDOI { return false }
        return true
    }

    private static func localizedDocumentType(_ rawValue: String?) -> String {
        switch rawValue {
        case "article": return "article 期刊论文"
        case "workingPaper": return "working paper 工作论文"
        case "book": return "book 书籍"
        case "bookChapter": return "book chapter 书籍章节"
        case "report": return "report 研究报告"
        case "thesis": return "thesis 学位论文"
        case "other": return "other 其他"
        default: return rawValue ?? ""
        }
    }

    private static func localizedVersionType(_ rawValue: String) -> String {
        switch rawValue {
        case "published": return "published 发表版"
        case "workingPaper": return "working paper 工作论文"
        case "acceptedManuscript": return "accepted manuscript 录用稿"
        case "preprint": return "preprint 预印本"
        case "supplement": return "supplement 补充材料"
        case "annotatedCopy": return "annotated copy 批注副本"
        default: return rawValue
        }
    }
}

struct LibrarySearchField: View {
    @Binding var searchText: String
    @Binding var mode: LibrarySearchMode
    @Binding var options: LibrarySearchOptions
    let prompt: String
    let isSearching: Bool
    let readinessText: String?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Menu {
                Picker("搜索模式", selection: $mode) {
                    ForEach(LibrarySearchMode.allCases) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
            } label: {
                Label(mode.title, systemImage: mode.systemImage)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择关键词搜索或智能搜索")

            Divider()
                .frame(height: 18)

            TextField(prompt, text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .help("正在智能搜索")
            } else if let readinessText {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(readinessText)
                    .accessibilityLabel(readinessText)
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }

            Menu {
                Picker("搜索范围", selection: $options.scope) {
                    ForEach(LibrarySearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Divider()
                Picker("匹配方式", selection: $options.matchMode) {
                    ForEach(LibrarySearchMatchMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Divider()
                TextField("起始年份", text: $options.minimumYearText)
                TextField("结束年份", text: $options.maximumYearText)
                Divider()
                Toggle("需要检查", isOn: $options.onlyNeedsReview)
                Toggle("已完成分析", isOn: $options.onlyAnalyzed)
                Toggle("已有摘要", isOn: $options.onlyWithAbstract)
                Toggle("带批注", isOn: $options.onlyAnnotated)
                Toggle("多个版本", isOn: $options.onlyMultipleVersions)
                Toggle("缺少 DOI", isOn: $options.onlyMissingDOI)
                if options.activeOptionCount > 0 {
                    Divider()
                    Button("清除搜索筛选") {
                        options.reset()
                    }
                }
            } label: {
                Image(systemName: options.activeOptionCount == 0
                      ? "slider.horizontal.3"
                      : "slider.horizontal.3.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(options.activeOptionCount == 0
                  ? "搜索筛选"
                  : "已启用 \(options.activeOptionCount) 个搜索筛选")

            Button(action: onSubmit) {
                Image(systemName: "magnifyingglass")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            .help(mode == .smart ? "开始智能搜索（回车）" : "搜索（回车）")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
    }
}

enum BatchTagOperation: String, CaseIterable, Identifiable {
    case add
    case remove

    var id: String { rawValue }
    var title: String { self == .add ? "添加标签" : "移除标签" }
}

struct BatchConfirmationDialogs: ViewModifier {
    let selectedCount: Int
    @Binding var showingReprocess: Bool
    @Binding var showingReview: Bool
    let onReprocess: () -> Void
    let onReview: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "重新处理 \(selectedCount) 篇文献？",
                isPresented: $showingReprocess
            ) {
                Button("重置并重新处理", role: .destructive, action: onReprocess)
                Button("取消", role: .cancel) {}
            } message: {
                Text("会重置可重新提取的书目字段，将文件移回未分类目录，但保留用户标签、强标识符和历史分析。")
            }
            .confirmationDialog(
                "将可安全处理的文献标记为已检查？",
                isPresented: $showingReview
            ) {
                Button("标记为已检查", action: onReview)
                Button("取消", role: .cancel) {}
            } message: {
                Text("疑似重复、文件缺失或智能处理未完成的文献会自动跳过。")
            }
    }
}

struct LibraryFileImportDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let receiveDrop: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        !LibraryFileDropRules.externalURLProviders(
            from: info.itemProviders(for: [UTType.url.identifier])
        ).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return receiveDrop(info.itemProviders(for: [UTType.url.identifier]))
    }
}

struct ImportDuplicateReviewSheet: View {
    let review: PendingImportReview
    let onAddVersion: (String) -> Void
    let onImportSeparately: () -> Void
    let onCancel: () -> Void

    @State private var versionType: String

    init(
        review: PendingImportReview,
        onAddVersion: @escaping (String) -> Void,
        onImportSeparately: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.review = review
        self.onAddVersion = onAddVersion
        self.onImportSeparately = onImportSeparately
        self.onCancel = onCancel
        _versionType = State(initialValue: review.imported.suggestedVersionType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("发现相似文献")
                .font(.title2)
            Label(review.matchReason, systemImage: "doc.on.doc")
                .foregroundStyle(.orange)

            GroupBox("新导入文件") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("文件", value: review.imported.originalFilename)
                    LabeledContent("标题", value: review.imported.title)
                    LabeledContent(
                        "作者",
                        value: review.imported.authorsText.isEmpty ? "未知" : review.imported.authorsText
                    )
                    LabeledContent(
                        "年份",
                        value: review.imported.publicationYear.map(String.init) ?? "未知"
                    )
                    LabeledContent("页数", value: review.imported.pageCount.formatted())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("已有文献") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("标题", value: review.candidateTitle)
                    LabeledContent(
                        "作者",
                        value: review.candidateAuthorsText.isEmpty ? "未知" : review.candidateAuthorsText
                    )
                    LabeledContent(
                        "年份",
                        value: review.candidateYear.map(String.init) ?? "未知"
                    )
                    LabeledContent("已有版本", value: review.candidateVersionCount.formatted())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("作为新版本加入时的类型", selection: $versionType) {
                Text("未知").tag("unknown")
                Text("正式发表版").tag("published")
                Text("工作论文").tag("workingPaper")
                Text("录用稿").tag("acceptedManuscript")
                Text("预印本").tag("preprint")
                Text("补充材料").tag("supplement")
                Text("带标注副本").tag("annotatedCopy")
            }

            Text("作为新版本加入后，文件会进入已有文章的文件夹；不会自动替换主要版本或重新生成研究卡。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("取消导入", role: .cancel, action: onCancel)
                Spacer()
                Button("作为独立文献导入", action: onImportSeparately)
                Button("作为新版本加入") { onAddVersion(versionType) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
}

/// 将清单变化检测隔离在独立视图中。文章选择只会刷新 LibraryView，
/// 不应因此重新遍历整个资料库并触发 SwiftData 关系取值。
struct ManifestAutosaveObserver: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Work.dateAdded, order: .reverse) private var works: [Work]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \PersonalMark.sortOrder) private var personalMarks: [PersonalMark]
    @Query(sort: \ReadingProject.name) private var projects: [ReadingProject]

    @ObservedObject var coordinator: ManifestCoordinator
    let libraryID: UUID?
    let rootURL: URL?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear(perform: scheduleExport)
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
                // SwiftData 的一次成功保存就是单调递增的变更事件。依赖保存通知，
                // 避免每次界面求值都拼接整库字符串和遍历全部关系。
                guard notification.object as AnyObject? === modelContext else { return }
                scheduleExport()
            }
    }

    private func scheduleExport() {
        guard let libraryID, let rootURL else { return }
        coordinator.scheduleExport(
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
