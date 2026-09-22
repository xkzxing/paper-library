import CoreGraphics
import CoreText
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import XCTest

@testable import PaperLibrary

extension ImportTests {
  func testStudyNoteUsesDedicatedNameAndIsNeverOverwritten() async throws {
    let source = temporaryRoot.appending(path: "study-note-source.pdf")
    try makePDF(at: source, title: "精读笔记测试", author: nil, year: 2024)
    let library = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
    try LibraryLayout.ensureExists(at: library)
    let actor = LibraryFileActor()
    let imported = try await actor.importPDF(from: source, to: library)

    let first = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "文章标题",
      kind: .study,
      in: library
    )
    XCTAssertTrue(first.created)
    XCTAssertEqual(first.url.lastPathComponent, "study-note-source-精读笔记.md")
    try Data("网页生成的精读笔记".utf8).write(to: first.url)

    let second = try await actor.createLiteratureNote(
      forPDFAt: imported.relativePath,
      title: "新标题",
      kind: .study,
      in: library
    )
    XCTAssertFalse(second.created)
    XCTAssertEqual(try String(contentsOf: second.url, encoding: .utf8), "网页生成的精读笔记")
    let existing = try await actor.existingLiteratureNote(
      forPDFAt: imported.relativePath,
      kind: .study,
      in: library
    )
    XCTAssertEqual(existing, first.url)
  }

  func testStudyNoteRequiresContinuousPartHeadings() throws {
    XCTAssertEqual(
      try GeminiStudyNoteClient.partCount(in: "# Part 1\n# Part 2：数据与方法\n# Part 3"),
      3
    )
    XCTAssertThrowsError(try GeminiStudyNoteClient.partCount(in: "# Part 1\n# Part 3")) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("[1, 3]"))
      XCTAssertTrue(message.contains("期望从 1 开始连续编号"))
      XCTAssertTrue(message.contains("# Part 1 ↩ # Part 3"))
    }
    XCTAssertEqual(
      try GeminiStudyNoteClient.partCount(in: "# 第一部分：背景\n# 第 2 部分：模型\n# Part 3：结论"),
      3
    )
    XCTAssertEqual(
      try GeminiStudyNoteClient.partCount(in: "1. 背景\n2. 模型\n3. 结论"),
      3
    )
    XCTAssertEqual(GeminiStudyNoteClient.partCountFromLiteResponse("12\n"), 12)
    XCTAssertNil(GeminiStudyNoteClient.partCountFromLiteResponse("共有 12 部分"))
    XCTAssertNil(GeminiStudyNoteClient.partCountFromLiteResponse("0"))
    XCTAssertTrue(GeminiStudyNoteClient.isValidPart("# Part 2：数据与方法\n\n正文", number: 2))
    XCTAssertTrue(GeminiStudyNoteClient.isValidPart("# 第二部分：数据与方法\n\n正文", number: 2))
    XCTAssertFalse(GeminiStudyNoteClient.isValidPart("# Part 1\n# Part 2", number: 2))
    XCTAssertTrue(
      StudyNoteError.outlineRecognitionFailed(
        initial: "初次返回缺少编号",
        corrected: "修正后仍不连续",
        lite: "轻量模型返回 0"
      ).localizedDescription.contains("轻量模型识别：轻量模型返回 0")
    )
  }

  func testStudyNoteThinkingRetryPromptMatchesScriptRules() {
    XCTAssertEqual(
      GeminiStudyNoteClient.promptForAttempt(basePrompt: "提示", attempt: 1),
      "提示"
    )
    XCTAssertEqual(
      GeminiStudyNoteClient.promptForAttempt(basePrompt: "提示", attempt: 2),
      "提示请记住一定要先思考再输出，现在请开始你的思考："
    )
    XCTAssertEqual(
      GeminiStudyNoteClient.promptForAttempt(
        basePrompt: "提示现在请开始你的思考：",
        attempt: 3
      ),
      "提示严禁直接输出结果。必须先进行充分思考，确认完成思考后再输出。请记住一定要先思考再输出，现在请开始你的思考："
    )
  }

  func testStudyNotePricingSeparatesCachedInputAndContextTiers() {
    let pricing = StudyNotePricing(
      liteInput: 0.30,
      liteCachedInput: 0.03,
      liteOutput: 2.50,
      regularInput: 2.0,
      regularCachedInput: 0.20,
      regularOutput: 12.0,
      largeInput: 4.0,
      largeCachedInput: 0.40,
      largeOutput: 18.0,
      cacheStoragePerMillionTokenHours: 4.50
    )

    let regular = StudyNoteUsage(
      inputTokens: 100_000,
      outputTokens: 10_000,
      totalTokens: 110_000,
      cachedInputTokens: 80_000
    )
    XCTAssertEqual(pricing.estimatedCostUSD(for: regular), 0.176, accuracy: 0.000_001)

    let large = StudyNoteUsage(
      inputTokens: 250_000,
      outputTokens: 10_000,
      totalTokens: 260_000,
      cachedInputTokens: 200_000
    )
    XCTAssertEqual(pricing.estimatedCostUSD(for: large), 0.46, accuracy: 0.000_001)

    let storage = StudyNoteUsage(
      inputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      cacheStorageTokenHours: 100_000
    )
    XCTAssertEqual(pricing.estimatedCostUSD(for: storage), 0.45, accuracy: 0.000_001)
  }

  func testAIExpenseSummaryGroupsResearchCardsAndStudyNotesByDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let firstDay = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 9, day: 4, hour: 23
        )))
    let secondDay = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 9, day: 5, hour: 8
        )))
    let totals = AIExpenseSummary.dailyTotals(
      for: [
        AIExpenseItem(createdAt: firstDay, costUSD: 0.30, kind: .researchCard),
        AIExpenseItem(createdAt: secondDay, costUSD: 0.10, kind: .researchCard),
        AIExpenseItem(createdAt: secondDay, costUSD: 0.20, kind: .studyNote),
        AIExpenseItem(createdAt: secondDay, costUSD: -1, kind: .studyNote),
      ], calendar: calendar)

    XCTAssertEqual(totals.count, 2)
    XCTAssertEqual(totals[0].researchCardCostUSD, 0.10, accuracy: 0.000_001)
    XCTAssertEqual(totals[0].studyNoteCostUSD, 0.20, accuracy: 0.000_001)
    XCTAssertEqual(totals[0].totalCostUSD, 0.30, accuracy: 0.000_001)
    XCTAssertEqual(totals[1].totalCostUSD, 0.30, accuracy: 0.000_001)
  }

  func testStudyNoteThinkingScheduleStrengthensEveryThreePartsAndAfterRetry() {
    var schedule = StudyNoteThinkingSchedule()

    for expectedStrength in [0, 0, 0] {
      XCTAssertEqual(schedule.strengthForNextPart(), expectedStrength)
      schedule.registerSuccessfulPart(using: expectedStrength)
    }
    XCTAssertEqual(schedule.strengthForNextPart(), 1)
    schedule.registerSuccessfulPart(using: 1)

    // 第五部分在强度 1 下出现正文抢跑，重试改用强度 2 并成功。
    XCTAssertEqual(schedule.strengthForNextPart(), 1)
    schedule.registerSuccessfulPart(using: 2)
    XCTAssertEqual(schedule.strengthForNextPart(), 2)
    schedule.registerSuccessfulPart(using: 2)
    XCTAssertEqual(schedule.strengthForNextPart(), 2)
    schedule.registerSuccessfulPart(using: 2)
    XCTAssertEqual(schedule.strengthForNextPart(), 3)
  }

  func testStudyNoteHighestThinkingStrengthIsRetained() {
    let prompt = GeminiStudyNoteClient.promptForThinkingStrength(
      basePrompt: "提示现在请开始你的思考：",
      strength: 5
    )
    XCTAssertEqual(
      prompt,
      "提示最高优先级要求：绝对不得直接生成正文。你必须先进行完整而深入的思考；只有确认思考已经完成后，才允许输出正文。若不能先思考，则不要输出正文："
    )
  }

  func testStudyNoteRetriesOnlyTransientFailures() {
    XCTAssertEqual(StudyNoteNetworkRetryPolicy.retryDelays, [2, 5, 12])
    XCTAssertTrue(StudyNoteNetworkRetryPolicy.isTransient(URLError(.networkConnectionLost)))
    XCTAssertTrue(StudyNoteNetworkRetryPolicy.isTransient(URLError(.timedOut)))
    XCTAssertTrue(
      StudyNoteNetworkRetryPolicy.isTransient(
        StudyNoteError.httpStatus(429, "请求过多")
      ))
    XCTAssertTrue(
      StudyNoteNetworkRetryPolicy.isTransient(
        StudyNoteError.httpStatus(503, "暂时不可用")
      ))
    XCTAssertFalse(StudyNoteNetworkRetryPolicy.isTransient(URLError(.cancelled)))
    XCTAssertFalse(
      StudyNoteNetworkRetryPolicy.isTransient(
        StudyNoteError.httpStatus(401, "密钥无效")
      ))
  }

  func testStudyNoteCheckpointSupportsResumeWithoutDuplicatingParts() throws {
    let directory = temporaryRoot.appending(path: "论文目录", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pdfURL = directory.appending(path: "论文.pdf")
    try Data().write(to: pdfURL)
    let taskID = UUID()
    let workID = UUID()
    defer { StudyNoteCheckpointStore.remove(taskID: taskID, pdfURL: pdfURL) }

    try StudyNoteCheckpointStore.initialize(
      taskID: taskID,
      workID: workID,
      pdfSHA256: "abc123",
      modelName: "test-model",
      promptVersion: "study-note-v2",
      title: "断点测试",
      pdfURL: pdfURL
    )
    try StudyNoteCheckpointStore.savePlan(
      "# Part 1\n# Part 2\n# Part 3",
      totalParts: 3,
      taskID: taskID,
      pdfURL: pdfURL
    )
    try StudyNoteCheckpointStore.appendPart(
      "# Part 1：背景\n\n第一部分正文",
      part: 1,
      totalParts: 3,
      taskID: taskID,
      pdfURL: pdfURL
    )
    // 同一部分即使因调用方重复通知，也不能写入两次。
    try StudyNoteCheckpointStore.appendPart(
      "# Part 1：背景\n\n第一部分正文",
      part: 1,
      totalParts: 3,
      taskID: taskID,
      pdfURL: pdfURL
    )
    try StudyNoteCheckpointStore.appendPart(
      "# Part 2：模型\n\n第二部分正文",
      part: 2,
      totalParts: 3,
      taskID: taskID,
      pdfURL: pdfURL
    )

    let recovered = try StudyNoteCheckpointStore.load(
      taskID: taskID,
      workID: workID,
      pdfSHA256: "abc123",
      pdfURL: pdfURL
    )
    XCTAssertEqual(recovered.checkpoint.completedParts, 2)
    XCTAssertEqual(recovered.checkpoint.totalParts, 3)
    XCTAssertEqual(recovered.draft.components(separatedBy: "# Part 1").count - 1, 1)
    XCTAssertTrue(
      StudyNoteCheckpointStore.hasRecoverableCheckpoint(
        taskID: taskID,
        pdfURL: pdfURL
      ))

    let exported = try StudyNoteCheckpointStore.exportBesidePDF(
      taskID: taskID,
      pdfURL: pdfURL,
      incomplete: true
    )
    XCTAssertEqual(exported.lastPathComponent, "论文-精读笔记-未完成.md")
    XCTAssertTrue(
      try String(contentsOf: exported, encoding: .utf8).contains("此精读笔记尚未完成")
    )
  }

  func testStudyNoteResumePromptStartsAtNextPart() {
    let context = StudyNoteResumeContext(
      outline: "# Part 1\n# Part 2\n# Part 3",
      completedParts: 2,
      totalParts: 3,
      existingDraft: "# Part 1：背景\n正文\n# Part 2：模型\n正文"
    )
    let prompt = GeminiStudyNoteClient.resumePrompt(context: context, nextPart: 3)

    XCTAssertTrue(prompt.contains("已经完整保存第 1 至第 2 部分"))
    XCTAssertTrue(prompt.contains("只生成第 3 部分"))
    XCTAssertTrue(prompt.contains(context.outline))
    XCTAssertTrue(prompt.contains(context.existingDraft))
  }

  func testStudyNoteResumeRuleRequiresIncompleteSavedParts() {
    let record = StudyNoteGeneration(
      status: "failed",
      totalParts: 5,
      completedParts: 2,
      draftFilename: "draft.md"
    )
    XCTAssertTrue(StudyNoteResumeRules.canResume(record))
    XCTAssertFalse(
      StudyNoteResumeRules.canResume(
        record,
        pdfURL: temporaryRoot.appending(path: "不存在的论文.pdf")
      ))
    record.completedParts = 5
    XCTAssertFalse(StudyNoteResumeRules.canResume(record))
    record.completedParts = 2
    record.status = "completed"
    XCTAssertFalse(StudyNoteResumeRules.canResume(record))
  }

  func testStudyNoteExportsCenteredTitleAndAvoidsNameCollisions() throws {
    let draftName = "test-study-note-\(UUID().uuidString).md"
    defer { StudyNoteDraftStore.remove(filename: draftName) }
    try StudyNoteDraftStore.writeHeader(title: "精读测试", filename: draftName)
    try StudyNoteDraftStore.append("# 第 1 部分\n\n测试正文", filename: draftName)

    let downloads = temporaryRoot.appending(path: "Downloads", directoryHint: .isDirectory)
    let first = try StudyNoteDraftStore.export(
      filename: draftName,
      pdfFilename: "原文.pdf",
      incomplete: false,
      downloadsDirectory: downloads
    )
    let second = try StudyNoteDraftStore.export(
      filename: draftName,
      pdfFilename: "原文.pdf",
      incomplete: false,
      downloadsDirectory: downloads
    )

    XCTAssertEqual(first.lastPathComponent, "原文-精读笔记.md")
    XCTAssertEqual(second.lastPathComponent, "原文-精读笔记 (2).md")
    XCTAssertEqual(
      try String(contentsOf: first, encoding: .utf8),
      "<h1 style=\"text-align: center; font-style: italic\">精读测试</h1>\n\n# 第 1 部分\n\n测试正文\n"
    )
  }

  func testGeneratedStudyNoteIsInstalledBesidePDFWithStableName() throws {
    let draftName = "test-study-note-beside-pdf-\(UUID().uuidString).md"
    defer { StudyNoteDraftStore.remove(filename: draftName) }
    try StudyNoteDraftStore.writeHeader(title: "精读测试", filename: draftName)
    try StudyNoteDraftStore.append("# 第一部分\n\n正文", filename: draftName)
    let directory = temporaryRoot.appending(path: "Paper", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pdfURL = directory.appending(path: "原文.pdf")
    try Data().write(to: pdfURL)

    let output = try StudyNoteDraftStore.exportBesidePDF(
      filename: draftName,
      pdfURL: pdfURL,
      incomplete: false
    )

    XCTAssertEqual(output, directory.appending(path: "原文-精读笔记.md"))
    XCTAssertThrowsError(
      try StudyNoteDraftStore.exportBesidePDF(
        filename: draftName,
        pdfURL: pdfURL,
        incomplete: false
      ))
  }
}
