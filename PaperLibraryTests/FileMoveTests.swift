import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testNameCollisionCreatesNumberedArticleFolder() async throws {
    let source = temporaryRoot.appending(path: "paper.pdf")
    try makePDF(at: source, title: "同名论文", author: nil, year: 2025)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()

    let first = try await actor.importPDF(from: source, to: library)
    let second = try await actor.importPDF(from: source, to: library)

    XCTAssertNotEqual(first.relativePath, second.relativePath)
    XCTAssertEqual(
      URL(fileURLWithPath: second.relativePath).deletingLastPathComponent().lastPathComponent,
      "paper (2)"
    )
    XCTAssertTrue(second.relativePath.hasSuffix("paper.pdf"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: first.relativePath).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: second.relativePath).path))
  }

  func testRelocationCanBeRolledBack() async throws {
    let source = temporaryRoot.appending(path: "relocate.pdf")
    try makePDF(at: source, title: "归档测试", author: "Jane Doe", year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)
    let request = FileRelocationRequest(
      fileVersionID: UUID(),
      sourceRelativePath: imported.relativePath,
      categoryFolder: "Labor",
      yearFolder: "2024",
      preferredFilename: "Doe - 2024 - Archive Test.pdf"
    )

    let moves = try await actor.relocateFiles([request], in: library)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: imported.relativePath).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: library.appending(path: moves.relocations[0].destinationRelativePath).path))

    try await actor.rollbackRelocations(moves, in: library)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: imported.relativePath).path))
  }

  func testArticleFolderMoveCarriesRelatedFilesAndRollsBack() async throws {
    let source = temporaryRoot.appending(path: "一篇很长名称的论文原稿.pdf")
    try makePDF(at: source, title: "文章目录移动测试", author: "张三", year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)
    let originalPDF = library.appending(path: imported.relativePath)
    let originalDirectory = originalPDF.deletingLastPathComponent()
    let relatedFile = originalDirectory.appending(path: "补充数据与说明.csv")
    let relatedDirectory = originalDirectory.appending(path: "其他版本", directoryHint: .isDirectory)
    try Data("数据".utf8).write(to: relatedFile)
    try FileManager.default.createDirectory(at: relatedDirectory, withIntermediateDirectories: true)
    try Data("旧版本".utf8).write(to: relatedDirectory.appending(path: "初稿说明.txt"))

    let batch = try await actor.relocateArticles(
      [
        ArticleRelocationRequest(
          workID: UUID(),
          files: [
            ArticleFileRelocationRequest(
              fileVersionID: UUID(),
              sourceRelativePath: imported.relativePath,
              preferredFilename: "张三 - 2024 - 文章目录移动测试.pdf"
            )
          ],
          categoryFolder: "Labor",
          yearFolder: "2024",
          preferredFolderName: "张三 - 2024 - 文章目录移动测试"
        )
      ], in: library)
    let destinationPath = try XCTUnwrap(batch.fileDestinations.first?.destinationRelativePath)
    let destinationDirectory = library.appending(path: destinationPath).deletingLastPathComponent()

    XCTAssertEqual(destinationDirectory.lastPathComponent, "张三 - 2024 - 文章目录移动测试")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: destinationDirectory.appending(path: "补充数据与说明.csv").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: destinationDirectory.appending(path: "其他版本/初稿说明.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: originalDirectory.path))

    try await actor.rollbackArticleRelocations(batch, in: library)

    XCTAssertTrue(FileManager.default.fileExists(atPath: originalPDF.path))
    XCTAssertEqual(try Data(contentsOf: relatedFile), Data("数据".utf8))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: relatedDirectory.appending(path: "初稿说明.txt").path))
  }

  func testFlatArticleMigratesPDFNotesAndAssetsIntoOneFolder() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let flatPDF = library.appending(path: "Labor/2023/旧下载名称.pdf")
    try FileManager.default.createDirectory(
      at: flatPDF.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makePDF(at: flatPDF, title: "旧资料迁移", author: "李四", year: 2023)
    let regularNote = LiteratureCompanionPaths.noteURL(for: flatPDF, kind: .regular)
    let regularAssets = LiteratureCompanionPaths.assetsURL(for: flatPDF, kind: .regular)
    let studyNote = LiteratureCompanionPaths.noteURL(for: flatPDF, kind: .study)
    let studyAssets = LiteratureCompanionPaths.assetsURL(for: flatPDF, kind: .study)
    try Data("普通笔记".utf8).write(to: regularNote)
    try FileManager.default.createDirectory(at: regularAssets, withIntermediateDirectories: true)
    try Data("精读笔记".utf8).write(to: studyNote)
    try FileManager.default.createDirectory(at: studyAssets, withIntermediateDirectories: true)

    let actor = LibraryFileActor()
    let batch = try await actor.relocateArticles(
      [
        ArticleRelocationRequest(
          workID: UUID(),
          files: [
            ArticleFileRelocationRequest(
              fileVersionID: UUID(),
              sourceRelativePath: "Labor/2023/旧下载名称.pdf",
              preferredFilename: "李四 - 2023 - 旧资料迁移.pdf"
            )
          ],
          categoryFolder: "Labor",
          yearFolder: "2023",
          preferredFolderName: "李四 - 2023 - 旧资料迁移"
        )
      ], in: library)
    let destinationPath = try XCTUnwrap(batch.fileDestinations.first?.destinationRelativePath)
    let destinationPDF = library.appending(path: destinationPath)

    XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPDF.path))
    for companion in LiteratureCompanionPaths.allURLs(for: destinationPDF) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path), companion.path)
    }
    XCTAssertEqual(destinationPath.split(separator: "/").count, 4)
  }

  func testAddingVersionReusesExistingArticleFolderAndRemovesTemporaryFolder() async throws {
    let firstSource = temporaryRoot.appending(path: "first.pdf")
    let secondSource = temporaryRoot.appending(path: "second.pdf")
    try makePDF(at: firstSource, title: "Versioned Paper", author: "Jane Doe", year: 2024)
    try makePDF(at: secondSource, title: "Versioned Paper Revised", author: "Jane Doe", year: 2025)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let firstImport = try await actor.importPDF(from: firstSource, to: library)
    let secondImport = try await actor.importPDF(from: secondSource, to: library)

    let firstID = UUID()
    let initialBatch = try await actor.relocateArticles(
      [
        ArticleRelocationRequest(
          workID: UUID(),
          files: [
            .init(
              fileVersionID: firstID,
              sourceRelativePath: firstImport.relativePath,
              preferredFilename: "Doe - 2024 - Versioned Paper.pdf"
            )
          ],
          categoryFolder: "Labor",
          yearFolder: "2024",
          preferredFolderName: "Doe - 2024 - Versioned Paper"
        )
      ], in: library)
    try await actor.commitArticleRelocations(initialBatch, in: library)
    let firstPath = try XCTUnwrap(initialBatch.fileDestinations.first?.destinationRelativePath)
    let existingFolder = library.appending(path: firstPath).deletingLastPathComponent()
    let temporaryFolder = library.appending(path: secondImport.relativePath)
      .deletingLastPathComponent()
    try Data("保留原名".utf8).write(to: existingFolder.appending(path: "supplement.pdf"))
    try Data("新版附件".utf8).write(to: temporaryFolder.appending(path: "appendix.csv"))

    let category = Category(name: "Labor")
    let firstVersion = FileVersion(
      id: firstID,
      relativePath: firstPath,
      originalFilename: "first.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "published",
      isPreferred: true
    )
    let secondVersion = FileVersion(
      relativePath: secondImport.relativePath,
      originalFilename: "second.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "workingPaper",
      isPreferred: false
    )
    let work = Work(
      title: "Versioned Paper",
      authorsText: "Jane Doe",
      publicationYear: 2024,
      metadataConfirmed: true,
      primaryCategory: category,
      fileVersions: [firstVersion, secondVersion]
    )
    let request = try XCTUnwrap(ArchiveRules.articleRelocationRequest(for: work))

    let batch = try await actor.relocateArticles([request], in: library)
    try await actor.commitArticleRelocations(batch, in: library)

    let destinations = Dictionary(
      uniqueKeysWithValues: batch.fileDestinations.map {
        ($0.fileVersionID, $0.destinationRelativePath)
      })
    let firstDestination = try XCTUnwrap(destinations[firstVersion.id])
    let secondDestination = try XCTUnwrap(destinations[secondVersion.id])
    XCTAssertEqual(
      library.appending(path: firstDestination).deletingLastPathComponent(), existingFolder)
    XCTAssertEqual(
      library.appending(path: secondDestination).deletingLastPathComponent(), existingFolder)
    XCTAssertFalse(existingFolder.lastPathComponent.hasSuffix(" (2)"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: existingFolder.appending(path: "supplement.pdf").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: existingFolder.appending(path: "appendix.csv").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFolder.path))
  }

  func testChangingPrimaryVersionRenamesManagedCompanionsAndKeepsManualFiles() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let oldFolder = library.appending(
      path: "Labor/2022/Doe - 2022 - Working Draft",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
    let draftPDF = oldFolder.appending(path: "Doe - 2022 - Working Draft.pdf")
    let publishedPDF = oldFolder.appending(path: "Doe - 2022 - Working Draft - 正式发表版.pdf")
    try makePDF(at: draftPDF, title: "Working Draft", author: "Jane Doe", year: 2022)
    try makePDF(at: publishedPDF, title: "Published Paper", author: "John Smith", year: 2024)
    for url in LiteratureCompanionPaths.allURLs(for: draftPDF) {
      if url.pathExtension == "assets" {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("初稿图片".utf8).write(to: url.appending(path: "figure.png"))
      } else {
        try Data("初稿笔记".utf8).write(to: url)
      }
    }
    for url in LiteratureCompanionPaths.allURLs(for: publishedPDF) {
      if url.pathExtension == "assets" {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("正式版图片".utf8).write(to: url.appending(path: "figure.png"))
      } else {
        try Data("正式版笔记".utf8).write(to: url)
      }
    }
    try Data("手动补充文件".utf8).write(to: oldFolder.appending(path: "supplement.pdf"))
    try Data("手动说明".utf8).write(to: oldFolder.appending(path: "notes-from-author.md"))

    let draft = FileVersion(
      relativePath: "Labor/2022/Doe - 2022 - Working Draft/Doe - 2022 - Working Draft.pdf",
      originalFilename: "draft.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "workingPaper",
      isPreferred: true
    )
    let published = FileVersion(
      relativePath: "Labor/2022/Doe - 2022 - Working Draft/Doe - 2022 - Working Draft - 正式发表版.pdf",
      originalFilename: "published.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "published",
      isPreferred: false
    )
    let work = Work(
      title: "Working Draft",
      authorsText: "Jane Doe",
      publicationYear: 2022,
      metadataConfirmed: true,
      primaryCategory: Category(name: "Labor"),
      fileVersions: [draft, published]
    )
    let request = try XCTUnwrap(
      ArchiveRules.articleRelocationRequest(
        for: work,
        title: "Published Paper",
        authorsText: "John Smith",
        publicationYear: 2024,
        categoryName: "Labor",
        metadataConfirmed: true,
        preferredVersion: published
      ))

    XCTAssertEqual(
      request.files.first(where: { $0.fileVersionID == published.id })?.preferredFilename,
      "Smith - 2024 - Published Paper.pdf"
    )
    XCTAssertEqual(
      request.files.first(where: { $0.fileVersionID == draft.id })?.preferredFilename,
      "Smith - 2024 - Published Paper - 工作论文.pdf"
    )

    let batch = try await LibraryFileActor().relocateArticles([request], in: library)
    let destinations = Dictionary(
      uniqueKeysWithValues: batch.fileDestinations.map {
        ($0.fileVersionID, $0.destinationRelativePath)
      })
    let primaryPath = try XCTUnwrap(destinations[published.id])
    let alternatePath = try XCTUnwrap(destinations[draft.id])
    let newFolder = library.appending(path: primaryPath).deletingLastPathComponent()
    XCTAssertEqual(newFolder.lastPathComponent, "Smith - 2024 - Published Paper")
    XCTAssertTrue(primaryPath.hasSuffix("/Smith - 2024 - Published Paper.pdf"))
    XCTAssertTrue(alternatePath.hasSuffix("/Smith - 2024 - Published Paper - 工作论文.pdf"))
    for companion in LiteratureCompanionPaths.allURLs(for: library.appending(path: primaryPath)) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path), companion.path)
    }
    for companion in LiteratureCompanionPaths.allURLs(for: library.appending(path: alternatePath)) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path), companion.path)
    }
    XCTAssertEqual(
      try Data(contentsOf: newFolder.appending(path: "supplement.pdf")),
      Data("手动补充文件".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: newFolder.appending(path: "notes-from-author.md")),
      Data("手动说明".utf8)
    )
  }

  func testMergingArticleFoldersKeepsSameNamedRelatedFiles() async throws {
    let firstSource = temporaryRoot.appending(path: "第一版.pdf")
    let secondSource = temporaryRoot.appending(path: "第二版.pdf")
    try makePDF(at: firstSource, title: "合并测试", author: "王五", year: 2024)
    try makePDF(at: secondSource, title: "合并测试", author: "王五", year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let first = try await actor.importPDF(from: firstSource, to: library)
    let second = try await actor.importPDF(from: secondSource, to: library)
    let firstDirectory = library.appending(path: first.relativePath).deletingLastPathComponent()
    let secondDirectory = library.appending(path: second.relativePath).deletingLastPathComponent()
    try Data("第一份".utf8).write(to: firstDirectory.appending(path: "补充材料.txt"))
    try Data("第二份".utf8).write(to: secondDirectory.appending(path: "补充材料.txt"))

    let firstID = UUID()
    let secondID = UUID()
    let batch = try await actor.relocateArticles(
      [
        ArticleRelocationRequest(
          workID: UUID(),
          files: [
            .init(
              fileVersionID: firstID,
              sourceRelativePath: first.relativePath,
              preferredFilename: "王五 - 2024 - 合并测试 - 初稿.pdf"
            ),
            .init(
              fileVersionID: secondID,
              sourceRelativePath: second.relativePath,
              preferredFilename: "王五 - 2024 - 合并测试 - 发表版.pdf"
            ),
          ],
          categoryFolder: "Labor",
          yearFolder: "2024",
          preferredFolderName: "王五 - 2024 - 合并测试"
        )
      ], in: library)
    let destinations = Dictionary(
      uniqueKeysWithValues: batch.fileDestinations.map {
        ($0.fileVersionID, $0.destinationRelativePath)
      })
    let mergedDirectory =
      library
      .appending(path: try XCTUnwrap(destinations[firstID]))
      .deletingLastPathComponent()

    XCTAssertEqual(
      mergedDirectory,
      library.appending(path: try XCTUnwrap(destinations[secondID])).deletingLastPathComponent()
    )
    let relatedContents = try Set([
      String(contentsOf: mergedDirectory.appending(path: "补充材料.txt"), encoding: .utf8),
      String(contentsOf: mergedDirectory.appending(path: "补充材料 (2).txt"), encoding: .utf8),
    ])
    XCTAssertEqual(relatedContents, Set(["第一份", "第二份"]))

    try await actor.commitArticleRelocations(batch, in: library)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondDirectory.path))
  }

  func testLiteratureNoteUsesPDFNameAndOnlyContainsCenteredItalicTitleHeading() async throws {
    let source = temporaryRoot.appending(path: "note-source.pdf")
    try makePDF(at: source, title: "笔记测试", author: nil, year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)

    let result = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "文章标题",
      in: library
    )

    XCTAssertTrue(result.created)
    XCTAssertEqual(
      result.url,
      library.appending(path: imported.relativePath)
        .deletingPathExtension()
        .appendingPathExtension("md")
    )
    XCTAssertEqual(
      try String(contentsOf: result.url, encoding: .utf8),
      "<h1 style=\"text-align: center; font-style: italic\">文章标题</h1>\n"
    )
  }

  func testExistingLiteratureNoteIsNeverOverwritten() async throws {
    let source = temporaryRoot.appending(path: "existing-note.pdf")
    try makePDF(at: source, title: "现有笔记", author: nil, year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)
    let first = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "原标题",
      in: library
    )
    let userContents = "# 原标题\n\n我的笔记\n"
    try Data(userContents.utf8).write(to: first.url)

    let second = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "新标题",
      in: library
    )

    XCTAssertFalse(second.created)
    XCTAssertEqual(try String(contentsOf: second.url, encoding: .utf8), userContents)
  }

  func testBothNotesAndAssetsMoveAndRollBackWithPDF() async throws {
    let source = temporaryRoot.appending(path: "move-note.pdf")
    try makePDF(at: source, title: "移动笔记", author: nil, year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)
    let note = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "移动笔记",
      in: library
    )
    let noteAssets = note.url.deletingPathExtension().appendingPathExtension("assets")
    try FileManager.default.createDirectory(at: noteAssets, withIntermediateDirectories: true)
    let imageData = Data("笔记图片".utf8)
    try imageData.write(to: noteAssets.appending(path: "figure.png"))
    let studyNote = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "移动精读笔记",
      kind: .study,
      in: library
    )
    let studyNoteContents = Data("精读笔记正文".utf8)
    try studyNoteContents.write(to: studyNote.url)
    let studyNoteAssets = LiteratureCompanionPaths.assetsURL(
      for: library.appending(path: imported.relativePath),
      kind: .study
    )
    try FileManager.default.createDirectory(at: studyNoteAssets, withIntermediateDirectories: true)
    let studyImageData = Data("精读笔记图片".utf8)
    try studyImageData.write(to: studyNoteAssets.appending(path: "study-figure.png"))

    let occupiedAssets =
      library
      .appending(path: "Labor/2024", directoryHint: .isDirectory)
      .appending(path: "Moved Note.assets", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: occupiedAssets, withIntermediateDirectories: true)
    let occupiedImage = occupiedAssets.appending(path: "existing.png")
    try Data("已有图片".utf8).write(to: occupiedImage)

    let batch = try await actor.relocateFiles(
      [
        FileRelocationRequest(
          fileVersionID: UUID(),
          sourceRelativePath: imported.relativePath,
          categoryFolder: "Labor",
          yearFolder: "2024",
          preferredFilename: "Moved Note.pdf"
        )
      ], in: library)
    let relocation = try XCTUnwrap(batch.relocations.first)
    let movedNotePath = try XCTUnwrap(relocation.noteDestinationRelativePath)
    let movedAssetsPath = try XCTUnwrap(relocation.noteAssetsDestinationRelativePath)
    let movedStudyNotePath = try XCTUnwrap(relocation.studyNoteDestinationRelativePath)
    let movedStudyAssetsPath = try XCTUnwrap(relocation.studyNoteAssetsDestinationRelativePath)

    XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: movedNotePath).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: noteAssets.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: movedAssetsPath).path))
    XCTAssertEqual(
      try Data(contentsOf: library.appending(path: movedAssetsPath).appending(path: "figure.png")),
      imageData
    )
    XCTAssertTrue(movedAssetsPath.hasSuffix("Moved Note (2).assets"))
    XCTAssertEqual(try Data(contentsOf: occupiedImage), Data("已有图片".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: studyNote.url.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: studyNoteAssets.path))
    XCTAssertTrue(movedStudyNotePath.hasSuffix("Moved Note (2)-精读笔记.md"))
    XCTAssertTrue(movedStudyAssetsPath.hasSuffix("Moved Note (2)-精读笔记.assets"))
    XCTAssertEqual(
      try Data(contentsOf: library.appending(path: movedStudyNotePath)), studyNoteContents)
    XCTAssertEqual(
      try Data(
        contentsOf: library.appending(path: movedStudyAssetsPath).appending(
          path: "study-figure.png")),
      studyImageData
    )

    try await actor.rollbackRelocations(batch, in: library)
    XCTAssertTrue(FileManager.default.fileExists(atPath: note.url.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: movedNotePath).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: noteAssets.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: movedAssetsPath).path))
    XCTAssertEqual(try Data(contentsOf: noteAssets.appending(path: "figure.png")), imageData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: studyNote.url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: studyNoteAssets.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: movedStudyNotePath).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: movedStudyAssetsPath).path))
    XCTAssertEqual(try Data(contentsOf: studyNote.url), studyNoteContents)
    XCTAssertEqual(
      try Data(contentsOf: studyNoteAssets.appending(path: "study-figure.png")), studyImageData)
  }

  func testInterruptedRelocationReturnsToDatabasePath() async throws {
    let source = temporaryRoot.appending(path: "interrupted.pdf")
    try makePDF(at: source, title: "中断测试", author: nil, year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)
    let batch = try await actor.relocateFiles(
      [
        FileRelocationRequest(
          fileVersionID: UUID(),
          sourceRelativePath: imported.relativePath,
          categoryFolder: "Macro",
          yearFolder: "2024",
          preferredFilename: "Moved.pdf"
        )
      ], in: library)

    _ = try await actor.recoverRelocationTransactions(
      knownRelativePaths: [imported.relativePath],
      in: library
    )

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: imported.relativePath).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: library.appending(path: batch.relocations[0].destinationRelativePath).path
      ))
  }

  func testArchiveFilenameRules() {
    let work = Work(
      title: "A Very Important Paper: Evidence / Results",
      authorsText: "Jane Doe; John Smith; Alice Jones",
      publicationYear: 2024,
      metadataConfirmed: true
    )
    let file = FileVersion(
      relativePath: "old.pdf",
      originalFilename: "old.pdf",
      pageCount: 1,
      fileSize: 1
    )

    XCTAssertEqual(
      ArchiveRules.filename(for: work, version: file, includeVersionSuffix: false),
      "Doe et al. - 2024 - A Very Important Paper Evidence Results.pdf"
    )
  }

  func testArchiveFilenameDoesNotUseFolderLengthLimit() {
    let work = Work(
      title:
        "Imperfect Competition, Compensating Differentials, and Rent Sharing in the US Labor Market",
      authorsText: "Thibaut Lamadon; Magne Mogstad; Bradley Setzler",
      publicationYear: 2022,
      metadataSource: "crossref"
    )
    let file = FileVersion(
      relativePath: "old.pdf",
      originalFilename: "old.pdf",
      pageCount: 1,
      fileSize: 1
    )

    XCTAssertEqual(
      ArchiveRules.filename(for: work, version: file, includeVersionSuffix: false),
      "Lamadon et al. - 2022 - Imperfect Competition, Compensating Differentials, and Rent Sharing in the US Labor Market.pdf"
    )
  }

  func testArchiveFilenameFitsFilesystemUTF8ByteLimit() {
    let work = Work(
      title: String(repeating: "经济学📚", count: 100),
      authorsText: "张三",
      publicationYear: 2026,
      metadataConfirmed: true
    )
    let file = FileVersion(
      relativePath: "old.pdf",
      originalFilename: "old.pdf",
      pageCount: 1,
      fileSize: 1
    )

    let filename = ArchiveRules.filename(for: work, version: file, includeVersionSuffix: false)

    XCTAssertTrue(filename.hasSuffix(".pdf"))
    XCTAssertLessThanOrEqual(filename.utf8.count, 244)
  }

  func testArticleRelocationUsesNoSuffixForPrimaryAndLabelsUnknownAlternate() throws {
    let primary = FileVersion(
      relativePath: "primary.pdf",
      originalFilename: "primary.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "published",
      isPreferred: true
    )
    let alternate = FileVersion(
      relativePath: "alternate.pdf",
      originalFilename: "alternate.pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "unknown",
      isPreferred: false
    )
    let work = Work(
      title: "Version Labels",
      authorsText: "Jane Doe",
      publicationYear: 2024,
      metadataConfirmed: true,
      fileVersions: [primary, alternate]
    )

    let request = try XCTUnwrap(ArchiveRules.articleRelocationRequest(for: work))
    XCTAssertEqual(
      request.files.first(where: { $0.fileVersionID == primary.id })?.preferredFilename,
      "Doe - 2024 - Version Labels.pdf"
    )
    XCTAssertEqual(
      request.files.first(where: { $0.fileVersionID == alternate.id })?.preferredFilename,
      "Doe - 2024 - Version Labels - 其他版本.pdf"
    )
    XCTAssertEqual(
      ArchiveRules.filename(
        title: "尚未核对",
        authorsText: "",
        publicationYear: nil,
        metadataConfirmed: false,
        version: alternate,
        includeVersionSuffix: true
      ),
      "alternate - 其他版本.pdf"
    )
    let longAlternate = FileVersion(
      relativePath: "long.pdf",
      originalFilename: String(repeating: "长文件名", count: 100) + ".pdf",
      pageCount: 1,
      fileSize: 1,
      versionTypeRawValue: "workingPaper",
      isPreferred: false
    )
    let longFilename = ArchiveRules.filename(
      title: String(repeating: "长标题", count: 100),
      authorsText: "Jane Doe",
      publicationYear: 2024,
      metadataConfirmed: true,
      version: longAlternate,
      includeVersionSuffix: true
    )
    XCTAssertTrue(longFilename.hasSuffix(" - 工作论文.pdf"))
    XCTAssertLessThanOrEqual(longFilename.utf8.count, 239)
  }

  func testImportRejectsCategorySymlinkOutsideLibrary() async throws {
    let source = temporaryRoot.appending(path: "source.pdf")
    try makePDF(at: source, title: "路径安全测试", author: nil, year: 2026)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    let outside = temporaryRoot.appending(path: "Outside", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let category = library.appending(path: "Uncategorized", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: category)
    try FileManager.default.createSymbolicLink(at: category, withDestinationURL: outside)

    do {
      _ = try await LibraryFileActor().importPDF(from: source, to: library)
      XCTFail("不应允许通过符号链接把 PDF 写到资料库之外")
    } catch PDFImportError.invalidTransactionPath {
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: outside.appending(path: "Unknown Year/source.pdf").path))
    }
  }

  @MainActor
  func testArchiveMaintenanceRepairsFilenameAndDatabasePath() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let oldRelativePath = "Labor/2022/old-download-name.pdf"
    let oldURL = library.appending(path: oldRelativePath)
    try FileManager.default.createDirectory(
      at: oldURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try makePDF(at: oldURL, title: "Archive Test", author: "Jane Doe", year: 2022)

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
    let category = Category(name: "Labor")
    let version = FileVersion(
      relativePath: oldRelativePath,
      originalFilename: "old-download-name.pdf",
      pageCount: 1,
      fileSize: 1
    )
    let work = Work(
      title: "Archive Test",
      authorsText: "Jane Doe; John Smith; Alice Jones",
      publicationYear: 2022,
      metadataConfirmed: false,
      metadataSource: "crossref",
      primaryCategory: category,
      fileVersions: [version]
    )
    container.mainContext.insert(category)
    container.mainContext.insert(work)
    try container.mainContext.save()

    try await ArchiveMaintenance.normalizeStructuredFilenames(
      works: [work],
      rootURL: library,
      modelContext: container.mainContext
    )

    let expected =
      "Labor/2022/Doe et al. - 2022 - Archive Test/Doe et al. - 2022 - Archive Test.pdf"
    XCTAssertEqual(version.relativePath, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: expected).path))
  }

  func testDuplicateLongFilenameStaysWithinFilesystemLimit() async throws {
    let filename = String(repeating: "a", count: 251) + ".pdf"
    let source = temporaryRoot.appending(path: filename)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try makePDF(at: source, title: "超长文件名", author: nil, year: 2024)
    try LibraryLayout.ensureExists(at: library)

    let actor = LibraryFileActor()
    _ = try await actor.importPDF(from: source, to: library)
    let duplicate = try await actor.importPDF(from: source, to: library)

    XCTAssertLessThanOrEqual(
      duplicate.relativePath.split(separator: "/").last?.utf8.count ?? .max, 255)
    let duplicateURL = library.appending(path: duplicate.relativePath)
    for companionURL in LiteratureCompanionPaths.allURLs(for: duplicateURL) {
      XCTAssertLessThanOrEqual(companionURL.lastPathComponent.utf8.count, 255)
    }
    let studyNote = try await actor.createLiteratureNote(
      forPDFAt: duplicate.relativePath,
      title: "超长文件名",
      kind: .study,
      in: library
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: studyNote.url.path))
  }

  func testFailedRelocationKeepsJournalForLaterRecovery() async throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let source = library.appending(path: "Uncategorized/paper.pdf")
    try makePDF(at: source, title: "回滚测试", author: nil, year: 2024)
    try Data("笔记".utf8).write(to: source.deletingPathExtension().appendingPathExtension("md"))

    let actor = LibraryFileActor(fileManager: FailingRelocationFileManager())
    let request = FileRelocationRequest(
      fileVersionID: UUID(),
      sourceRelativePath: "Uncategorized/paper.pdf",
      categoryFolder: "Labor",
      yearFolder: "2024",
      preferredFilename: "renamed.pdf"
    )

    do {
      _ = try await actor.relocateFiles([request], in: library)
      XCTFail("应当模拟文件移动失败")
    } catch {
      // 预期结果：恢复日志由后续启动流程处理。
    }

    let journals = try FileManager.default.contentsOfDirectory(
      atPath: library.appending(path: ".paperlib/operations").path
    )
    XCTAssertFalse(journals.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: "Labor/2024/renamed.pdf").path)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: "Uncategorized/paper.md").path)
    )
  }

  func testLibraryPathSafetyRejectsTraversalAndAbsolutePaths() throws {
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)

    XCTAssertThrowsError(try LibraryPathSafety.url(for: "../outside.pdf", inside: library))
    XCTAssertThrowsError(try LibraryPathSafety.url(for: "/tmp/outside.pdf", inside: library))
    XCTAssertNoThrow(try LibraryPathSafety.url(for: "Uncategorized/paper.pdf", inside: library))
  }

  func testDraggedPDFNameDoesNotRepeatExtension() {
    let url = URL(fileURLWithPath: "/tmp/College Textbooks.pdf")
    XCTAssertEqual(PDFDragExportRules.suggestedFilenameBase(for: url), "College Textbooks")
  }

  func testDraggedPDFProvidesStandardFileURLForWebUploads() {
    let provider = WorkRowDragProvider.make(
      workID: UUID(),
      pdfURL: URL(fileURLWithPath: "/tmp/College Textbooks.pdf")
    )
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier))
  }

}
