import Foundation
import PDFKit

enum AnalysisMode: String, Codable, CaseIterable, Sendable {
    case extract
    case deep
}

struct AnalysisField: Codable, Sendable, Equatable {
    let value: String
    let status: String
    let confidence: Double
    let pages: [Int]
    let evidence: String
}

struct PaperAnalysis: Codable, Sendable, Equatable {
    let oneSentenceSummary: AnalysisField
    let researchQuestion: AnalysisField
    let paperType: AnalysisField
    let context: AnalysisField
    let dataSources: AnalysisField
    let sample: AnalysisField
    let variables: AnalysisField
    let identificationStrategy: AnalysisField
    let identificationAssumptions: AnalysisField
    let mainResults: AnalysisField
    let mechanisms: AnalysisField
    let heterogeneity: AnalysisField
    let robustness: AnalysisField
    let limitations: AnalysisField
    let suggestedCategory: String
    let suggestedTags: [String]
    var bibliographicTitle: AnalysisField? = nil
    var bibliographicAuthors: AnalysisField? = nil
    var bibliographicYear: AnalysisField? = nil
    var bibliographicDOI: AnalysisField? = nil
    var bibliographicJournalOrSeries: AnalysisField? = nil
    var bibliographicISBN: AnalysisField? = nil
    var bibliographicPublisher: AnalysisField? = nil
    var documentType: AnalysisField? = nil
    var fileVersionType: AnalysisField? = nil

    var evidenceFields: [AnalysisField] {
        let researchFields = [
            oneSentenceSummary, researchQuestion, paperType, context, dataSources,
            sample, variables, identificationStrategy, identificationAssumptions,
            mainResults, mechanisms, heterogeneity, robustness, limitations
        ]
        return researchFields + [
            bibliographicTitle, bibliographicAuthors, bibliographicYear,
            bibliographicDOI, bibliographicJournalOrSeries, bibliographicISBN,
            bibliographicPublisher, documentType, fileVersionType
        ].compactMap { $0 }
    }
}

struct PaperAnalysisResponse: Sendable {
    let analysis: PaperAnalysis
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    /// 模型给出的部分证据页码不在上传 PDF 范围内时，保留结果但要求人工复核。
    let needsEvidenceReview: Bool
}

struct PDFPageReferenceResolver {
    let pageCount: Int

    init(pageCount: Int, printedPageOffset _: Int?) {
        self.pageCount = max(0, pageCount)
    }

    init(document: PDFDocument, pageLimit: Int?) {
        pageCount = min(document.pageCount, pageLimit ?? document.pageCount)
    }

    func pdfPage(for reference: Int) -> Int? {
        (1...pageCount).contains(reference) ? reference : nil
    }
}

enum EvidencePageNormalizer {
    private static let fieldNames = [
        "bibliographicTitle", "bibliographicAuthors", "bibliographicYear",
        "bibliographicDOI", "bibliographicJournalOrSeries", "bibliographicISBN",
        "bibliographicPublisher", "documentType", "fileVersionType",
        "oneSentenceSummary", "researchQuestion", "paperType", "context",
        "dataSources", "sample", "variables", "identificationStrategy",
        "identificationAssumptions", "mainResults", "mechanisms",
        "heterogeneity", "robustness", "limitations",
    ]

    static func normalize(
        _ analysis: PaperAnalysis,
        resolver: PDFPageReferenceResolver
    ) throws -> PaperAnalysis {
        let encoded = try JSONEncoder().encode(analysis)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw GeminiAnalysisError.invalidResponse
        }

        for fieldName in fieldNames {
            guard var field = object[fieldName] as? [String: Any],
                  let values = field["pages"] as? [NSNumber]
            else { continue }
            var normalized: [Int] = []
            for value in values.map(\.intValue) {
                // 模型偶尔会忽略提示，填写期刊的印刷页码。引用无法定位不应
                // 让整份已经结构化的分析完全丢失；移除这类页码并在调用方标为待复核。
                guard let page = resolver.pdfPage(for: value) else { continue }
                if !normalized.contains(page) { normalized.append(page) }
            }
            field["pages"] = normalized.sorted()
            object[fieldName] = field
        }

        let normalizedData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PaperAnalysis.self, from: normalizedData)
    }

    static func hasInvalidPageReferences(
        _ analysis: PaperAnalysis,
        resolver: PDFPageReferenceResolver
    ) throws -> Bool {
        let encoded = try JSONEncoder().encode(analysis)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw GeminiAnalysisError.invalidResponse
        }
        return fieldNames.contains { fieldName in
            guard let field = object[fieldName] as? [String: Any],
                  let values = field["pages"] as? [NSNumber]
            else { return false }
            return values.contains { resolver.pdfPage(for: $0.intValue) == nil }
        }
    }

    static func isOnlyPageCorrection(
        _ candidate: PaperAnalysis,
        of original: PaperAnalysis
    ) throws -> Bool {
        func contentWithoutPages(_ analysis: PaperAnalysis) throws -> Data {
            let encoded = try JSONEncoder().encode(analysis)
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw GeminiAnalysisError.invalidResponse
            }
            for fieldName in fieldNames {
                guard var field = object[fieldName] as? [String: Any] else { continue }
                field.removeValue(forKey: "pages")
                object[fieldName] = field
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return try contentWithoutPages(candidate) == contentWithoutPages(original)
    }
}

protocol PaperAnalyzing: Sendable {
    func analyze(
        pdfURL: URL,
        mode: AnalysisMode,
        allowedCategories: [String],
        existingTags: [String],
        pageLimit: Int?
    ) async throws -> PaperAnalysisResponse
}

enum GeminiAnalysisError: LocalizedError {
    case fileTooLarge
    case invalidResponse
    case httpStatus(Int, String)
    case invalidPageEvidence
    case missingAPIKey
    case budgetExceeded
    case budgetCheckUnavailable
    case billedUsage(input: Int, output: Int, total: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "PDF 超过 50 MB，当前版本无法以内联方式发送。"
        case .invalidResponse:
            return "Gemini 返回了无法识别的结构化结果。"
        case let .httpStatus(code, message):
            return "Gemini 请求失败（\(code)）：\(message)"
        case .invalidPageEvidence:
            return "AI 返回了超出本次 PDF 范围的顺序页码，结果未保存。请重试；期刊页码和书籍印刷页码不会被自动换算。"
        case .missingAPIKey:
            return "请先在设置中保存 Gemini API 密钥。"
        case .budgetExceeded:
            return "本次 AI 请求的最高估算费用会超过本月剩余预算。"
        case .budgetCheckUnavailable:
            return "无法在请求前核算 AI 费用，为避免超出预算已停止本次分析。"
        case let .billedUsage(_, _, _, message):
            return message
        }
    }
}

enum AIBudgetRules {
    static let maximumOutputTokens = 8_192

    static func maximumEstimatedCost(
        inputTokens: Int,
        inputPricePerMillionUSD: Double,
        outputPricePerMillionUSD: Double
    ) -> Double {
        Double(max(0, inputTokens)) / 1_000_000 * max(0, inputPricePerMillionUSD) +
            Double(maximumOutputTokens) / 1_000_000 * max(0, outputPricePerMillionUSD)
    }

    static func allows(
        inputTokens: Int,
        remainingBudgetUSD: Double,
        inputPricePerMillionUSD: Double,
        outputPricePerMillionUSD: Double
    ) -> Bool {
        maximumEstimatedCost(
            inputTokens: inputTokens,
            inputPricePerMillionUSD: inputPricePerMillionUSD,
            outputPricePerMillionUSD: outputPricePerMillionUSD
        ) <= max(0, remainingBudgetUSD)
    }
}
