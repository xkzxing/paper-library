import Foundation
import SwiftData

enum AIExpenseKind: Sendable, Equatable {
    case researchCard
    case studyNote
}

struct AIExpenseItem: Sendable {
    let createdAt: Date
    let costUSD: Double
    let kind: AIExpenseKind
}

struct DailyAIExpense: Identifiable, Sendable {
    let date: Date
    let researchCardCostUSD: Double
    let studyNoteCostUSD: Double

    var id: Date { date }
    var totalCostUSD: Double { researchCardCostUSD + studyNoteCostUSD }
}

enum AIExpenseSummary {
    static func dailyTotals(
        for items: [AIExpenseItem],
        calendar: Calendar = .current
    ) -> [DailyAIExpense] {
        let grouped = Dictionary(grouping: items.filter { $0.costUSD > 0 }) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.map { date, entries in
            DailyAIExpense(
                date: date,
                researchCardCostUSD: entries
                    .filter { $0.kind == .researchCard }
                    .reduce(0) { $0 + $1.costUSD },
                studyNoteCostUSD: entries
                    .filter { $0.kind == .studyNote }
                    .reduce(0) { $0 + $1.costUSD }
            )
        }.sorted { $0.date > $1.date }
    }
}

@Model
final class AIAnalysis {
    @Attribute(.unique) var id: UUID
    var modelName: String
    var promptVersion: String
    var resultJSON: String?
    var status: String
    var errorMessage: String?
    var createdAt: Date
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Double
    var analyzedFileVersionID: UUID?
    var work: Work?

    init(
        id: UUID = UUID(),
        modelName: String,
        promptVersion: String,
        resultJSON: String? = nil,
        status: String = "queued",
        errorMessage: String? = nil,
        createdAt: Date = .now,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUSD: Double = 0,
        analyzedFileVersionID: UUID? = nil,
        work: Work? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.promptVersion = promptVersion
        self.resultJSON = resultJSON
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.analyzedFileVersionID = analyzedFileVersionID
        self.work = work
    }
}

/// 精读笔记保存在对应 PDF 旁边；此模型只保存生成任务的进度和费用，
/// 不保存正文或文件的绝对路径。
@Model
final class StudyNoteGeneration {
    @Attribute(.unique) var id: UUID
    var modelName: String
    var status: String
    var errorMessage: String?
    var createdAt: Date
    var completedAt: Date?
    var totalParts: Int
    var completedParts: Int
    var inputTokens: Int
    var cachedInputTokens: Int = 0
    var outputTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Double
    var draftFilename: String
    var downloadedFilename: String?
    var work: Work?

    init(
        id: UUID = UUID(),
        modelName: String = "gemini-3.1-pro-preview",
        status: String = "queued",
        errorMessage: String? = nil,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        totalParts: Int = 0,
        completedParts: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUSD: Double = 0,
        draftFilename: String,
        downloadedFilename: String? = nil,
        work: Work? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.totalParts = totalParts
        self.completedParts = completedParts
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.draftFilename = draftFilename
        self.downloadedFilename = downloadedFilename
        self.work = work
    }
}
