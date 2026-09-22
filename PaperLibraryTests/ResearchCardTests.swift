import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testVerifiedAIMetadataCanUseStructuredFilenameBeforeManualConfirmation() {
    let work = Work(
      title: "Automatic Metadata Paper",
      authorsText: "Jane Doe; John Smith",
      publicationYear: 2025,
      metadataConfirmed: false,
      metadataSource: "crossref"
    )
    let file = FileVersion(
      relativePath: "Uncategorized/Unknown Year/download.pdf",
      originalFilename: "download.pdf",
      pageCount: 1,
      fileSize: 1
    )

    XCTAssertEqual(
      ArchiveRules.filename(for: work, version: file, includeVersionSuffix: false),
      "Doe & Smith - 2025 - Automatic Metadata Paper.pdf"
    )
  }

  func testLongDocumentUploadCanUseOnlyLeadingPages() throws {
    let source = temporaryRoot.appending(path: "long-document.pdf")
    try makePDF(at: source, title: "长文献", author: "测试作者", year: 2025, pageCount: 12)

    let data = try PDFUploadBuilder.data(from: source, pageLimit: 5)
    let excerpt = try XCTUnwrap(PDFDocument(data: data))

    XCTAssertEqual(excerpt.pageCount, 5)
    XCTAssertEqual(try XCTUnwrap(PDFDocument(url: source)).pageCount, 12)
  }

  func testPaperAnalysisJSONRoundTrip() throws {
    let unknown = AnalysisField(
      value: "",
      status: "unknown",
      confidence: 0,
      pages: [],
      evidence: ""
    )
    let analysis = PaperAnalysis(
      oneSentenceSummary: unknown,
      researchQuestion: unknown,
      paperType: unknown,
      context: unknown,
      dataSources: unknown,
      sample: unknown,
      variables: unknown,
      identificationStrategy: unknown,
      identificationAssumptions: unknown,
      mainResults: unknown,
      mechanisms: unknown,
      heterogeneity: unknown,
      robustness: unknown,
      limitations: unknown,
      suggestedCategory: "Labor",
      suggestedTags: ["minimum wage"]
    )

    let data = try JSONEncoder().encode(analysis)
    XCTAssertEqual(try JSONDecoder().decode(PaperAnalysis.self, from: data), analysis)
  }

  func testOnlyPDFSequencePagesAreAccepted() {
    let resolver = PDFPageReferenceResolver(pageCount: 44, printedPageOffset: 168)

    XCTAssertNil(resolver.pdfPage(for: 171))
    XCTAssertNil(resolver.pdfPage(for: 212))
    XCTAssertEqual(resolver.pdfPage(for: 3), 3)
    XCTAssertNil(resolver.pdfPage(for: 500))
  }

  func testAIRequestGateSerializesAndCancelsQueuedRequest() async {
    let gate = AIRequestGate()
    let first = UUID()
    let second = UUID()
    let firstAcquired = await gate.acquire(first)
    XCTAssertTrue(firstAcquired)
    let waiting = Task { await gate.acquire(second) }
    try? await Task.sleep(for: .milliseconds(10))
    await gate.cancel(second)
    let waitingAcquired = await waiting.value
    XCTAssertFalse(waitingAcquired)
    await gate.release(first)
  }

  func testAIBudgetUsesCountedInputAndMaximumOutputBeforeRequest() {
    let maximumCost = AIBudgetRules.maximumEstimatedCost(
      inputTokens: 1_000_000,
      inputPricePerMillionUSD: 0.30,
      outputPricePerMillionUSD: 2.50
    )

    XCTAssertEqual(maximumCost, 0.32048, accuracy: 0.000_001)
    XCTAssertTrue(
      AIBudgetRules.allows(
        inputTokens: 1_000_000,
        remainingBudgetUSD: 0.32048,
        inputPricePerMillionUSD: 0.30,
        outputPricePerMillionUSD: 2.50
      ))
    XCTAssertFalse(
      AIBudgetRules.allows(
        inputTokens: 1_000_000,
        remainingBudgetUSD: 0.32,
        inputPricePerMillionUSD: 0.30,
        outputPricePerMillionUSD: 2.50
      ))
  }

  func testPrintedPageNumbersAreNotDetectedOrConverted() throws {
    let url = temporaryRoot.appending(path: "paginated.pdf")
    try makePaginatedPDF(at: url, printedStart: 169, pageCount: 8)
    let document = try XCTUnwrap(PDFDocument(url: url))

    let resolver = PDFPageReferenceResolver(document: document, pageLimit: nil)

    XCTAssertNil(resolver.pdfPage(for: 175))
  }

  func testPrintedEvidencePagesAreRemovedAndFlaggedForReview() throws {
    let unknown = AnalysisField(
      value: "", status: "unknown", confidence: 0, pages: [], evidence: "")
    let explicit = AnalysisField(
      value: "研究结论",
      status: "explicit",
      confidence: 0.9,
      pages: [171, 172],
      evidence: "期刊印刷页码"
    )
    let analysis = PaperAnalysis(
      oneSentenceSummary: explicit,
      researchQuestion: unknown,
      paperType: unknown,
      context: unknown,
      dataSources: unknown,
      sample: unknown,
      variables: unknown,
      identificationStrategy: unknown,
      identificationAssumptions: unknown,
      mainResults: unknown,
      mechanisms: unknown,
      heterogeneity: unknown,
      robustness: unknown,
      limitations: unknown,
      suggestedCategory: "Labor",
      suggestedTags: []
    )

    let resolver = PDFPageReferenceResolver(pageCount: 44, printedPageOffset: 168)
    XCTAssertTrue(try EvidencePageNormalizer.hasInvalidPageReferences(analysis, resolver: resolver))
    let normalized = try EvidencePageNormalizer.normalize(analysis, resolver: resolver)
    XCTAssertEqual(normalized.oneSentenceSummary.pages, [])
    XCTAssertEqual(normalized.oneSentenceSummary.value, "研究结论")
    XCTAssertTrue(try EvidencePageNormalizer.isOnlyPageCorrection(normalized, of: analysis))
  }

  func testOlderAIAnalysisWithoutBibliographicFieldsStillDecodes() throws {
    let unknown = AnalysisField(
      value: "", status: "unknown", confidence: 0, pages: [], evidence: "")
    let analysis = PaperAnalysis(
      oneSentenceSummary: unknown,
      researchQuestion: unknown,
      paperType: unknown,
      context: unknown,
      dataSources: unknown,
      sample: unknown,
      variables: unknown,
      identificationStrategy: unknown,
      identificationAssumptions: unknown,
      mainResults: unknown,
      mechanisms: unknown,
      heterogeneity: unknown,
      robustness: unknown,
      limitations: unknown,
      suggestedCategory: "Labor",
      suggestedTags: []
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) as? [String: Any]
    )
    for key in [
      "bibliographicTitle", "bibliographicAuthors", "bibliographicYear",
      "bibliographicDOI", "bibliographicJournalOrSeries", "bibliographicISBN",
      "bibliographicPublisher", "documentType", "fileVersionType",
    ] {
      object.removeValue(forKey: key)
    }

    let decoded = try JSONDecoder().decode(
      PaperAnalysis.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(decoded.bibliographicTitle)
    XCTAssertEqual(decoded.suggestedCategory, "Labor")
  }

  func testAIAnalysisSafelyFillsMissingBibliographicMetadata() {
    let unknown = AnalysisField(
      value: "", status: "unknown", confidence: 0, pages: [], evidence: "")
    let explicitTitle = AnalysisField(
      value: "A Verified Working Paper",
      status: "explicit",
      confidence: 0.98,
      pages: [1],
      evidence: "首页标题"
    )
    var analysis = PaperAnalysis(
      oneSentenceSummary: unknown,
      researchQuestion: unknown,
      paperType: unknown,
      context: unknown,
      dataSources: unknown,
      sample: unknown,
      variables: unknown,
      identificationStrategy: unknown,
      identificationAssumptions: unknown,
      mainResults: unknown,
      mechanisms: unknown,
      heterogeneity: unknown,
      robustness: unknown,
      limitations: unknown,
      suggestedCategory: "Labor",
      suggestedTags: []
    )
    analysis.bibliographicTitle = explicitTitle
    analysis.bibliographicAuthors = AnalysisField(
      value: "Jane Doe; John Smith",
      status: "explicit",
      confidence: 0.96,
      pages: [1],
      evidence: "首页作者"
    )
    analysis.bibliographicDOI = AnalysisField(
      value: "10.1234/correct",
      status: "explicit",
      confidence: 0.99,
      pages: [2],
      evidence: "版权信息"
    )
    analysis.fileVersionType = AnalysisField(
      value: "workingPaper",
      status: "explicit",
      confidence: 0.95,
      pages: [1],
      evidence: "SSRN"
    )
    analysis.documentType = AnalysisField(
      value: "workingPaper",
      status: "explicit",
      confidence: 0.97,
      pages: [1],
      evidence: "SSRN"
    )
    let work = Work(title: "ssrn-1234567", doi: "10.9999/cited-reference")
    let version = FileVersion(
      relativePath: "Uncategorized/2025/ssrn-1234567.pdf",
      originalFilename: "ssrn-1234567.pdf",
      pageCount: 10,
      fileSize: 1,
      versionTypeRawValue: "published"
    )

    XCTAssertTrue(AIAnalysisMetadataApplier.apply(analysis, to: work, version: version))
    XCTAssertEqual(work.title, "A Verified Working Paper")
    XCTAssertEqual(work.authorsText, "Jane Doe; John Smith")
    XCTAssertEqual(work.doi, "10.1234/correct")
    XCTAssertEqual(version.versionTypeRawValue, "workingPaper")
    XCTAssertEqual(version.bibliographicTitle, "A Verified Working Paper")
    XCTAssertEqual(version.bibliographicAuthorsText, "Jane Doe; John Smith")
    XCTAssertEqual(version.bibliographicDOI, "10.1234/correct")
    XCTAssertEqual(version.bibliographicMetadataSource, "ai")
    XCTAssertFalse(version.bibliographicMetadataConfirmed)
    XCTAssertEqual(work.documentTypeRawValue, "workingPaper")
    XCTAssertEqual(work.metadataSource, "ai")
  }

  func testLocalAPIKeyStorePersistsWithoutKeychain() throws {
    let store = LocalAPIKeyStore(baseDirectory: temporaryRoot)

    try store.save("test-api-key")

    XCTAssertEqual(try store.read(), "test-api-key")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: store.fileURL.deletingLastPathComponent().path
    )
    XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

    try store.delete()
    XCTAssertNil(try store.read())
  }

  func testLatestAIStatusSupersedesEarlierFailure() {
    let work = Work(title: "测试文献")
    work.analyses = [
      AIAnalysis(
        modelName: "gemini",
        promptVersion: "1",
        status: "failed",
        createdAt: Date(timeIntervalSince1970: 100)
      ),
      AIAnalysis(
        modelName: "gemini",
        promptVersion: "2",
        status: "completed",
        createdAt: Date(timeIntervalSince1970: 200)
      ),
    ]

    XCTAssertEqual(AIAnalysisStateRules.latestStatus(for: work), "completed")
    XCTAssertFalse(AIAnalysisStateRules.isLatestStatus(work, oneOf: ["failed"]))
  }

  func testSuccessfulRetryClearsOnlyResolvedAutomaticIssue() {
    let recovered = Work(
      title: "重试测试",
      needsReview: true,
      metadataConflictNote: "AI 处理因上次运行中断而未完成。"
    )
    AIAnalysisIssueRules.clearResolvedAutomaticIssue(on: recovered)
    XCTAssertFalse(recovered.needsReview)
    XCTAssertNil(recovered.metadataConflictNote)

    let manualConflict = Work(
      title: "元数据冲突",
      needsReview: true,
      metadataConflictNote: "PDF 与 Crossref 的年份不一致。"
    )
    AIAnalysisIssueRules.clearResolvedAutomaticIssue(on: manualConflict)
    XCTAssertTrue(manualConflict.needsReview)
    XCTAssertNotNil(manualConflict.metadataConflictNote)

    let duplicate = Work(
      title: "重复候选",
      needsReview: true,
      duplicateCandidateWorkID: UUID(),
      metadataConflictNote: "自动分类失败：测试"
    )
    AIAnalysisIssueRules.clearResolvedAutomaticIssue(on: duplicate)
    XCTAssertTrue(duplicate.needsReview)
    XCTAssertNotNil(duplicate.metadataConflictNote)
  }

  @MainActor
  func testAITagSuggestionsAreNormalizedAndDeduplicated() {
    XCTAssertEqual(
      AIAnalysisTagApplier.normalizedNames([
        "  labor   demand ",
        "Labor demand",
        "minimum wage",
        "",
      ]),
      ["labor demand", "minimum wage"]
    )
  }

  @MainActor
  func testAITagSuggestionsArePersistedOnWork() throws {
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
    let existingTag = Tag(name: "Labor Demand")
    let work = Work(title: "测试文献")
    container.mainContext.insert(existingTag)
    container.mainContext.insert(work)

    XCTAssertTrue(
      try AIAnalysisTagApplier.apply(
        ["labor demand", "minimum wage"],
        to: work,
        modelContext: container.mainContext
      ))
    try container.mainContext.save()

    XCTAssertEqual(Set(work.tags.map(\.name)), ["Labor Demand", "minimum wage"])
    XCTAssertTrue(work.tags.contains(where: { $0.id == existingTag.id }))
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Tag>()), 2)
  }

  func testExistingTagsAreNormalizedBeforeAIAnalysis() {
    XCTAssertEqual(
      GeminiPaperAnalyzer.normalizedTags([
        " Labor   Demand ",
        "labor demand",
        "Minimum Wage",
        "",
      ]),
      ["Labor Demand", "Minimum Wage"]
    )
  }

  @MainActor
  func testInterruptedAIQueueIsRecoveredAsFailure() throws {
    let schema = Schema([
      Work.self, FileVersion.self, Category.self, Tag.self, PersonalMark.self, ReadingProject.self, AIAnalysis.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let queued = AIAnalysis(modelName: "gemini", promptVersion: "v1", status: "queued")
    let running = AIAnalysis(modelName: "gemini", promptVersion: "v1", status: "running")
    let completed = AIAnalysis(modelName: "gemini", promptVersion: "v1", status: "completed")
    let work = Work(title: "恢复队列测试", analyses: [queued, running, completed])
    container.mainContext.insert(work)
    try container.mainContext.save()

    let recovered = try AIAnalysisRecoveryMaintenance.markInterruptedTasks(
      modelContext: container.mainContext
    )

    XCTAssertEqual(recovered, 2)
    XCTAssertEqual(queued.status, "failed")
    XCTAssertEqual(running.status, "failed")
    XCTAssertEqual(completed.status, "completed")
    XCTAssertTrue(work.needsReview)
    XCTAssertNotNil(work.metadataConflictNote)
  }

}
