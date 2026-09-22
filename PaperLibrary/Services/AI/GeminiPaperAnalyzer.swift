import Foundation
import PDFKit
import SwiftData

struct GeminiPaperAnalyzer: PaperAnalyzing {
    let apiKey: String
    let model: String
    let session: URLSession
    let remainingBudgetUSD: Double?
    let inputPricePerMillionUSD: Double
    let outputPricePerMillionUSD: Double

    init(
        apiKey: String,
        model: String,
        session: URLSession = .shared,
        remainingBudgetUSD: Double? = nil,
        inputPricePerMillionUSD: Double = 0,
        outputPricePerMillionUSD: Double = 0
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.remainingBudgetUSD = remainingBudgetUSD
        self.inputPricePerMillionUSD = inputPricePerMillionUSD
        self.outputPricePerMillionUSD = outputPricePerMillionUSD
    }

    func analyze(
        pdfURL: URL,
        mode: AnalysisMode,
        allowedCategories: [String],
        existingTags: [String],
        pageLimit: Int? = nil
    ) async throws -> PaperAnalysisResponse {
        let preparedFile = try await Task.detached(priority: .userInitiated) {
            try PDFUploadBuilder.prepareFile(from: pdfURL, pageLimit: pageLimit)
        }.value
        defer { preparedFile.removeTemporaryFile() }
        guard preparedFile.fileSize <= 50 * 1_024 * 1_024 else {
            throw GeminiAnalysisError.fileTooLarge
        }
        let fileClient = GeminiStudyNoteClient(apiKey: apiKey, session: session)
        let remoteFile = try await fileClient.upload(pdfURL: preparedFile.url, onRetry: nil)
        defer { Task { try? await fileClient.delete(remoteFile) } }
        try await fileClient.waitUntilActive(remoteFile, onRetry: nil)
        let categories = Self.normalizedCategories(allowedCategories)
        let prompt = Self.prompt(
            mode: mode,
            allowedCategories: categories,
            existingTags: Self.normalizedTags(existingTags),
            pageLimit: pageLimit
        )
        let contents: [[String: Any]] = [[
            "parts": [
                ["fileData": [
                    "mimeType": remoteFile.mimeType ?? "application/pdf",
                    "fileUri": remoteFile.uri
                ]],
                ["text": prompt]
            ]
        ]]
        let thinkingConfig: [String: Any] = [
            "thinkingLevel": mode == .deep ? "high" : "minimal"
        ]
        let currentFormatConfig: [String: Any] = [
            "thinkingConfig": thinkingConfig,
            "maxOutputTokens": AIBudgetRules.maximumOutputTokens,
            "responseFormat": [
                "text": [
                    "mimeType": "application/json",
                    "schema": Self.responseSchema(allowedCategories: categories)
                ]
            ]
        ]
        let legacySchemaConfig: [String: Any] = [
            "thinkingConfig": thinkingConfig,
            "maxOutputTokens": AIBudgetRules.maximumOutputTokens,
            "responseMimeType": "application/json",
            "responseSchema": Self.responseSchema(allowedCategories: categories)
        ]
        let jsonOnlyConfig: [String: Any] = [
            "thinkingConfig": thinkingConfig,
            "maxOutputTokens": AIBudgetRules.maximumOutputTokens,
            "responseMimeType": "application/json"
        ]
        let promptOnlyConfig: [String: Any] = [
            "thinkingConfig": thinkingConfig,
            "maxOutputTokens": AIBudgetRules.maximumOutputTokens
        ]
        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": currentFormatConfig
        ]

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")
        else { throw GeminiAnalysisError.invalidResponse }

        if let remainingBudgetUSD {
            guard inputPricePerMillionUSD > 0, outputPricePerMillionUSD > 0 else {
                throw GeminiAnalysisError.budgetCheckUnavailable
            }
            let inputTokens = try await countTokens(
                generateContentBody: body,
                encodedModel: encodedModel
            )
            guard AIBudgetRules.allows(
                inputTokens: inputTokens,
                remainingBudgetUSD: remainingBudgetUSD,
                inputPricePerMillionUSD: inputPricePerMillionUSD,
                outputPricePerMillionUSD: outputPricePerMillionUSD
            ) else {
                throw GeminiAnalysisError.budgetExceeded
            }
        }

        let data: Data
        do {
            data = try await generateContent(body: body, url: url)
        } catch let GeminiAnalysisError.httpStatus(400, message)
            where message.localizedCaseInsensitiveContains("response_format") {
            // Gemini 的生成内容接口正从旧的 responseMimeType/responseSchema
            // 迁移到 responseFormat。部分已发布模型仍只接受旧字段。
            var legacyBody = body
            legacyBody["generationConfig"] = legacySchemaConfig
            do {
                data = try await generateContent(body: legacyBody, url: url)
            } catch GeminiAnalysisError.httpStatus(400, _) {
                // 最后的兼容降级仍保留 JSON 模式；结果会在本地按 PaperAnalysis
                // 严格解码及页码范围校验，无法通过校验就不会保存。
                var jsonBody = body
                jsonBody["generationConfig"] = jsonOnlyConfig
                do {
                    data = try await generateContent(body: jsonBody, url: url)
                } catch GeminiAnalysisError.httpStatus(400, _) {
                    // 极少数旧接口既不支持结构化字段也不支持 JSON MIME 类型。
                    // 仍要求模型仅返回 JSON，之后由本地严格解码和页码校验把关。
                    var promptBody = body
                    promptBody["generationConfig"] = promptOnlyConfig
                    data = try await generateContent(body: promptBody, url: url)
                }
            }
        }

        let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
        let primaryInputTokens = envelope.usageMetadata?.promptTokenCount ?? 0
        let primaryOutputTokens = max(
            envelope.usageMetadata?.candidatesTokenCount ?? 0,
            (envelope.usageMetadata?.totalTokenCount ?? 0) - primaryInputTokens
        )
        let primaryTotalTokens = envelope.usageMetadata?.totalTokenCount ?? 0
        guard let text = envelope.candidates.first?.content.parts.compactMap(\.text).joined(),
              let analysisData = text.data(using: .utf8),
              let decodedAnalysis = try? JSONDecoder().decode(PaperAnalysis.self, from: analysisData),
              let document = PDFDocument(url: pdfURL)
        else {
            throw GeminiAnalysisError.billedUsage(
                input: primaryInputTokens,
                output: primaryOutputTokens,
                total: primaryTotalTokens,
                message: GeminiAnalysisError.invalidResponse.localizedDescription
            )
        }
        let resolver = PDFPageReferenceResolver(document: document, pageLimit: pageLimit)
        let initialNeedsEvidenceReview = try EvidencePageNormalizer.hasInvalidPageReferences(
            decodedAnalysis,
            resolver: resolver
        )
        var selectedAnalysis = decodedAnalysis
        var retryInputTokens = 0
        var retryOutputTokens = 0
        var retryTotalTokens = 0

        if initialNeedsEvidenceReview {
            let originalJSON = String(decoding: analysisData, as: UTF8.self)
            let correctionContents: [[String: Any]] = [[
                "parts": [
                    ["fileData": [
                        "mimeType": remoteFile.mimeType ?? "application/pdf",
                        "fileUri": remoteFile.uri
                    ]],
                    ["text": Self.pageCorrectionPrompt(
                        originalAnalysisJSON: originalJSON,
                        pageCount: resolver.pageCount
                    )]
                ]
            ]]
            var correctionConfig = jsonOnlyConfig
            correctionConfig["maxOutputTokens"] = AIBudgetRules.maximumOutputTokens
            let correctionBody: [String: Any] = [
                "contents": correctionContents,
                "generationConfig": correctionConfig
            ]
            do {
                if try await canAffordEvidencePageRetry(
                    body: correctionBody,
                    encodedModel: encodedModel,
                    primaryEnvelope: envelope
                ) {
                    let correctionData = try await generateContent(body: correctionBody, url: url)
                    if let correctionEnvelope = try? JSONDecoder().decode(GeminiEnvelope.self, from: correctionData) {
                        retryInputTokens = correctionEnvelope.usageMetadata?.promptTokenCount ?? 0
                        retryOutputTokens = max(
                            correctionEnvelope.usageMetadata?.candidatesTokenCount ?? 0,
                            (correctionEnvelope.usageMetadata?.totalTokenCount ?? 0) - retryInputTokens
                        )
                        retryTotalTokens = correctionEnvelope.usageMetadata?.totalTokenCount ?? 0
                        if let correctionText = correctionEnvelope.candidates.first?.content.parts.compactMap(\.text).joined(),
                           let correctionData = correctionText.data(using: .utf8),
                           let correctedAnalysis = try? JSONDecoder().decode(PaperAnalysis.self, from: correctionData),
                           try EvidencePageNormalizer.isOnlyPageCorrection(
                                correctedAnalysis,
                                of: decodedAnalysis
                           ),
                           !(try EvidencePageNormalizer.hasInvalidPageReferences(
                                correctedAnalysis,
                                resolver: resolver
                           )) {
                            selectedAnalysis = correctedAnalysis
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 页码修正是质量增强步骤；再次请求失败时仍保存原始分析并提示复核。
            }
        }

        let needsEvidenceReview = try EvidencePageNormalizer.hasInvalidPageReferences(
            selectedAnalysis,
            resolver: resolver
        )
        let analysis = try EvidencePageNormalizer.normalize(selectedAnalysis, resolver: resolver)

        return PaperAnalysisResponse(
            analysis: analysis,
            inputTokens: (envelope.usageMetadata?.promptTokenCount ?? 0) + retryInputTokens,
            outputTokens: max(
                envelope.usageMetadata?.candidatesTokenCount ?? 0,
                (envelope.usageMetadata?.totalTokenCount ?? 0) -
                    (envelope.usageMetadata?.promptTokenCount ?? 0)
            ) + retryOutputTokens,
            totalTokens: (envelope.usageMetadata?.totalTokenCount ?? 0) + retryTotalTokens,
            needsEvidenceReview: needsEvidenceReview
        )
    }

    private func generateContent(body: [String: Any], url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiAnalysisError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "未知错误"
            throw GeminiAnalysisError.httpStatus(http.statusCode, message)
        }
        return data
    }

    private func countTokens(
        generateContentBody: [String: Any],
        encodedModel: String
    ) async throws -> Int {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):countTokens"
        ) else { throw GeminiAnalysisError.budgetCheckUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        var fullRequest = generateContentBody
        fullRequest["model"] = "models/\(model)"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["generateContentRequest": fullRequest]
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let result = try? JSONDecoder().decode(GeminiTokenCountResponse.self, from: data)
            else { throw GeminiAnalysisError.budgetCheckUnavailable }
            return result.totalTokens
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiAnalysisError.budgetCheckUnavailable
        }
    }

    private func canAffordEvidencePageRetry(
        body: [String: Any],
        encodedModel: String,
        primaryEnvelope: GeminiEnvelope
    ) async throws -> Bool {
        guard let remainingBudgetUSD else { return true }
        guard inputPricePerMillionUSD > 0, outputPricePerMillionUSD > 0 else { return false }
        let primaryInput = primaryEnvelope.usageMetadata?.promptTokenCount ?? 0
        let primaryOutput = max(
            primaryEnvelope.usageMetadata?.candidatesTokenCount ?? 0,
            (primaryEnvelope.usageMetadata?.totalTokenCount ?? 0) - primaryInput
        )
        let remainingAfterPrimary = remainingBudgetUSD -
            Double(primaryInput) / 1_000_000 * inputPricePerMillionUSD -
            Double(primaryOutput) / 1_000_000 * outputPricePerMillionUSD
        let retryInput = try await countTokens(
            generateContentBody: body,
            encodedModel: encodedModel
        )
        return AIBudgetRules.allows(
            inputTokens: retryInput,
            remainingBudgetUSD: remainingAfterPrimary,
            inputPricePerMillionUSD: inputPricePerMillionUSD,
            outputPricePerMillionUSD: outputPricePerMillionUSD
        )
    }

    private static func prompt(
        mode: AnalysisMode,
        allowedCategories: [String],
        existingTags: [String],
        pageLimit: Int?
    ) -> String {
        let categoryText = allowedCategories.joined(separator: "、")
        let tagText = existingTags.isEmpty ? "（当前没有已有标签）" : existingTags.joined(separator: "、")
        let scopeText = pageLimit.map {
            "当前只提供了原文献前 \($0) 页。只能根据这些页面提取；未出现的内容必须标记为 unknown，不得假装已检查整本文献。"
        } ?? "已提供整份 PDF，必须检查整份文献。"
        let base = """
    你是经济学文献结构化信息提取器，文献可能是期刊论文、工作论文、书籍、书籍章节、研究报告或学位论文。只依据 PDF 中的信息，用中文填写结果。只输出符合要求的 JSON 对象，不要使用 Markdown 或补充说明。
    \(scopeText)
    不要假定标题、作者或出版信息一定在第一页。对书籍，优先检查封面、扉页、版权页和目录前页；对论文，同时检查首页、页眉页脚、参考引用信息和文末。
    找不到的信息必须将 value 设为空字符串、status 设为 unknown、confidence 设为 0、pages 设为空数组。
    status 只能是 explicit、inferred、unknown。pages 可以为空数组；只有能够确定上传 PDF 的顺序页码时才填写。pages 只能填写上传 PDF 从第一页开始数的顺序页码：PDF 第一页必须写 1，第二页必须写 2。绝对不要填写页面上印刷的期刊页码、书籍页码或论文自身页码。例如，PDF 第 3 页即使页面上印着 171，pages 也必须写 3。不能确定顺序页码时宁可留空，绝不猜测或转换印刷页码。提交前逐项核对所有页码都不超过本次提供的 PDF 页数。证据说明必须简短，不要长段摘抄。
    书目标题、作者、年份、DOI、期刊或论文系列、ISBN、出版社只填写 PDF 中明确出现的内容。作者之间使用分号分隔。
    documentType.value 只能是 article、workingPaper、book、bookChapter、report、thesis 或 other。
    fileVersionType.value 只能是 published、workingPaper、acceptedManuscript、preprint、supplement、annotatedCopy 或 unknown。SSRN 和 NBER 论文默认视为 workingPaper，arXiv 论文视为 preprint。
    suggestedCategory 必须且只能从以下当前主分类中选择一个：\(categoryText)。不得创造新分类；无法判断时选择 Uncategorized。
    当前文献库已有标签：\(tagText)。suggestedTags 应优先选择语义准确的已有标签，并逐字沿用已有标签名称；不要创建仅大小写、单复数、缩写或近义表达不同的重复标签。只有现有标签都不能准确描述文献时，才创建必要的新标签。标签应是简短、可复用的小类主题或研究方法，不要写成句子，最多返回 8 个。
    """
        guard mode == .deep else { return base }
        return base + """
        重点分析识别策略、关键识别假设、机制、异质性、稳健性和局限。合理推断必须标记为 inferred，不能伪装成作者明确陈述。
        """
    }

    private static func pageCorrectionPrompt(
        originalAnalysisJSON: String,
        pageCount: Int
    ) -> String {
        """
        你正在修正一份经济学文献分析中的证据页码。请重新查看上传的 PDF，但不要改变下方 JSON 中任何字段的 value、status、confidence、evidence、suggestedCategory 或 suggestedTags；只修正每个字段的 pages。
        pages 只能使用从上传 PDF 第一页开始的顺序页码，范围必须是 1 到 \(pageCount)。绝对不能填写期刊、书籍或论文页面上印刷的页码。若不能确定顺序页码，请将该字段的 pages 设为 []。只输出完整 JSON，不要使用 Markdown 或说明。

        需要修正的原始 JSON：
        \(originalAnalysisJSON)
        """
    }

    private static func responseSchema(allowedCategories: [String]) -> [String: Any] {
        let field: [String: Any] = [
            "type": "object",
            "properties": [
                "value": ["type": "string"],
                "status": ["type": "string", "enum": ["explicit", "inferred", "unknown"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "pages": ["type": "array", "items": ["type": "integer", "minimum": 1]],
                "evidence": ["type": "string"]
            ],
            "required": ["value", "status", "confidence", "pages", "evidence"]
        ]
        let fieldNames = [
            "bibliographicTitle", "bibliographicAuthors", "bibliographicYear",
            "bibliographicDOI", "bibliographicJournalOrSeries", "bibliographicISBN",
            "bibliographicPublisher", "documentType", "fileVersionType",
            "oneSentenceSummary", "researchQuestion", "paperType", "context",
            "dataSources", "sample", "variables", "identificationStrategy",
            "identificationAssumptions", "mainResults", "mechanisms",
            "heterogeneity", "robustness", "limitations"
        ]
        var properties = Dictionary(uniqueKeysWithValues: fieldNames.map { ($0, field) })
        properties["suggestedCategory"] = ["type": "string", "enum": allowedCategories]
        properties["suggestedTags"] = [
            "type": "array",
            "items": ["type": "string"],
            "maxItems": 8,
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": fieldNames + ["suggestedCategory", "suggestedTags"]
        ]
    }

    private static func normalizedCategories(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result = values.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
        if !result.contains(where: { $0.caseInsensitiveCompare("Uncategorized") == .orderedSame }) {
            result.append("Uncategorized")
        }
        return result
    }

    static func normalizedTags(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw -> String? in
            let value = raw
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

enum PDFUploadBuilder {
    struct PreparedFile: @unchecked Sendable {
        let url: URL
        let fileSize: Int
        let temporaryDirectory: URL?

        func removeTemporaryFile(fileManager: FileManager = .default) {
            guard let temporaryDirectory else { return }
            try? fileManager.removeItem(at: temporaryDirectory)
        }
    }

    static func prepareFile(
        from url: URL,
        pageLimit: Int?,
        fileManager: FileManager = .default
    ) throws -> PreparedFile {
        guard let pageLimit, pageLimit > 0 else {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return PreparedFile(url: url, fileSize: size ?? 0, temporaryDirectory: nil)
        }
        guard let source = PDFDocument(url: url) else { throw PDFImportError.unreadablePDF }
        let count = min(source.pageCount, pageLimit)
        guard count < source.pageCount else {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return PreparedFile(url: url, fileSize: size ?? 0, temporaryDirectory: nil)
        }

        let excerpt = PDFDocument()
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            excerpt.insert(page, at: excerpt.pageCount)
        }
        guard excerpt.pageCount > 0 else { throw PDFImportError.unreadablePDF }
        let directory = fileManager.temporaryDirectory
            .appending(path: "PaperLibraryUpload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: url.lastPathComponent)
        guard excerpt.write(to: target) else {
            try? fileManager.removeItem(at: directory)
            throw PDFImportError.unreadablePDF
        }
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return PreparedFile(url: target, fileSize: size ?? 0, temporaryDirectory: directory)
    }

    static func data(from url: URL, pageLimit: Int?) throws -> Data {
        guard let pageLimit, pageLimit > 0 else { return try Data(contentsOf: url) }
        guard let source = PDFDocument(url: url) else { throw PDFImportError.unreadablePDF }
        let count = min(source.pageCount, pageLimit)
        guard count < source.pageCount else { return try Data(contentsOf: url) }

        let excerpt = PDFDocument()
        for index in 0..<count {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            excerpt.insert(page, at: excerpt.pageCount)
        }
        guard excerpt.pageCount > 0, let data = excerpt.dataRepresentation() else {
            throw PDFImportError.unreadablePDF
        }
        return data
    }
}

struct LocalAPIKeyStore: Sendable {
    static let shared = LocalAPIKeyStore()

    let fileURL: URL

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        let applicationSupport = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        fileURL = applicationSupport
            .appending(path: "PaperLibrary/Private", directoryHint: .isDirectory)
            .appending(path: "gemini-api-key")
    }

    func save(_ value: String, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(value.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    }

    func readIfAvailable() -> String? {
        try? read()
    }

    func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

actor AIRequestGate {
    static let shared = AIRequestGate()

    private var activeTicket: UUID?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func acquire(_ id: UUID) async -> Bool {
        if activeTicket == nil {
            activeTicket = id
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append((id, continuation))
        }
    }

    func cancel(_ id: UUID) {
        guard activeTicket != id,
              let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func release(_ id: UUID) {
        guard activeTicket == id else { return }
        guard !waiters.isEmpty else {
            activeTicket = nil
            return
        }
        let next = waiters.removeFirst()
        activeTicket = next.id
        next.continuation.resume(returning: true)
    }
}
