import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  @MainActor
  func testBatchTagRulesAddWithoutDuplicatesAndRemoveFromAllSelectedWorks() throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let first = Work(title: "第一篇")
    let second = Work(title: "第二篇")
    let tag = Tag(name: "因果推断")
    container.mainContext.insert(first)
    container.mainContext.insert(second)
    container.mainContext.insert(tag)

    BatchTagRules.add([tag], to: [first, second])
    BatchTagRules.add([tag], to: [first, second])
    XCTAssertEqual(first.tags.count, 1)
    XCTAssertEqual(second.tags.count, 1)

    BatchTagRules.remove([tag], from: [first, second])
    XCTAssertTrue(first.tags.isEmpty)
    XCTAssertTrue(second.tags.isEmpty)
  }

  func testLibrarySortingSupportsNameAddedAndLastOpened() {
    let oldest = Work(
      title: "Beta",
      dateAdded: Date(timeIntervalSince1970: 100),
      lastOpenedAt: Date(timeIntervalSince1970: 300)
    )
    let newest = Work(
      title: "Alpha",
      dateAdded: Date(timeIntervalSince1970: 200),
      lastOpenedAt: Date(timeIntervalSince1970: 400)
    )
    let neverOpened = Work(
      title: "Gamma",
      dateAdded: Date(timeIntervalSince1970: 150)
    )

    XCTAssertEqual(
      LibrarySortRules.sorted(
        [oldest, newest, neverOpened],
        by: .dateAdded,
        direction: .descending
      ).map(\.id),
      [newest.id, neverOpened.id, oldest.id]
    )
    XCTAssertEqual(
      LibrarySortRules.sorted(
        [oldest, newest, neverOpened],
        by: .lastOpened,
        direction: .ascending
      ).map(\.id),
      [oldest.id, newest.id, neverOpened.id]
    )
    XCTAssertEqual(
      LibrarySortRules.sorted(
        [oldest, newest, neverOpened],
        by: .lastOpened,
        direction: .descending
      ).map(\.id),
      [newest.id, oldest.id, neverOpened.id]
    )

    let project = ReadingProject(name: "优先级排序")
    let completed = Work(
      title: "已读文献",
      dateAdded: Date(timeIntervalSince1970: 4)
    )
    project.setPriority(.two, for: oldest.id)
    project.setPriority(.two, for: newest.id)
    project.setPriority(.three, for: neverOpened.id)
    project.setPriority(.completed, for: completed.id)
    XCTAssertEqual(
      LibrarySortRules.sorted(
        [completed, oldest, newest, neverOpened],
        by: .dateAdded,
        direction: .ascending,
        priority: { project.priority(for: $0.id) }
      ).map(\.id),
      [neverOpened.id, oldest.id, newest.id, completed.id]
    )
    XCTAssertEqual(
      LibrarySortRules.sorted(
        [oldest, newest, neverOpened],
        by: .title,
        direction: .ascending
      ).map(\.id),
      [newest.id, oldest.id, neverOpened.id]
    )
  }

  @MainActor
  func testWorkCanBelongToMultipleProjectsWithoutChangingFilePath() throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let work = Work(title: "跨项目文献")
    let version = FileVersion(
      relativePath: "Labor/2024/paper.pdf",
      originalFilename: "paper.pdf",
      pageCount: 10,
      fileSize: 100
    )
    let first = ReadingProject(name: "项目一")
    let second = ReadingProject(name: "项目二")
    work.fileVersions.append(version)
    work.projects.append(contentsOf: [first, second])
    container.mainContext.insert(work)
    container.mainContext.insert(first)
    container.mainContext.insert(second)
    try container.mainContext.save()

    XCTAssertEqual(Set(work.projects.map(\.name)), ["项目一", "项目二"])
    XCTAssertEqual(version.relativePath, "Labor/2024/paper.pdf")

    container.mainContext.delete(first)
    try container.mainContext.save()

    XCTAssertEqual(work.projects.map(\.name), ["项目二"])
    XCTAssertEqual(version.relativePath, "Labor/2024/paper.pdf")
  }

  @MainActor
  func testRenamingProjectPreservesWorksAndPriorities() throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let work = Work(title: "项目改名测试")
    let project = ReadingProject(name: "原项目")
    work.projects.append(project)
    project.setPriority(.three, for: work.id)
    container.mainContext.insert(work)
    container.mainContext.insert(project)
    try container.mainContext.save()

    project.name = "新项目"
    try container.mainContext.save()

    let savedProject = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<ReadingProject>()).first { $0.id == project.id }
    )
    XCTAssertEqual(savedProject.name, "新项目")
    XCTAssertEqual(savedProject.works.map(\.id), [work.id])
    XCTAssertEqual(savedProject.priority(for: work.id), .three)
  }

  @MainActor
  func testBatchReviewRulesSkipUnresolvedProblems() throws {
    let normal = Work(
      title: "可标记",
      needsReview: true,
      metadataConflictNote: "标题与 Crossref 记录不同"
    )
    let duplicate = Work(
      title: "疑似重复",
      needsReview: true,
      duplicateCandidateWorkID: UUID()
    )
    let missing = Work(
      title: "文件缺失",
      needsReview: true,
      metadataConflictNote: "找不到资料库中的 PDF 文件：test.pdf"
    )
    let failed = Work(title: "处理失败", needsReview: true)
    failed.analyses.append(
      AIAnalysis(
        modelName: "test",
        promptVersion: "test",
        status: "failed"
      ))

    let result = BatchReviewRules.markReviewed([normal, duplicate, missing, failed])

    XCTAssertEqual(result, .init(marked: 1, skipped: 3))
    XCTAssertFalse(normal.needsReview)
    XCTAssertNil(normal.metadataConflictNote)
    XCTAssertTrue(duplicate.needsReview)
    XCTAssertTrue(missing.needsReview)
    XCTAssertTrue(failed.needsReview)
  }

  @MainActor
  func testSearchMatchesMultipleTermsAcrossFieldsAndNormalizesText() {
    let work = Work(
      title: "Labor Supply Responses",
      authorsText: "José Álvarez",
      publicationYear: 2024,
      doi: "10.1234/example"
    )

    XCTAssertTrue(
      LibrarySearchRules.matches(
        work,
        query: "alvarez 2024",
        options: LibrarySearchOptions()
      ))
    XCTAssertTrue(
      LibrarySearchRules.matches(
        work,
        query: "ＬＡＢＯＲ",
        options: LibrarySearchOptions()
      ))
    var titleOnly = LibrarySearchOptions()
    titleOnly.scope = .title
    XCTAssertFalse(
      LibrarySearchRules.matches(
        work,
        query: "alvarez",
        options: titleOnly
      ))
  }

  @MainActor
  func testSearchSupportsQuotedPhrasesAndAnyKeywordMode() {
    let work = Work(
      title: "The Employment Effects of a Minimum Wage",
      authorsText: "Jane Smith"
    )
    XCTAssertTrue(
      LibrarySearchRules.matches(
        work,
        query: "smith \"minimum wage\"",
        options: LibrarySearchOptions()
      ))
    XCTAssertFalse(
      LibrarySearchRules.matches(
        work,
        query: "smith taxation",
        options: LibrarySearchOptions()
      ))
    var anyKeyword = LibrarySearchOptions()
    anyKeyword.matchMode = .anyTerm
    XCTAssertTrue(
      LibrarySearchRules.matches(
        work,
        query: "smith taxation",
        options: anyKeyword
      ))
  }

  @MainActor
  func testSearchIncludesAbstractYearFilenameAndLocalizedVersionType() {
    let work = Work(
      title: "A Study",
      publicationYear: 2022,
      abstractText: "使用断点回归识别政策效应"
    )
    work.fileVersions.append(
      FileVersion(
        relativePath: "Labor/2022/source-copy.pdf",
        originalFilename: "RDD-final.pdf",
        pageCount: 20,
        fileSize: 100,
        versionTypeRawValue: "acceptedManuscript"
      ))

    XCTAssertTrue(
      LibrarySearchRules.matches(
        work,
        query: "2022 断点回归",
        options: LibrarySearchOptions()
      ))
    var files = LibrarySearchOptions()
    files.scope = .files
    XCTAssertTrue(LibrarySearchRules.matches(work, query: "rdd-final", options: files))
    XCTAssertTrue(LibrarySearchRules.matches(work, query: "录用稿", options: files))
  }

  @MainActor
  func testSearchSpecialFiltersAndIgnoresRawAnalysisKeys() {
    let work = Work(
      title: "Filtered Work",
      publicationYear: 2021,
      abstractText: "有摘要",
      needsReview: true
    )
    work.fileVersions.append(
      FileVersion(
        relativePath: "one.pdf",
        originalFilename: "one.pdf",
        pageCount: 1,
        fileSize: 1,
        hasAnnotations: true
      ))
    work.fileVersions.append(
      FileVersion(
        relativePath: "two.pdf",
        originalFilename: "two.pdf",
        pageCount: 1,
        fileSize: 1,
        isPreferred: false
      ))
    work.analyses.append(
      AIAnalysis(
        modelName: "test",
        promptVersion: "test",
        resultJSON: #"{"internalNoise":"needle","status":"unknown"}"#,
        status: "completed"
      ))

    var options = LibrarySearchOptions()
    options.minimumYearText = "2020"
    options.maximumYearText = "2022"
    options.onlyNeedsReview = true
    options.onlyAnalyzed = true
    options.onlyWithAbstract = true
    options.onlyAnnotated = true
    options.onlyMultipleVersions = true
    options.onlyMissingDOI = true
    XCTAssertTrue(LibrarySearchRules.matches(work, query: "", options: options))

    options.scope = .research
    XCTAssertFalse(LibrarySearchRules.matches(work, query: "needle", options: options))
    options.maximumYearText = "2020"
    XCTAssertFalse(LibrarySearchRules.matches(work, query: "", options: options))
  }

  @MainActor
  func testLibraryListControllerKeepsStableSnapshotUntilRebuild() {
    let work = Work(title: "旧题名")
    let controller = LibraryListController()
    controller.rebuild(from: [work])
    let initialVersion = controller.version
    let initial = controller.snapshot(for: work.id)!
    XCTAssertTrue(LibrarySearchRules.matches(initial, query: "旧题名", options: .init()))

    work.title = "新题名"
    let unchanged = controller.snapshot(for: work.id)!
    XCTAssertTrue(LibrarySearchRules.matches(unchanged, query: "旧题名", options: .init()))
    XCTAssertFalse(LibrarySearchRules.matches(unchanged, query: "新题名", options: .init()))

    controller.rebuild(from: [work])
    XCTAssertGreaterThan(controller.version, initialVersion)
    let refreshed = controller.snapshot(for: work.id)!
    XCTAssertTrue(LibrarySearchRules.matches(refreshed, query: "新题名", options: .init()))
  }

  @MainActor
  func testLibraryListControllerReusesResolvedIDsUntilRequestChanges() {
    let work = Work(title: "缓存测试")
    let controller = LibraryListController()
    controller.rebuild(from: [work])
    var buildCount = 0
    func request(query: String) -> LibraryListRequestKey {
      LibraryListRequestKey(
        snapshotVersion: controller.version,
        sidebarSelection: .all,
        query: query,
        searchMode: .keyword,
        searchOptions: .init(),
        selectedTagIDs: [],
        selectedPersonalMarkIDs: [],
        sortField: .title,
        sortDirection: .ascending,
        projectID: nil,
        projectPriorityData: nil,
        searchResultVersion: 0
      )
    }

    let first = controller.workIDs(for: request(query: "")) {
      buildCount += 1
      return [work.id]
    }
    let second = controller.workIDs(for: request(query: "")) {
      buildCount += 1
      return []
    }
    let changed = controller.workIDs(for: request(query: "新查询")) {
      buildCount += 1
      return []
    }

    XCTAssertEqual(first, [work.id])
    XCTAssertEqual(second, [work.id])
    XCTAssertTrue(changed.isEmpty)
    XCTAssertEqual(buildCount, 2)
  }

  @MainActor
  func testSnapshotPrioritySortMatchesModelSortWithoutRepeatedDecoding() {
    let first = Work(title: "甲", dateAdded: Date(timeIntervalSince1970: 2))
    let second = Work(title: "乙", dateAdded: Date(timeIntervalSince1970: 1))
    let controller = LibraryListController()
    controller.rebuild(from: [first, second])
    let priorities = [second.id.uuidString: ProjectWorkPriority.three.rawValue]

    XCTAssertEqual(
      LibrarySortRules.sorted(
        controller.orderedSnapshots,
        by: .dateAdded,
        direction: .descending,
        priorityValues: priorities
      ).map(\.workID),
      [second.id, first.id]
    )
  }

  @MainActor
  func testFiveThousandEstablishedSnapshotsFilterAndSortWithinBaseline() {
    let works = (0..<5_000).map { index in
      Work(
        title: "文献 \(index)",
        publicationYear: 2000 + index % 25,
        dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let snapshots = works.map(LibrarySearchRules.snapshot)
    var options = LibrarySearchOptions()
    options.minimumYearText = "2010"

    let startedAt = CFAbsoluteTimeGetCurrent()
    let matched = snapshots.filter {
      LibrarySearchRules.matches($0, query: "", options: options)
    }
    let sorted = LibrarySortRules.sorted(
      matched,
      by: .dateAdded,
      direction: .descending
    )
    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

    XCTAssertEqual(sorted.count, 3_000)
    XCTAssertLessThan(elapsed, 0.150, "五千篇快照的筛选与排序应在 150 毫秒内完成")
  }

  @MainActor
  func testSearchRanksTitleAboveAbstractAndExplainsMatch() {
    let titleMatch = Work(title: "Minimum Wage Evidence")
    let abstractMatch = Work(
      title: "Employment Study",
      abstractText: "Evidence about the minimum wage"
    )
    let options = LibrarySearchOptions()

    XCTAssertGreaterThan(
      LibrarySearchRules.relevanceScore(
        for: titleMatch,
        query: "minimum wage",
        options: options
      ),
      LibrarySearchRules.relevanceScore(
        for: abstractMatch,
        query: "minimum wage",
        options: options
      )
    )
    XCTAssertEqual(
      LibrarySearchRules.primaryMatchReason(
        for: titleMatch,
        query: "minimum wage",
        options: options
      ),
      "匹配题名"
    )
  }

  func testWorkSelectionRulesSelectAndToggleRows() {
    let first = UUID()
    let second = UUID()

    XCTAssertEqual(
      WorkSelectionRules.selection(
        afterClicking: first,
        current: [],
        commandModified: false
      ),
      [first]
    )
    XCTAssertEqual(
      WorkSelectionRules.selection(
        afterClicking: second,
        current: [first],
        commandModified: false
      ),
      [second]
    )
    XCTAssertEqual(
      WorkSelectionRules.selection(
        afterClicking: second,
        current: [first],
        commandModified: true
      ),
      [first, second]
    )
    XCTAssertEqual(
      WorkSelectionRules.selection(
        afterClicking: first,
        current: [first, second],
        commandModified: true
      ),
      [second]
    )
  }

  func testProjectPriorityUsesDistinctMarkers() {
    XCTAssertEqual(ProjectWorkPriority.one.marker, "❗️")
    XCTAssertEqual(ProjectWorkPriority.two.marker, "‼️")
    XCTAssertEqual(ProjectWorkPriority.three.marker, "🚩")
    XCTAssertEqual(ProjectWorkPriority.completed.marker, "✅")
    XCTAssertEqual(ProjectWorkPriority.menuOrder.last, .completed)
    XCTAssertLessThan(ProjectWorkPriority.completed.sortRank, ProjectWorkPriority.none.sortRank)
    XCTAssertEqual(ProjectWorkPriority.merged(.completed, .three), .completed)
  }

  @MainActor
  func testOrphanTagsAreDeletedButLinkedTagsRemain() throws {
    let schema = Schema([
      Work.self,
      FileVersion.self,
      Category.self,
      Tag.self,
      PersonalMark.self,
      ReadingProject.self,
      AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let linked = Tag(name: "linked")
    let orphan = Tag(name: "orphan")
    let work = Work(title: "测试文献", tags: [linked])
    container.mainContext.insert(linked)
    container.mainContext.insert(orphan)
    container.mainContext.insert(work)
    try container.mainContext.save()

    XCTAssertEqual(try TagMaintenance.deleteOrphans(modelContext: container.mainContext), 1)
    try container.mainContext.save()

    XCTAssertEqual(
      try container.mainContext.fetch(FetchDescriptor<Tag>()).map(\.name),
      ["linked"]
    )
  }
}
