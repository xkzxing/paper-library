import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

final class ImportTests: XCTestCase {
  var temporaryRoot: URL!

  override func setUpWithError() throws {
    temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: "PaperLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryRoot {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
  }

  func testWorkRowDragIsNotEligibleForLibraryFileImport() {
    let pdfURL = temporaryRoot.appending(path: "dragged-paper.pdf")
    let provider = WorkRowDragProvider.make(workID: UUID(), pdfURL: pdfURL)

    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(WorkRowDragProvider.typeIdentifier))
    XCTAssertTrue(LibraryFileDropRules.externalURLProviders(from: [provider]).isEmpty)
  }

  func testSuccessfulImport() async throws {
    let source = temporaryRoot.appending(path: "source.pdf")
    try makePDF(at: source, title: "测试论文", author: "张三", year: 2024)
    let sourceMetadata = try PDFMetadataExtractor.extract(from: source)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)

    let result = try await LibraryFileActor().importPDF(from: source, to: library)

    XCTAssertEqual(result.title, "测试论文")
    XCTAssertEqual(result.authorsText, "张三")
    XCTAssertEqual(result.publicationYear, sourceMetadata.publicationYear)
    XCTAssertEqual(result.fileMetadataYear, sourceMetadata.fileMetadataYear)
    XCTAssertEqual(result.pageCount, 1)
    XCTAssertTrue(result.relativePath.contains("Uncategorized/Unknown Year/"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: result.relativePath).path))
  }

  func testSourceFileRemainsUnchanged() async throws {
    let source = temporaryRoot.appending(path: "immutable-source.pdf")
    try makePDF(at: source, title: "源文件测试", author: nil, year: 2023)
    let bytesBefore = try Data(contentsOf: source)
    let attributesBefore = try FileManager.default.attributesOfItem(atPath: source.path)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)

    _ = try await LibraryFileActor().importPDF(from: source, to: library)

    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: source), bytesBefore)
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: source.path)
    XCTAssertEqual(attributesAfter[.size] as? NSNumber, attributesBefore[.size] as? NSNumber)
  }

  func testCommittedImportRemovesTransactionJournal() async throws {
    let source = temporaryRoot.appending(path: "commit.pdf")
    try makePDF(at: source, title: "提交测试", author: nil, year: 2022)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()

    let result = try await actor.importPDF(from: source, to: library)
    let journal = library.appending(
      path: ".paperlib/imports/\(result.transactionID.uuidString).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

    try await actor.commitImport(transactionID: result.transactionID, in: library)

    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.appending(path: result.relativePath).path))
  }

  func testRollbackRemovesCopiedFileButKeepsSource() async throws {
    let source = temporaryRoot.appending(path: "rollback.pdf")
    try makePDF(at: source, title: "回滚测试", author: nil, year: 2021)
    let sourceData = try Data(contentsOf: source)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()

    let result = try await actor.importPDF(from: source, to: library)
    let articleDirectory = library.appending(path: result.relativePath).deletingLastPathComponent()
    try await actor.rollbackImport(result, in: library)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: result.relativePath).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: articleDirectory.path))
    XCTAssertEqual(try Data(contentsOf: source), sourceData)
  }

  func testMovedImportCanBeRecovered() async throws {
    let source = temporaryRoot.appending(path: "recover.pdf")
    try makePDF(at: source, title: "恢复测试", author: nil, year: 2020)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()

    let imported = try await actor.importPDF(from: source, to: library)
    let scan = try await actor.scanRecoverableImports(in: library)

    XCTAssertEqual(scan.warnings, [])
    XCTAssertEqual(scan.recoverableItems, [imported])
  }

  func testLibraryIdentifierPersistsAndRejectsAnotherLibrary() throws {
    let firstRoot = temporaryRoot.appending(path: "First", directoryHint: .isDirectory)
    let secondRoot = temporaryRoot.appending(path: "Second", directoryHint: .isDirectory)
    let first = try LibraryLayout.openOrCreate(at: firstRoot, expectedID: nil)
    let reopened = try LibraryLayout.openOrCreate(at: firstRoot, expectedID: first.id)
    let second = try LibraryLayout.openOrCreate(at: secondRoot, expectedID: nil)

    XCTAssertEqual(first, reopened)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertThrowsError(try LibraryLayout.openOrCreate(at: secondRoot, expectedID: first.id))
  }

  func testImportingOneHundredPDFsDoesNotLoseFiles() async throws {
    let sources = temporaryRoot.appending(path: "Sources", directoryHint: .isDirectory)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    var importedPaths: [String] = []

    for index in 0..<100 {
      let source = sources.appending(path: "paper-\(index).pdf")
      try makePDF(at: source, title: "论文 \(index)", author: nil, year: 2024)
      let result = try await actor.importPDF(from: source, to: library)
      importedPaths.append(result.relativePath)
    }

    XCTAssertEqual(Set(importedPaths).count, 100)
    XCTAssertTrue(
      importedPaths.allSatisfy {
        FileManager.default.fileExists(atPath: library.appending(path: $0).path)
      })
    XCTAssertTrue(
      (0..<100).allSatisfy {
        FileManager.default.fileExists(atPath: sources.appending(path: "paper-\($0).pdf").path)
      })
  }

  func makePDF(
    at url: URL,
    title: String,
    author: String?,
    year: Int,
    pageCount: Int = 1
  ) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
    var metadata: [CFString: Any] = [
      kCGPDFContextTitle: title,
      kCGPDFContextSubject: "测试年份 \(year)",
    ]
    if let author {
      metadata[kCGPDFContextAuthor] = author
    }

    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary)
    else {
      XCTFail("无法写入测试 PDF")
      return
    }

    for _ in 0..<pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(mediaBox)
      context.endPDFPage()
    }
    context.closePDF()
  }

  func makePaginatedPDF(
    at url: URL,
    printedStart: Int,
    pageCount: Int
  ) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      XCTFail("无法写入带页码的测试 PDF")
      return
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for index in 0..<pageCount {
      context.beginPDFPage(nil)
      let text = "\(printedStart + index) TEST JOURNAL HEADER" as CFString
      let attributed = CFAttributedStringCreate(
        nil,
        text,
        [kCTFontAttributeName: font] as CFDictionary
      )!
      let line = CTLineCreateWithAttributedString(attributed)
      context.textPosition = CGPoint(x: 20, y: 370)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  func importedPDF(sha256: String, doi: String?) -> ImportedPDF {
    ImportedPDF(
      transactionID: UUID(),
      relativePath: "Uncategorized/Unknown Year/test.pdf",
      originalFilename: "test.pdf",
      title: "Test Paper",
      authorsText: "Jane Doe",
      publicationYear: 2024,
      fileMetadataYear: 2024,
      pageCount: 10,
      fileSize: 100,
      sha256: sha256,
      doi: doi,
      nberNumber: nil,
      ssrnID: nil,
      arxivID: nil,
      repecHandle: nil,
      textFingerprint: nil,
      hasAnnotations: false,
      suggestedVersionType: "unknown"
    )
  }
}

final class FailingRelocationFileManager: FileManager, @unchecked Sendable {
  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.lastPathComponent == "paper.md"
      || (srcURL.lastPathComponent == "renamed.pdf" && dstURL.lastPathComponent == "paper.pdf")
    {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}

final class BibTeXURLProtocolStub: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: BibTeXRemoteError.invalidResponse)
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class OpenAlexURLProtocolStub: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
