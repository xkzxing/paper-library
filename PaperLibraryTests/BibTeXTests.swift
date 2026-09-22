import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testBibTeXCitationKeyUsesAllSurnameInitialsAndFirstContentWord() throws {
    let work = Work(
      title: "The Effects of Trade",
      authorsText: "José Álvarez; Jane Doe; Alice Jones",
      publicationYear: 2024,
      journal: "Economic Review",
      documentTypeRawValue: "article",
      metadataConfirmed: true
    )

    let entry = try BibTeXExporter.makeEntry(for: work)
    let repeatedEntry = try BibTeXExporter.makeEntry(for: work)

    XCTAssertEqual(entry.citationKey, "AlvarezDJ2024Effects")
    XCTAssertEqual(entry.citationKey, repeatedEntry.citationKey)
  }

  func testBibTeXExportEscapesFieldsAndNormalizesDOI() throws {
    let work = Work(
      id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
      title: "The Effects of R&D_100% on {Output}",
      authorsText: "José Álvarez; Jane Doe & Sons",
      publicationYear: 2024,
      journal: "Journal of A&B",
      doi: "https://doi.org/10.1234/ABC.567).",
      nberNumber: "1234",
      arxivID: "2401.01234",
      documentTypeRawValue: "article",
      metadataConfirmed: true
    )

    let entry = try BibTeXExporter.makeEntry(for: work)

    XCTAssertTrue(entry.content.hasPrefix("@article{\(entry.citationKey),\n"))
    XCTAssertTrue(entry.content.contains("author = {José Álvarez and Jane Doe \\& Sons}"))
    XCTAssertTrue(
      entry.content.contains(
        "title = {{The Effects of R\\&D\\_100\\% on \\{Output\\}}}"
      ))
    XCTAssertTrue(entry.content.contains("journal = {Journal of A\\&B}"))
    XCTAssertTrue(entry.content.contains("doi = {10.1234/abc.567}"))
    XCTAssertTrue(entry.content.contains("note = {NBER 1234; arXiv 2401.01234}"))
    XCTAssertTrue(entry.content.hasSuffix("\n}\n"))
  }

  func testBibTeXExportRejectsUnreviewedOrInvalidMetadata() throws {
    let work = Work(
      title: "Verified Title",
      authorsText: "Jane Doe",
      publicationYear: 2024,
      doi: "10.1234/valid"
    )

    XCTAssertThrowsError(try BibTeXExporter.makeEntry(for: work)) {
      XCTAssertEqual($0 as? BibTeXExportError, .metadataNotConfirmed)
    }

    work.metadataConfirmed = true
    work.needsReview = true
    XCTAssertThrowsError(try BibTeXExporter.makeEntry(for: work)) {
      XCTAssertEqual($0 as? BibTeXExportError, .needsReview)
    }

    work.needsReview = false
    work.doi = "not-a-doi"
    XCTAssertThrowsError(try BibTeXExporter.makeEntry(for: work)) {
      XCTAssertEqual($0 as? BibTeXExportError, .invalidDOI)
    }
  }

  func testPageNumberWarningDoesNotRequireReviewOrBlockBibTeXExport() throws {
    let work = Work(
      title: "Verified Title",
      authorsText: "Jane Doe",
      publicationYear: 2024,
      doi: "10.1234/valid",
      metadataConfirmed: true,
      needsReview: true,
      metadataConflictNote: "AI 返回了无法定位到 PDF 的引用页码；分析结果已保留，请复核引用页码。"
    )

    XCTAssertTrue(WorkReviewRules.hasPageNumberWarning(work))
    XCTAssertFalse(WorkReviewRules.requiresReview(work))
    XCTAssertNoThrow(try BibTeXExporter.makeEntry(for: work))

    WorkReviewRules.addPageNumberWarning(to: work)
    XCTAssertEqual(work.metadataConflictNote, WorkReviewRules.pageNumberWarning)
  }

  func testOnlineBibTeXUsesShortKeyAndMatchesEquivalentLocalMetadata() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BibTeXURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    BibTeXURLProtocolStub.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-bibtex")
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/x-bibtex"]
      )!
      let bibTeX = """
        @article{remote-key,
          author = {Doe, Jane and Smith, John},
          title = {{The Effects of Trade}},
          journal = {Economic Review},
          year = {2024},
          doi = {10.1234/example}
        }
        """
      return (response, Data(bibTeX.utf8))
    }
    defer { BibTeXURLProtocolStub.handler = nil }
    let local = BibliographicSnapshot(
      title: "The effects of trade",
      authorsText: "Jane Doe; John Smith",
      publicationYear: 2024,
      doi: "https://doi.org/10.1234/EXAMPLE",
      journal: "Economic Review"
    )

    let online = try await BibTeXRemoteClient(session: session).fetch(
      for: local,
      contactEmail: nil
    )

    XCTAssertEqual(online.entry.citationKey, "DoeS2024Effects")
    XCTAssertTrue(online.entry.content.contains("@article{DoeS2024Effects,"))
    XCTAssertEqual(BibTeXComparisonRules.differences(local: local, online: online.metadata), [])
  }

  func testBibTeXComparisonReportsOnlyContradictoryLocalFields() {
    let local = BibliographicSnapshot(
      title: "Local Title",
      authorsText: "Jane Doe",
      publicationYear: 2023,
      doi: nil,
      journal: nil
    )
    let online = BibliographicSnapshot(
      title: "Online Title",
      authorsText: "Jane Smith",
      publicationYear: 2024,
      doi: "10.1234/example",
      journal: "Remote Journal"
    )

    let differences = BibTeXComparisonRules.differences(local: local, online: online)

    XCTAssertEqual(differences.map(\.field), ["标题", "作者", "年份", "DOI", "期刊或会议"])
  }
}
