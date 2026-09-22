import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testDOINormalization() {
    XCTAssertEqual(
      PDFMetadataExtractor.normalizedDOI("https://doi.org/10.1234/ABC.567)."),
      "10.1234/abc.567"
    )
    XCTAssertNil(PDFMetadataExtractor.normalizedDOI("not-a-doi"))
  }

  func testFirstPageBibliographicMetadataExtraction() {
    let text = """
      Generative AI as Seniority-Biased Technological Change:
      Evidence from U.S. Résumé and Job Posting Data*
      Seyed M. Hosseini† Guy Lichtinger‡
      First Version: August 31, 2025
      This Version: June 6, 2026
      Abstract
      """

    let result = PDFMetadataExtractor.inferredBibliographicMetadata(
      from: text,
      fallbackTitle: "ssrn-5425555"
    )

    XCTAssertEqual(
      result.title,
      "Generative AI as Seniority-Biased Technological Change: Evidence from U.S. Résumé and Job Posting Data"
    )
    XCTAssertEqual(result.authorsText, "Seyed M. Hosseini; Guy Lichtinger")
  }

  func testLocalMetadataRepairFillsPlaceholdersAndVersionType() {
    let work = Work(title: "ssrn-5425555", publicationYear: 2025)
    let version = FileVersion(
      relativePath: "Uncategorized/2025/ssrn-5425555.pdf",
      originalFilename: "ssrn-5425555.pdf",
      pageCount: 109,
      fileSize: 1
    )
    let metadata = ExtractedPDFMetadata(
      title: "Generative AI as Seniority-Biased Technological Change",
      authorsText: "Seyed M. Hosseini; Guy Lichtinger",
      publicationYear: 2025,
      fileMetadataYear: 2026,
      pageCount: 109,
      doi: nil,
      nberNumber: nil,
      ssrnID: "5425555",
      arxivID: nil,
      repecHandle: nil,
      textFingerprint: nil,
      hasAnnotations: false,
      suggestedVersionType: "workingPaper"
    )

    XCTAssertTrue(LocalMetadataRepairRules.apply(metadata, to: work, version: version))
    XCTAssertEqual(work.title, "ssrn-5425555")
    XCTAssertTrue(work.authorsText.isEmpty)
    XCTAssertEqual(work.ssrnID, "5425555")
    XCTAssertEqual(version.versionTypeRawValue, "workingPaper")
  }

  func testReprocessingResetPreservesFileHistoryTagsAndStrongIdentifiers() {
    let originalCategory = Category(name: "Labor")
    let uncategorized = Category(name: "Uncategorized", isSystemCategory: true)
    let tag = Tag(name: "用户标签")
    let analysis = AIAnalysis(modelName: "test", promptVersion: "test-v1", status: "completed")
    let work = Work(
      title: "已确认标题",
      authorsText: "Jane Doe",
      publicationYear: 2025,
      journal: "Journal",
      doi: "10.1234/test",
      ssrnID: "5425555",
      documentTypeRawValue: "article",
      isbn: "9780000000000",
      publisher: "Publisher",
      metadataConfirmed: true,
      needsReview: true,
      metadataSource: "crossref",
      metadataConflictNote: "AI 返回了无法定位到 PDF 的引用页码；分析结果已保留，请复核引用页码。",
      primaryCategory: originalCategory,
      tags: [tag],
      analyses: [analysis]
    )
    let version = FileVersion(
      relativePath: "Labor/2025/Archived.pdf",
      originalFilename: "original-file.pdf",
      pageCount: 10,
      fileSize: 1,
      versionTypeRawValue: "published",
      bibliographicTitle: "已核对的版本标题",
      bibliographicAuthorsText: "Jane Doe",
      bibliographicYear: 2025,
      bibliographicJournal: "Journal",
      bibliographicDOI: "10.1234/test",
      bibliographicMetadataSource: "crossref",
      bibliographicMetadataConfirmed: true
    )
    work.fileVersions.append(version)

    WorkReprocessingRules.reset(work, uncategorized: uncategorized)

    XCTAssertEqual(work.title, "original-file")
    XCTAssertTrue(work.authorsText.isEmpty)
    XCTAssertNil(work.publicationYear)
    XCTAssertNil(work.doi)
    XCTAssertEqual(work.ssrnID, "5425555")
    XCTAssertEqual(work.primaryCategory?.id, uncategorized.id)
    XCTAssertEqual(work.tags.map { $0.name }, ["用户标签"])
    XCTAssertEqual(work.analyses.map { $0.id }, [analysis.id])
    XCTAssertEqual(version.relativePath, "Labor/2025/Archived.pdf")
    XCTAssertEqual(version.versionTypeRawValue, "unknown")
    XCTAssertNil(version.bibliographicTitle)
    XCTAssertNil(version.bibliographicAuthorsText)
    XCTAssertNil(version.bibliographicYear)
    XCTAssertNil(version.bibliographicJournal)
    XCTAssertNil(version.bibliographicDOI)
    XCTAssertNil(version.bibliographicMetadataSource)
    XCTAssertFalse(version.bibliographicMetadataConfirmed)
    XCTAssertFalse(work.metadataConfirmed)
    XCTAssertEqual(work.metadataSource, "pendingAI")
    XCTAssertFalse(work.needsReview)
    XCTAssertNil(work.metadataConflictNote)
  }

  func testDuplicateMatcherUsesHashButDoesNotTrustUnverifiedDOI() {
    let existingWork = Work(title: "Existing")
    let existingFile = FileVersion(
      relativePath: "existing.pdf",
      originalFilename: "existing.pdf",
      pageCount: 1,
      fileSize: 1,
      sha256: "same-hash"
    )
    existingWork.fileVersions.append(existingFile)
    let exactImport = importedPDF(sha256: "same-hash", doi: nil)

    if case .exactFile = DuplicateMatcher.decision(
      for: exactImport,
      works: [existingWork],
      versions: [existingFile]
    ) {
      // 预期结果
    } else {
      XCTFail("相同 SHA-256 应识别为完全重复")
    }

    existingWork.doi = "10.1234/paper"
    let versionImport = importedPDF(sha256: "different", doi: "https://doi.org/10.1234/PAPER")
    if case .possibleDuplicate = DuplicateMatcher.decision(
      for: versionImport,
      works: [existingWork],
      versions: [existingFile]
    ) {
      // 应进入人工审核，不自动合并。
    } else {
      XCTFail("相同 DOI 应作为可审核的疑似重复")
    }
  }

  func testDuplicateMatcherDoesNotAutomaticallyMergeByExtractedIdentifier() {
    let existing = Work(title: "另一篇论文", nberNumber: "12345")
    let imported = ImportedPDF(
      transactionID: UUID(),
      relativePath: "Uncategorized/Unknown Year/new.pdf",
      originalFilename: "new.pdf",
      title: "完全不同的论文",
      authorsText: "",
      publicationYear: nil,
      fileMetadataYear: nil,
      pageCount: 1,
      fileSize: 1,
      sha256: "different-hash",
      doi: nil,
      nberNumber: "12345",
      ssrnID: nil,
      arxivID: nil,
      repecHandle: nil,
      textFingerprint: nil,
      hasAnnotations: false,
      suggestedVersionType: "unknown"
    )

    if case .possibleDuplicate = DuplicateMatcher.decision(
      for: imported,
      works: [existing],
      versions: []
    ) {
      // 编号相同时交给用户审核。
    } else {
      XCTFail("相同编号应作为可审核的疑似重复")
    }
  }

  @MainActor
  func testFailedArchiveDoesNotMarkMetadataAsManuallyConfirmed() async throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let work = Work(
      title: "原标题",
      metadataConfirmed: false,
      metadataSource: "ai"
    )
    work.fileVersions.append(
      FileVersion(
        relativePath: "Uncategorized/Unknown Year/missing.pdf",
        originalFilename: "missing.pdf",
        pageCount: 1,
        fileSize: 1
      ))
    container.mainContext.insert(work)
    try container.mainContext.save()
    let coordinator = ArchiveCoordinator()

    coordinator.archive(
      work: work,
      title: "新标题",
      authorsText: "新作者",
      publicationYear: 2026,
      category: nil,
      in: library,
      modelContext: container.mainContext
    )
    while coordinator.isWorking {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertNotNil(coordinator.errorText)
    XCTAssertEqual(work.title, "原标题")
    XCTAssertFalse(work.metadataConfirmed)
    XCTAssertEqual(work.metadataSource, "ai")
  }

  func testCrossrefCompletionSetsCheckedMarkerWithoutUserConfirmation() {
    let work = Work(title: "Original", authorsText: "Author")
    let version = FileVersion(
      relativePath: "original.pdf",
      originalFilename: "original.pdf",
      pageCount: 1,
      fileSize: 1
    )
    work.fileVersions.append(version)
    let metadata = CrossrefMetadata(
      title: "Verified Title",
      authorsText: "Verified Author",
      publicationYear: 2024,
      doi: "10.1234/verified",
      journal: "Verified Journal",
      abstractText: nil
    )

    CrossrefMetadataApplier.apply(metadata, to: work, version: version)

    XCTAssertTrue(work.crossrefChecked)
    XCTAssertTrue(work.metadataConfirmed)
    XCTAssertEqual(work.metadataSource, "crossref")
    XCTAssertEqual(work.doi, "10.1234/verified")
    XCTAssertEqual(version.bibliographicTitle, "Verified Title")
    XCTAssertEqual(version.bibliographicAuthorsText, "Verified Author")
    XCTAssertEqual(version.bibliographicYear, 2024)
    XCTAssertEqual(version.bibliographicJournal, "Verified Journal")
    XCTAssertEqual(version.bibliographicDOI, "10.1234/verified")
    XCTAssertEqual(version.bibliographicMetadataSource, "crossref")
    XCTAssertTrue(version.bibliographicMetadataConfirmed)
  }

  func testCrossrefCorrectsUnconfirmedCandidateDOI() {
    let work = Work(
      title: "Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks",
      authorsText: "Judith Chevalier; Austan Goolsbee",
      publicationYear: 2009,
      doi: "10.1162/qjec.124.4.1853"
    )
    let metadata = CrossrefMetadata(
      title: work.title,
      authorsText: work.authorsText,
      publicationYear: 2009,
      doi: "10.1162/qjec.2009.124.4.1853",
      journal: "The Quarterly Journal of Economics",
      abstractText: nil
    )

    CrossrefMetadataApplier.apply(metadata, to: work)

    XCTAssertEqual(work.doi, "10.1162/qjec.2009.124.4.1853")
  }

  func testOpenAlexLooksUpJournalMetricsByDOI() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAlexURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    OpenAlexURLProtocolStub.handler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      let payload: String
      if url.path.hasPrefix("/works/doi:") {
        payload = """
          {
            "primary_location": {
              "source": {
                "id": "https://openalex.org/S4210225822",
                "type": "journal"
              }
            }
          }
          """
      } else if url.path == "/sources/S4210225822" {
        payload = """
          {
            "id": "https://openalex.org/S4210225822",
            "display_name": "Test Journal",
            "issn_l": "1234-5678",
            "issn": ["1234-5678", "8765-4321"],
            "type": "journal",
            "summary_stats": {
              "2yr_mean_citedness": 4.25,
              "h_index": 72,
              "i10_index": 415
            },
            "works_count": 1200,
            "cited_by_count": 34567,
            "updated_date": "2026-09-01"
          }
          """
      } else {
        throw URLError(.unsupportedURL)
      }
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(payload.utf8)
      )
    }
    defer { OpenAlexURLProtocolStub.handler = nil }

    let metrics = try await OpenAlexJournalClient(session: session).lookup(
      doi: "https://doi.org/10.1000/example",
      journal: "Test Journal"
    )

    XCTAssertEqual(metrics?.sourceName, "Test Journal")
    XCTAssertEqual(metrics?.matchMethod, .doi)
    XCTAssertEqual(metrics?.twoYearMeanCitedness, 4.25)
    XCTAssertEqual(metrics?.hIndex, 72)
    XCTAssertEqual(metrics?.i10Index, 415)
    XCTAssertEqual(metrics?.worksCount, 1200)
    XCTAssertEqual(metrics?.citedByCount, 34567)
  }

  func testOpenAlexErrorIncludesStageStatusAndResponse() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAlexURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    OpenAlexURLProtocolStub.handler = { request in
      let url = try XCTUnwrap(request.url)
      return (
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!,
        Data(#"{"error":"invalid request"}"#.utf8)
      )
    }
    defer { OpenAlexURLProtocolStub.handler = nil }

    do {
      _ = try await OpenAlexJournalClient(session: session).lookup(
        doi: "10.1000/example",
        journal: nil
      )
      XCTFail("应当返回详细错误")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("按 DOI 查找论文"))
      XCTAssertTrue(message.contains("401"))
      XCTAssertTrue(message.contains("invalid request"))
    }
  }

  func testOpenAlexCachedMetricsOnlyMatchOriginalBibliographicIdentity() throws {
    let metrics = OpenAlexJournalMetrics(
      sourceID: "https://openalex.org/S1",
      sourceName: "Test Journal",
      issnL: nil,
      issns: [],
      twoYearMeanCitedness: 1.5,
      hIndex: 10,
      i10Index: 5,
      worksCount: 100,
      citedByCount: 200,
      sourceUpdatedDate: nil,
      fetchedAt: .now,
      matchMethod: .doi,
      requestedDOI: "10.1000/original",
      requestedJournal: "Test Journal"
    )
    let work = Work(
      title: "测试文献",
      journal: "Test Journal",
      doi: "10.1000/original",
      openAlexJournalMetricsJSON: String(
        decoding: try JSONEncoder().encode(metrics),
        as: UTF8.self
      )
    )

    XCTAssertNotNil(work.openAlexJournalMetrics)
    work.doi = "10.1000/changed"
    XCTAssertNil(work.openAlexJournalMetrics)
  }

  func testCrossrefRemovesHTMLFootnoteMarkerFromTitle() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BibTeXURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    BibTeXURLProtocolStub.handler = { request in
      guard let url = request.url else { throw BibTeXRemoteError.invalidResponse }
      let payload = """
        {
          "message": {
            "title": ["Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks<sup>*</sup>"],
            "DOI": "10.1162/qjec.2009.124.4.1853"
          }
        }
        """
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(payload.utf8)
      )
    }
    defer { BibTeXURLProtocolStub.handler = nil }
    let client = CrossrefClient(session: session)

    let metadata = try await client.lookup(
      doi: "10.1162/qjec.2009.124.4.1853",
      title: "Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks",
      author: "",
      contactEmail: nil,
      forceRefresh: true
    )

    XCTAssertEqual(
      metadata?.title,
      "Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks"
    )
  }

  func testCrossrefFallsBackToBibliographicMatchAfterInvalidDOI() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BibTeXURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    BibTeXURLProtocolStub.handler = { request in
      guard let url = request.url else { throw BibTeXRemoteError.invalidResponse }
      if url.path.contains("/works/10.1162") {
        return (
          HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
      guard url.query?.contains("query.bibliographic") == true else {
        throw BibTeXRemoteError.invalidResponse
      }
      let payload = """
        {
          "message": {
            "items": [{
              "title": ["Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks"],
              "author": [
                {"given": "Judith", "family": "Chevalier"},
                {"given": "Austan", "family": "Goolsbee"}
              ],
              "published": {"date-parts": [[2009, 11]]},
              "DOI": "10.1162/qjec.2009.124.4.1853",
              "container-title": ["The Quarterly Journal of Economics"]
            }]
          }
        }
        """
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(payload.utf8)
      )
    }
    defer { BibTeXURLProtocolStub.handler = nil }
    let client = CrossrefClient(session: session)

    let metadata = try await client.lookup(
      doi: "10.1162/qjec.124.4.1853",
      title: "Are Durable Goods Consumers Forward-Looking? Evidence from College Textbooks",
      author: "Judith Chevalier; Austan Goolsbee",
      publicationYear: 2009,
      contactEmail: nil,
      forceRefresh: true
    )

    XCTAssertEqual(metadata?.doi, "10.1162/qjec.2009.124.4.1853")
    XCTAssertEqual(metadata?.publicationYear, 2009)
  }

  func testCrossrefRetriesTitleWithoutAuthorForRecordsMissingAuthors() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BibTeXURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    BibTeXURLProtocolStub.handler = { request in
      guard let url = request.url else { throw BibTeXRemoteError.invalidResponse }
      let query = url.query ?? ""
      let payload: String
      if query.contains("query.author") {
        payload = #"{"message":{"items":[]}}"#
      } else {
        payload = """
          {
            "message": {
              "items": [{
                "title": ["What Drives Media Slant? Evidence From U.S. Daily Newspapers"],
                "published": {"date-parts": [[2010]]},
                "DOI": "10.3982/ecta7195",
                "container-title": ["Econometrica"]
              }]
            }
          }
          """
      }
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(payload.utf8)
      )
    }
    defer { BibTeXURLProtocolStub.handler = nil }
    let client = CrossrefClient(session: session)

    let metadata = try await client.lookup(
      doi: nil,
      title: "What Drives Media Slant? Evidence From U.S. Daily Newspapers",
      author: "Matthew Gentzkow; Jesse M. Shapiro",
      publicationYear: 2010,
      contactEmail: nil,
      forceRefresh: true
    )

    XCTAssertEqual(metadata?.doi, "10.3982/ecta7195")
    XCTAssertEqual(metadata?.authorsText, "")
  }

  @MainActor
  func testVerifiedIdentifierCreatesReviewableDuplicateLink() throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let existing = Work(
      title: "已有记录",
      doi: "https://doi.org/10.1234/SAME",
      metadataSource: "crossref"
    )
    let imported = Work(
      title: "新版本",
      doi: "10.1234/same",
      metadataSource: "ai"
    )
    container.mainContext.insert(existing)
    container.mainContext.insert(imported)
    try container.mainContext.save()

    try PostAnalysisDuplicateLinker.link(imported, modelContext: container.mainContext)

    XCTAssertEqual(imported.duplicateCandidateWorkID, existing.id)
    XCTAssertTrue(imported.needsReview)
    XCTAssertNotNil(imported.metadataConflictNote)
  }
}
