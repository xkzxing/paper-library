import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testManifestRoundTrip() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    let descriptor = try LibraryLayout.openOrCreate(at: library, expectedID: nil)
    let manifest = LibraryManifest(
      schemaVersion: LibraryManifest.currentSchemaVersion,
      libraryID: descriptor.id,
      exportedAt: .now,
      works: [],
      categories: [],
      tags: [],
      projects: []
    )
    let store = ManifestStore()

    try await store.write(manifest, to: library)
    let restored = try await store.read(from: library)

    XCTAssertEqual(restored?.libraryID, descriptor.id)
    XCTAssertEqual(restored?.works.count, 0)
  }

  func testManifestFallsBackToNewestValidBackup() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    let descriptor = try LibraryLayout.openOrCreate(at: library, expectedID: nil)
    let store = ManifestStore()
    let first = LibraryManifest(
      schemaVersion: LibraryManifest.currentSchemaVersion,
      libraryID: descriptor.id,
      exportedAt: Date(timeIntervalSince1970: 1),
      works: [], categories: [], tags: [], projects: []
    )
    let second = LibraryManifest(
      schemaVersion: LibraryManifest.currentSchemaVersion,
      libraryID: descriptor.id,
      exportedAt: Date(timeIntervalSince1970: 2),
      works: [], categories: [], tags: [], projects: []
    )
    try await store.write(first, to: library)
    try await store.write(second, to: library)
    let primary = try LibraryPathSafety.url(
      for: ".paperlib/manifest.json",
      inside: library
    )
    try Data("not-json".utf8).write(to: primary, options: .atomic)

    let restored = try await store.read(
      from: library,
      expectedLibraryID: descriptor.id
    )

    XCTAssertEqual(restored?.exportedAt, first.exportedAt)
  }

  func testManifestPrunesHiddenBackupsToTen() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    let descriptor = try LibraryLayout.openOrCreate(at: library, expectedID: nil)
    let backups = library.appending(path: ".paperlib/backups", directoryHint: .isDirectory)
    for index in 0..<12 {
      var url = backups.appending(path: "manifest-old-\(index).json")
      try Data("{}".utf8).write(to: url)
      var values = URLResourceValues()
      values.isHidden = true
      try url.setResourceValues(values)
    }
    let manifest = LibraryManifest(
      schemaVersion: LibraryManifest.currentSchemaVersion,
      libraryID: descriptor.id,
      exportedAt: .now,
      works: [],
      categories: [],
      tags: [],
      projects: []
    )

    try await ManifestStore().write(manifest, to: library)

    let files = try FileManager.default.contentsOfDirectory(
      at: backups,
      includingPropertiesForKeys: nil,
      options: []
    ).filter { $0.lastPathComponent.hasPrefix("manifest-") }
    XCTAssertLessThanOrEqual(files.count, 10)
  }

  @MainActor
  func testManifestRestoresEmptyCatalogEntriesAndRelationships() async throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let source = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let emptyCategory = Category(name: "Health", sortOrder: 3, colorHex: "#123456")
    let linkedCategory = Category(name: "Labor", sortOrder: 2, colorHex: "#654321")
    let emptyTag = Tag(name: "尚未使用", colorHex: "#AABBCC")
    let linkedTag = Tag(name: "Minimum Wage", colorHex: "#DDEEFF")
    let personalMark = PersonalMark(name: "好文章", colorHex: "#B65C75", sortOrder: 0)
    let emptyProject = ReadingProject(name: "待读项目")
    let linkedProject = ReadingProject(name: "论文项目")
    let lastOpenedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let openAlexLookupAt = Date(timeIntervalSince1970: 1_700_000_100)
    let work = Work(
      title: "恢复测试",
      lastOpenedAt: lastOpenedAt,
      openAlexJournalMetricsJSON: #"{"sourceID":"S1"}"#,
      openAlexJournalLookupAttemptedAt: openAlexLookupAt,
      primaryCategory: linkedCategory,
      tags: [linkedTag],
      personalMarks: [personalMark],
      projects: [linkedProject]
    )
    let version = FileVersion(
      relativePath: "Labor/2024/恢复测试/恢复测试.pdf",
      originalFilename: "working-paper.pdf",
      pageCount: 12,
      fileSize: 100,
      versionTypeRawValue: "published",
      bibliographicTitle: "正式发表标题",
      bibliographicAuthorsText: "Jane Doe; John Smith",
      bibliographicYear: 2024,
      bibliographicJournal: "Journal of Tests",
      bibliographicDOI: "10.1234/version",
      bibliographicMetadataSource: "crossref",
      bibliographicMetadataConfirmed: true
    )
    let analysis = AIAnalysis(
      modelName: "gemini-test",
      promptVersion: "test-v1",
      status: "completed",
      analyzedFileVersionID: version.id
    )
    work.fileVersions.append(version)
    work.analyses.append(analysis)
    linkedProject.setPriority(.three, for: work.id)
    linkedProject.sortFieldRawValue = LibrarySortField.lastOpened.rawValue
    linkedProject.sortDirectionRawValue = LibrarySortDirection.ascending.rawValue
    [emptyCategory, linkedCategory].forEach(source.mainContext.insert)
    [emptyTag, linkedTag].forEach(source.mainContext.insert)
    source.mainContext.insert(personalMark)
    [emptyProject, linkedProject].forEach(source.mainContext.insert)
    source.mainContext.insert(work)
    try source.mainContext.save()

    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    let descriptor = try LibraryLayout.openOrCreate(at: library, expectedID: nil)
    let exporter = ManifestCoordinator()
    await exporter.export(
      libraryID: descriptor.id,
      rootURL: library,
      works: [work],
      categories: [emptyCategory, linkedCategory],
      tags: [emptyTag, linkedTag],
      projects: [emptyProject, linkedProject],
      personalMarks: [personalMark]
    )
    XCTAssertNil(exporter.errorText)

    let destination = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let restorer = ManifestCoordinator()
    _ = await restorer.restoreIfNeeded(
      libraryID: descriptor.id,
      rootURL: library,
      modelContext: destination.mainContext
    )

    XCTAssertNil(restorer.errorText)
    let restoredCategories = try destination.mainContext.fetch(
      FetchDescriptor<PaperLibrary.Category>()
    )
    let restoredTags = try destination.mainContext.fetch(FetchDescriptor<Tag>())
    let restoredPersonalMarks = try destination.mainContext.fetch(FetchDescriptor<PersonalMark>())
    let restoredProjects = try destination.mainContext.fetch(
      FetchDescriptor<ReadingProject>()
    )
    let restoredWork = try XCTUnwrap(
      destination.mainContext.fetch(FetchDescriptor<Work>()).first
    )
    XCTAssertEqual(Set(restoredCategories.map(\.name)), ["Health", "Labor"])
    XCTAssertEqual(Set(restoredTags.map(\.name)), ["尚未使用", "Minimum Wage"])
    XCTAssertEqual(restoredPersonalMarks.map(\.name), ["好文章"])
    XCTAssertEqual(Set(restoredProjects.map(\.name)), ["待读项目", "论文项目"])
    XCTAssertEqual(restoredWork.primaryCategory?.name, "Labor")
    XCTAssertEqual(restoredWork.tags.map(\.name), ["Minimum Wage"])
    XCTAssertEqual(restoredWork.personalMarks.map(\.name), ["好文章"])
    XCTAssertEqual(restoredWork.projects.map(\.name), ["论文项目"])
    XCTAssertEqual(restoredWork.lastOpenedAt, lastOpenedAt)
    XCTAssertEqual(restoredWork.openAlexJournalMetricsJSON, #"{"sourceID":"S1"}"#)
    XCTAssertEqual(restoredWork.openAlexJournalLookupAttemptedAt, openAlexLookupAt)
    let restoredVersion = try XCTUnwrap(restoredWork.fileVersions.first)
    XCTAssertEqual(restoredVersion.bibliographicTitle, "正式发表标题")
    XCTAssertEqual(restoredVersion.bibliographicAuthorsText, "Jane Doe; John Smith")
    XCTAssertEqual(restoredVersion.bibliographicYear, 2024)
    XCTAssertEqual(restoredVersion.bibliographicJournal, "Journal of Tests")
    XCTAssertEqual(restoredVersion.bibliographicDOI, "10.1234/version")
    XCTAssertEqual(restoredVersion.bibliographicMetadataSource, "crossref")
    XCTAssertTrue(restoredVersion.bibliographicMetadataConfirmed)
    XCTAssertEqual(restoredWork.analyses.first?.analyzedFileVersionID, restoredVersion.id)
    let restoredLinkedProject = try XCTUnwrap(
      restoredProjects.first { $0.name == "论文项目" }
    )
    XCTAssertEqual(restoredLinkedProject.priority(for: restoredWork.id), .three)
    XCTAssertEqual(restoredLinkedProject.sortFieldRawValue, LibrarySortField.lastOpened.rawValue)
    XCTAssertEqual(
      restoredLinkedProject.sortDirectionRawValue, LibrarySortDirection.ascending.rawValue)
  }

  func testDatabaseRecoveryMovesStoreAndSidecarsWithoutDeletingThem() throws {
    let store = temporaryRoot.appending(path: "default.store")
    let sharedMemory = URL(fileURLWithPath: store.path + "-shm")
    let journal = URL(fileURLWithPath: store.path + "-wal")
    try Data("store".utf8).write(to: store)
    try Data("shm".utf8).write(to: sharedMemory)
    try Data("wal".utf8).write(to: journal)

    let quarantine = try DatabaseStoreRecovery.quarantineStore(at: store)

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sharedMemory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appending(path: store.lastPathComponent)),
      Data("store".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appending(path: sharedMemory.lastPathComponent)),
      Data("shm".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: quarantine.appending(path: journal.lastPathComponent)),
      Data("wal".utf8)
    )
  }
}
