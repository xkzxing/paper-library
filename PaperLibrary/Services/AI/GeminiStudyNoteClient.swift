import Foundation

struct GeminiUploadedFile: Decodable {
    let name: String
    let uri: String
    let mimeType: String?
    let state: String?
}

private struct GeminiFileEnvelope: Decodable {
    let file: GeminiUploadedFile
}

private struct GeminiCachedContent: Decodable {
    struct UsageMetadata: Decodable {
        let totalTokenCount: Int?
    }

    let name: String
    let usageMetadata: UsageMetadata?
}

/// 使用与 `analyze_article.py` 相同的文件上传、聊天与流式生成流程。
/// 只有先收到模型的思考摘要、再收到正常结束的正文时，才会把该轮回复放进聊天历史。
struct GeminiStudyNoteClient {
    typealias RetryObserver = @MainActor @Sendable (Int, Int, Error) async throws -> Void

    static let model = "gemini-3.1-pro-preview"
    private static let outlineRecognizerModel = "gemini-3.5-flash-lite"
    private static let cacheTTLSeconds = 3_600
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    @MainActor
    func generate(
        pdfURL: URL,
        resume: StudyNoteResumeContext? = nil,
        onStage: @escaping @MainActor @Sendable (String) async throws -> Void,
        onPlan: @MainActor @Sendable (String, Int) async throws -> Void,
        onPart: @MainActor @Sendable (Int, Int, String, StudyNoteUsage) async throws -> Void
    ) async throws {
        let retryObserver: RetryObserver = { retryNumber, delay, error in
            try await onStage(
                "网络暂时不可用，\(delay) 秒后自动重试（\(retryNumber)/\(StudyNoteNetworkRetryPolicy.retryDelays.count)）：\(error.localizedDescription)"
            )
        }
        try await onStage("正在上传 PDF…")
        let remoteFile = try await upload(pdfURL: pdfURL, onRetry: retryObserver)
        var cachedContent: GeminiCachedContent?
        defer {
            let cacheToDelete = cachedContent
            Task {
                if let cacheToDelete { try? await delete(cacheToDelete) }
                try? await delete(remoteFile)
            }
        }
        try await waitUntilActive(remoteFile, onRetry: retryObserver)

        try await onStage("正在建立 PDF 缓存…")
        do {
            cachedContent = try await createCache(for: remoteFile, onRetry: retryObserver)
        } catch {
            // 过短文档不满足显式缓存的最低令牌数时，仍可依靠模型自动缓存继续生成。
            cachedContent = nil
            try await onStage("显式缓存不可用，正在使用自动缓存继续：\(error.localizedDescription)")
        }
        if cachedContent != nil {
            try await onStage("PDF 显式缓存已建立。")
        }
        if let cachedTokens = cachedContent?.usageMetadata?.totalTokenCount, cachedTokens > 0 {
            try await onPart(
                0,
                resume?.totalParts ?? 0,
                "",
                StudyNoteUsage(
                    inputTokens: 0,
                    outputTokens: 0,
                    totalTokens: 0,
                    cacheStorageTokenHours: Double(cachedTokens) * Double(Self.cacheTTLSeconds) / 3_600
                )
            )
        }

        if let resume {
            guard resume.completedParts > 0,
                  resume.totalParts > resume.completedParts
            else { throw StudyNoteError.invalidResponse }
            var history: [[String: Any]] = []
            var thinkingSchedule = StudyNoteThinkingSchedule()
            for _ in 0..<resume.completedParts {
                thinkingSchedule.registerSuccessfulPart(using: thinkingSchedule.strengthForNextPart())
            }
            for part in (resume.completedParts + 1)...resume.totalParts {
                try Task.checkCancellation()
                try await onStage("正在继续生成第 \(part)/\(resume.totalParts) 部分…")
                let basePrompt = part == resume.completedParts + 1
                    ? Self.resumePrompt(context: resume, nextPart: part)
                    : Self.nextPartPrompt
                let result = try await generateWithThinking(
                    basePrompt: basePrompt,
                    remoteFile: part == resume.completedParts + 1 && cachedContent == nil ? remoteFile : nil,
                    cachedContentName: cachedContent?.name,
                    history: &history,
                    initialThinkingStrength: thinkingSchedule.strengthForNextPart(),
                    onRetry: retryObserver
                )
                guard Self.isValidPart(result.answer, number: part) else {
                    throw StudyNoteError.invalidPart(part)
                }
                try await onPart(part, resume.totalParts, result.answer, result.usage)
                thinkingSchedule.registerSuccessfulPart(using: result.thinkingStrength)
            }
            return
        }

        try await onStage("正在规划章节…")
        var history: [[String: Any]] = []
        let initialOutlineResult = try await generateWithThinking(
            basePrompt: Self.outlinePrompt,
            remoteFile: cachedContent == nil ? remoteFile : nil,
            cachedContentName: cachedContent?.name,
            history: &history,
            onRetry: retryObserver
        )
        var count: Int
        var selectedOutline = initialOutlineResult.answer
        var outlineUsages = [initialOutlineResult.usage]
        var liteUsage: StudyNoteUsage?
        do {
            count = try Self.partCount(in: initialOutlineResult.answer)
        } catch let initialError {
            // 目录本身不合格时，不应直接终止整份精读。保留首次回复在对话历史中，
            // 让模型只重排标题格式；两次请求的用量都会记入本次任务。
            try await onStage("正在调整章节目录格式…")
            let correctedOutlineResult = try await generateWithThinking(
                basePrompt: Self.outlineFormatRetryPrompt,
                remoteFile: nil,
                cachedContentName: cachedContent?.name,
                history: &history,
                onRetry: retryObserver
            )
            selectedOutline = correctedOutlineResult.answer
            outlineUsages.append(correctedOutlineResult.usage)
            do {
                count = try Self.partCount(in: correctedOutlineResult.answer)
            } catch let correctedError {
                try await onStage("正在使用轻量模型确认章节数量…")
                do {
                    let recognized = try await recognizePartCountWithLite(
                        in: correctedOutlineResult.answer,
                        onRetry: retryObserver
                    )
                    count = recognized.count
                    liteUsage = recognized.usage
                } catch {
                    throw StudyNoteError.outlineRecognitionFailed(
                        initial: initialError.localizedDescription,
                        corrected: correctedError.localizedDescription,
                        lite: error.localizedDescription
                    )
                }
            }
        }
        try await onPlan(selectedOutline, count)
        // 把目录与第一部分一同通知协调器，目录只用于内部生成状态，不会单独显示为正文。
        for usage in outlineUsages {
            try await onPart(0, count, "", usage)
        }
        if let liteUsage {
            try await onPart(0, count, "", liteUsage)
        }
        var thinkingSchedule = StudyNoteThinkingSchedule()

        for part in 1...count {
            try Task.checkCancellation()
            try await onStage("正在生成第 \(part)/\(count) 部分…")
            let basePrompt = part == 1 ? Self.firstPartPrompt : Self.nextPartPrompt
            let result = try await generateWithThinking(
                basePrompt: basePrompt,
                remoteFile: nil,
                cachedContentName: cachedContent?.name,
                history: &history,
                initialThinkingStrength: thinkingSchedule.strengthForNextPart(),
                onRetry: retryObserver
            )
            let text = result.answer
            guard Self.isValidPart(text, number: part) else {
                throw StudyNoteError.invalidPart(part)
            }
            try await onPart(part, count, text, result.usage)
            thinkingSchedule.registerSuccessfulPart(using: result.thinkingStrength)
        }
    }

    func upload(
        pdfURL: URL,
        onRetry: RetryObserver?
    ) async throws -> GeminiUploadedFile {
        let resourceValues = try pdfURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = resourceValues.fileSize else { throw CocoaError(.fileReadUnknown) }
        let uploadURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
        var start = URLRequest(url: uploadURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("application/pdf", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["display_name": pdfURL.lastPathComponent]
        ])
        let (startData, startResponse) = try await requestData(for: start, onRetry: onRetry)
        guard let http = startResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "x-goog-upload-url"),
              let destination = URL(string: location)
        else { throw try error(from: startResponse, data: startData) }

        var finish = URLRequest(url: destination)
        finish.httpMethod = "POST"
        finish.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        finish.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        finish.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        let (finishData, finishResponse) = try await retryingTransientFailures(onRetry: onRetry) {
            let (data, response) = try await session.upload(for: finish, fromFile: pdfURL)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw try error(from: response, data: data)
            }
            return (data, response)
        }
        guard let finishHTTP = finishResponse as? HTTPURLResponse,
              (200..<300).contains(finishHTTP.statusCode)
        else { throw try error(from: finishResponse, data: finishData) }
        // 可恢复上传的完成请求会直接返回文件对象；部分旧接口会额外包一层
        // file。两者都接受，避免把成功的 200 响应误报为上传失败。
        if let file = try? JSONDecoder().decode(GeminiUploadedFile.self, from: finishData) {
            return file
        }
        if let envelope = try? JSONDecoder().decode(GeminiFileEnvelope.self, from: finishData) {
            return envelope.file
        }
        throw StudyNoteError.invalidResponse
    }

    func waitUntilActive(
        _ file: GeminiUploadedFile,
        onRetry: RetryObserver?
    ) async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(file.name)") else {
            throw StudyNoteError.invalidResponse
        }
        for _ in 0..<150 {
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await requestData(for: request, onRetry: onRetry)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { throw try error(from: response, data: data) }
            let current: GeminiUploadedFile
            if let file = try? JSONDecoder().decode(GeminiUploadedFile.self, from: data) {
                current = file
            } else if let envelope = try? JSONDecoder().decode(GeminiFileEnvelope.self, from: data) {
                current = envelope.file
            } else {
                throw StudyNoteError.invalidResponse
            }
            let state = current.state?.uppercased() ?? "ACTIVE"
            if state == "ACTIVE" { return }
            if state == "FAILED" || state == "ERROR" { throw StudyNoteError.invalidResponse }
            try await Task.sleep(for: .seconds(2))
        }
        throw StudyNoteError.invalidResponse
    }

    private func createCache(
        for file: GeminiUploadedFile,
        onRetry: RetryObserver?
    ) async throws -> GeminiCachedContent {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/cachedContents") else {
            throw StudyNoteError.cacheFailure("缓存请求地址无效。")
        }
        let body: [String: Any] = [
            "model": "models/\(Self.model)",
            "displayName": "PaperLibrary 精读 PDF",
            "contents": [[
                "role": "user",
                "parts": [[
                    "fileData": [
                        "fileUri": file.uri,
                        "mimeType": file.mimeType ?? "application/pdf"
                    ]
                ]]
            ]],
            "ttl": "\(Self.cacheTTLSeconds)s"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await requestData(for: request, onRetry: onRetry)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw try error(from: response, data: data)
        }
        do {
            return try JSONDecoder().decode(GeminiCachedContent.self, from: data)
        } catch {
            throw StudyNoteError.cacheFailure(
                "服务返回成功，但缓存信息无法解析：\(String(decoding: data.prefix(800), as: UTF8.self))"
            )
        }
    }

    private func delete(_ cache: GeminiCachedContent) async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(cache.name)") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw try error(from: response, data: data)
        }
    }

    func delete(_ file: GeminiUploadedFile) async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(file.name)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw try error(from: response, data: data)
        }
    }

    private func recognizePartCountWithLite(
        in outline: String,
        onRetry: RetryObserver?
    ) async throws -> (count: Int, usage: StudyNoteUsage) {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedModel = Self.outlineRecognizerModel.addingPercentEncoding(
            withAllowedCharacters: allowed
        ), let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent"
        ) else {
            throw StudyNoteError.invalidOutline("轻量模型请求地址无效。")
        }

        let prompt = """
        下面是一份精读笔记的章节目录。请只输出其中一级章节的总数，只能输出一个阿拉伯数字，不要附加任何文字、标点或 Markdown。若无法判断则输出 0。

        \(outline)
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 16]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await requestData(for: request, onRetry: onRetry)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw try error(from: response, data: data)
        }
        let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
        guard let text = envelope.candidates.first?.content.parts.compactMap(\.text).joined() else {
            throw StudyNoteError.invalidOutline("轻量模型没有返回可读取的内容，候选回复数为 \(envelope.candidates.count)。")
        }
        guard let count = Self.partCountFromLiteResponse(text) else {
            throw StudyNoteError.invalidOutline(
                "轻量模型返回“\(Self.responsePreview(text))”，期望 1 至 99 的单个阿拉伯数字。"
            )
        }

        let inputTokens = envelope.usageMetadata?.promptTokenCount ?? 0
        let outputTokens = max(
            envelope.usageMetadata?.candidatesTokenCount ?? 0,
            (envelope.usageMetadata?.totalTokenCount ?? 0) - inputTokens
        )
        return (
            count,
            StudyNoteUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: envelope.usageMetadata?.totalTokenCount ?? 0,
                cachedInputTokens: envelope.usageMetadata?.cachedContentTokenCount ?? 0,
                billingSource: .lite
            )
        )
    }

    static func partCountFromLiteResponse(_ response: String) -> Int? {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(value), (1...99).contains(count) else { return nil }
        return count
    }

    private struct StreamResult {
        let answer: String
        let usage: StudyNoteUsage
        let thinkingStrength: Int
    }

    /// 完整保留 Python 脚本的三次尝试规则：一旦正文先于思考摘要到达，即丢弃这次
    /// 流，绝不把它写入历史或本地草稿，并用原脚本的提示语重试。
    private func generateWithThinking(
        basePrompt: String,
        remoteFile: GeminiUploadedFile?,
        cachedContentName: String?,
        history: inout [[String: Any]],
        initialThinkingStrength: Int = 0,
        onRetry: RetryObserver? = nil
    ) async throws -> StreamResult {
        for attempt in 0..<3 {
            let thinkingStrength = min(max(initialThinkingStrength + attempt, 0), 5)
            let prompt = Self.promptForThinkingStrength(
                basePrompt: basePrompt,
                strength: thinkingStrength
            )
            let userContent = Self.userContent(prompt: prompt, remoteFile: remoteFile)
            let outcome = try await retryingTransientFailures(onRetry: onRetry) {
                try await streamGenerate(
                    contents: history + [userContent],
                    cachedContentName: cachedContentName
                )
            }
            switch outcome {
            case let .success(answer, usage, modelContent):
                history.append(userContent)
                history.append(modelContent)
                return .init(answer: answer, usage: usage, thinkingStrength: thinkingStrength)
            case .answerBeforeThought:
                continue
            }
        }
        throw StudyNoteError.invalidResponse
    }

    private enum StreamOutcome {
        case success(String, StudyNoteUsage, [String: Any])
        case answerBeforeThought
    }

    /// `URLSession.bytes(for:)` 不暴露底层任务，无法在发现正文抢跑时主动取消。
    /// 这里保留可取消的数据任务，使“丢弃本轮”同时断开网络请求。
    private final class SSEDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var response: URLResponse?
        private var responseWaiter: CheckedContinuation<URLResponse, Error>?
        private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?

        func dataStream() -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                lock.lock()
                streamContinuation = continuation
                lock.unlock()
            }
        }

        func waitForResponse() async throws -> URLResponse {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let response {
                    lock.unlock()
                    continuation.resume(returning: response)
                } else {
                    responseWaiter = continuation
                    lock.unlock()
                }
            }
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            lock.lock()
            self.response = response
            let waiter = responseWaiter
            responseWaiter = nil
            lock.unlock()
            waiter?.resume(returning: response)
            completionHandler(.allow)
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let continuation = streamContinuation
            lock.unlock()
            continuation?.yield(data)
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            let waiter = responseWaiter
            responseWaiter = nil
            let continuation = streamContinuation
            streamContinuation = nil
            lock.unlock()
            if let error {
                waiter?.resume(throwing: error)
                continuation?.finish(throwing: error)
            } else {
                if waiter != nil { waiter?.resume(throwing: StudyNoteError.invalidResponse) }
                continuation?.finish()
            }
        }
    }

    private func streamGenerate(
        contents: [[String: Any]],
        cachedContentName: String?
    ) async throws -> StreamOutcome {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):streamGenerateContent?alt=sse")!
        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": 1.0,
                "topP": 0.95,
                "topK": 64,
                "maxOutputTokens": 65_536,
                "thinkingConfig": [
                    "includeThoughts": true,
                    "thinkingLevel": "HIGH"
                ]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "OFF"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "OFF"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "OFF"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "OFF"]
            ]
        ]
        if let cachedContentName {
            body["cachedContent"] = cachedContentName
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let delegate = SSEDataTaskDelegate()
        let streamSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let dataStream = delegate.dataStream()
        let task = streamSession.dataTask(with: request)
        let cancelRequest: @Sendable () -> Void = {
            task.cancel()
            streamSession.invalidateAndCancel()
        }
        defer { cancelRequest() }

        task.resume()
        let response = try await withTaskCancellationHandler(operation: {
            try await delegate.waitForResponse()
        }, onCancel: cancelRequest)
        return try await withTaskCancellationHandler(operation: {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await chunk in dataStream { data.append(chunk) }
                throw try error(from: response, data: data)
            }

            var thoughtSeen = false
            var answer = ""
            var finishReason = ""
            var usage = StudyNoteUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
            var modelParts: [[String: Any]] = []
            var eventData: [String] = []
            var lineBuffer = Data()

            func consume(_ data: String) throws -> Bool {
                guard !data.isEmpty,
                      let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                      let candidate = (object["candidates"] as? [[String: Any]])?.first
                else { return false }
                if let reason = candidate["finishReason"] as? String, !reason.isEmpty {
                    finishReason = reason
                }
                if let content = candidate["content"] as? [String: Any] {
                    for part in content["parts"] as? [[String: Any]] ?? [] {
                        // 后续请求必须携带这一轮完整的模型内容（包括思考签名），而不是
                        // 只带最后一个 SSE 片段；这与 Python 聊天对象保存的历史一致。
                        modelParts.append(part)
                        guard let text = part["text"] as? String, !text.isEmpty else { continue }
                        if (part["thought"] as? Bool) == true {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thoughtSeen = true }
                        } else if !thoughtSeen {
                            return true
                        } else {
                            answer += text
                        }
                    }
                }
                if let metadata = object["usageMetadata"] as? [String: Any] {
                    let input = (metadata["promptTokenCount"] as? NSNumber)?.intValue ?? 0
                    let output = (metadata["candidatesTokenCount"] as? NSNumber)?.intValue ?? 0
                    let total = (metadata["totalTokenCount"] as? NSNumber)?.intValue ?? 0
                    let cached = (metadata["cachedContentTokenCount"] as? NSNumber)?.intValue ?? 0
                    usage = .init(
                        inputTokens: input,
                        outputTokens: output,
                        totalTokens: total,
                        cachedInputTokens: cached
                    )
                }
                return false
            }

            func consumeLine(_ rawLine: String) throws -> Bool {
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if line.isEmpty {
                    if try consume(eventData.joined(separator: "\n")) { return true }
                    eventData.removeAll(keepingCapacity: true)
                } else if line.hasPrefix("data:") {
                    eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
                return false
            }

            for try await chunk in dataStream {
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: 10) {
                    let line = String(decoding: lineBuffer[..<newline], as: UTF8.self)
                    lineBuffer.removeSubrange(...newline)
                    if try consumeLine(line) {
                        // 发现正文先于思考摘要的当下主动断开连接，避免仅停止本地解析。
                        cancelRequest()
                        return .answerBeforeThought
                    }
                }
            }
            if !lineBuffer.isEmpty,
               try consumeLine(String(decoding: lineBuffer, as: UTF8.self)) {
                cancelRequest()
                return .answerBeforeThought
            }
            if try consume(eventData.joined(separator: "\n")) {
                cancelRequest()
                return .answerBeforeThought
            }
            guard thoughtSeen,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  finishReason == "STOP",
                  !modelParts.isEmpty
            else { throw StudyNoteError.invalidResponse }
            return .success(answer, usage, ["role": "model", "parts": modelParts])
        }, onCancel: cancelRequest)
    }

    private static func userContent(prompt: String, remoteFile: GeminiUploadedFile?) -> [String: Any] {
        var parts: [[String: Any]] = []
        if let remoteFile {
            parts.append([
                "fileData": [
                    "fileUri": remoteFile.uri,
                    "mimeType": remoteFile.mimeType ?? "application/pdf"
                ]
            ])
        }
        parts.append(["text": prompt])
        return ["role": "user", "parts": parts]
    }

    private func requestData(
        for request: URLRequest,
        onRetry: RetryObserver?
    ) async throws -> (Data, URLResponse) {
        try await retryingTransientFailures(onRetry: onRetry) {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw try error(from: response, data: data)
            }
            return (data, response)
        }
    }

    private func retryingTransientFailures<T>(
        onRetry: RetryObserver?,
        operation: () async throws -> T
    ) async throws -> T {
        var retryIndex = 0
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard retryIndex < StudyNoteNetworkRetryPolicy.retryDelays.count,
                      StudyNoteNetworkRetryPolicy.isTransient(error)
                else { throw error }
                let delay = StudyNoteNetworkRetryPolicy.retryDelays[retryIndex]
                retryIndex += 1
                try await onRetry?(retryIndex, delay, error)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func error(from response: URLResponse, data: Data) throws -> Error {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let message = String(decoding: data, as: UTF8.self)
        return StudyNoteError.httpStatus(code, message.prefix(800).description)
    }

    static func partCount(in outline: String) throws -> Int {
        let lines = outline.components(separatedBy: .newlines)
        let headingValues = lines.compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let title = trimmed.drop { $0 == "#" || $0.isWhitespace }
            return leadingPartNumber(in: String(title))
        }
        // 有些模型会把目录写成有序列表。仅在没有可识别的 Markdown 标题时使用
        // 这一回退规则，避免把某一部分内部的普通列表误判为章节。
        let values = headingValues.isEmpty ? lines.compactMap(orderedListPartNumber(in:)) : headingValues
        let unique = Array(Set(values)).sorted()
        guard let last = unique.last, unique == Array(1...last) else {
            let source = headingValues.isEmpty ? "有序列表" : "一级标题"
            throw StudyNoteError.invalidOutline(
                "使用\(source)识别到的章节编号为 \(unique)。期望从 1 开始连续编号；原始回复共 \(lines.count) 行，摘要：“\(responsePreview(outline))”。"
            )
        }
        return last
    }

    private static func responsePreview(_ response: String, limit: Int = 300) -> String {
        let normalized = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↩ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    static func isValidPart(_ text: String, number: Int) -> Bool {
        let pattern = #"(?m)^#(?!#)\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard matches.count == 1,
              let titleRange = Range(matches[0].range(at: 1), in: text)
        else { return false }
        let title = String(text[titleRange])
        return leadingPartNumber(in: title) == number
    }

    private static func orderedListPartNumber(in line: String) -> Int? {
        let normalized = line.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? line
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\s*[.、:：)）-]\s+"#),
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized)
        else { return nil }
        return Int(normalized[range])
    }

    private static func leadingPartNumber(in title: String) -> Int? {
        let normalized = title.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? title
        let patterns = [
            #"(?i)^(?:part\s*)?(\d+)(?:\b|\s*[:：.、\-—])"#,
            #"^第\s*(\d+)\s*(?:部分|章|节)?(?:\b|\s*[:：.、\-—])"#,
            #"^第\s*([零一二三四五六七八九十百]+)\s*(?:部分|章|节)?(?:\b|\s*[:：.、\-—])"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)
                  ),
                  let range = Range(match.range(at: 1), in: normalized)
            else { continue }
            let value = String(normalized[range])
            if let number = Int(value) { return number }
            if let number = chineseNumber(value) { return number }
        }
        return nil
    }

    private static func chineseNumber(_ value: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if let tensIndex = value.firstIndex(of: "十") {
            let prefix = String(value[..<tensIndex])
            let suffix = String(value[value.index(after: tensIndex)...])
            let tens = prefix.isEmpty ? 1 : (prefix.first.flatMap { digits[$0] } ?? -1)
            let ones = suffix.isEmpty ? 0 : (suffix.first.flatMap { digits[$0] } ?? -1)
            guard tens >= 0, ones >= 0, suffix.count <= 1 else { return nil }
            return tens * 10 + ones
        }
        guard value.count == 1, let character = value.first else { return nil }
        return digits[character]
    }

    static let outlinePrompt = """
    你能不能帮我整理一下这篇文章出现的所有重要内容，以及增加一些原文省略但理解时必要的推导过程、背景说明、直觉解释和例子，以及检查并修正可能存在的推导或表述错误，方便我这种理解困难的学生阅读和复习。我读原文比较吃力，尤其经常不知道作者为什么突然引入某个概念、公式、假设、方法或讨论，所以请特别帮助我解释每一部分“在做什么”“为什么要这样做”以及“它和前后内容是什么关系”。由于文章中的概念、公式、推导和论述可能过多，一次性生成不完，所以我们这样办：你先完整阅读文章，把所有需要讲解的内容按照文章本身的逻辑和内容类型分为若干部分，并列出每一部分需要讲解的内容，然后我们再一部分一部分生成。划分时不要强行套用固定框架，而应该根据文章实际内容决定如何划分；如果文章包含理论、实证、证明、例子、制度背景、方法讨论、数据分析或其他内容，就按照它们在原文中的实际作用进行组织，如果没有某一类内容，则完全不需要加入。注意不要遗漏任何对理解原文有实质作用的内容。对于原文中作者默认读者已经知道、但实际上理解文章所需要的背景知识，也请列入相应部分。请把之后要生成的每一个 Part 都设计为一个独立的一级标题，也就是说正式讲解时每一部分都应当使用 Markdown 一级标题 #，Part 内部再根据内容需要使用二级标题 ##、三级标题 ### 等。现在先不要正式生成讲解，只列出完整的分部分方案以及每一部分需要涵盖的内容。输出格式必须严格为从 `# Part 1：标题` 开始的连续一级标题，依次使用 `# Part 2：标题`、`# Part 3：标题`；不要使用“第一部分”、编号列表或任何导言。
    """.trimmingCharacters(in: .newlines)

    static let outlineFormatRetryPrompt = """
    你刚才的章节方案格式无法被程序识别。不要解释、不要重复导言、不要生成正文，只重新输出完整的章节目录。每个章节必须独占一个 Markdown 一级标题，并严格按 `# Part 1：标题`、`# Part 2：标题`、`# Part 3：标题` 的连续格式编号；标题下可用普通列表简述覆盖内容。不要使用“第一部分”、`##` 标题或有序列表作为章节标题。
    """

    static let firstPartPrompt = """
    请用中文完成，越详细越好。请注意一定不要改变原文中的 notation，不要遗漏原始文章中的任何重要信息，每一点有实质意义的内容都需要进行解释。注意这是一个面向理解困难读者的讲解，而不是摘要、翻译或简单改写，所以你需要讲清楚任何可能存在疑问的地方。尤其注意：当原文出现新的概念、定义、公式、假设、推导、方法、结论或讨论时，不要只告诉我“它是什么”，还要尽量解释作者为什么在这里引入它、它想解决什么问题、它与前后内容有什么关系，以及它之后有什么作用；如果某一内容本身不适合这样分析，则按照原文本身最自然的方式解释，不要强行套用固定模板。如果原文省略了理解所需要的中间步骤、推导、背景知识或直觉，请补充出来；如果一个抽象内容可以通过简单例子帮助理解，也请补充例子，但补充内容必须服务于理解原文，不要无关扩展。请区分原文真正表达的内容与你为了帮助理解而增加的解释，不要把你的补充内容误写成作者原本的结论。在正式输出前，请先自行检查文章里的推导、公式和逻辑是否正确，如果发现错误或明显不严谨的地方，不要悄悄修改原文含义，而是在讲解中说明原来的做法、问题在哪里，以及正确的理解或推导。请使用清晰、自然的 Markdown 结构组织内容。当前生成的这一整个 Part 必须使用一个 Markdown 一级标题 # 作为标题，Part 内部再根据内容需要使用二级标题 ##、三级标题 ### 等，不要在同一个 Part 中再使用其他一级标题。可以使用列表、粗体、斜体、引用块和公式，但不要为了格式而把内容切得过碎。数学公式请保持原文 notation，并使用标准 Markdown/LaTeX 数学公式格式。请忽略所有引用要求，绝对不要在正文中提及“Source X”“Page X”“参考文献”或“[cite]”，将所有来源信息内化为你自己的讲解。现在请生成第一部分。
    """.trimmingCharacters(in: .newlines)

    static let nextPartPrompt = """
    非常好！现在请生成下一部分，越详细越好，只需要新的部分，不要重复之前已经生成的内容。请注意一定不要改变原文中的 notation，不要遗漏原始文章中的任何重要信息，每一点有实质意义的内容都需要进行解释。注意这是一个讲解，而不是摘要，所以你需要讲清楚任何可能存在疑问的地方。尤其注意解释作者现在在做什么、为什么要这样做、这一内容和前后文有什么关系；如果某一段内容本身不适合按照这种方式分析，就按照原文本身最自然的逻辑解释，不要强行套用固定模板。如果原文省略了理解所必要的推导步骤、背景知识、直觉解释或简单例子，请补充出来，但不要改变作者原本的 notation 和结论。请区分原文内容与你为了帮助理解而增加的补充说明，不要把补充内容写成作者原本明确表达的观点。在正式输出前，请先自行检查这一部分中的推导、公式和逻辑是否正确，如果发现问题，请说明并进行正确解释，不要无声修改原文含义。请继续使用清晰、自然的 Markdown 结构。当前生成的这一整个 Part 必须使用一个 Markdown 一级标题 # 作为标题，Part 内部再根据内容需要使用二级标题 ##、三级标题 ### 等，不要在同一个 Part 中再使用其他一级标题。可以使用列表、粗体、斜体、引用块和公式，但不要为了格式而把内容切得过碎。数学公式请保持原文 notation，并使用标准 Markdown/LaTeX 数学公式格式。请忽略所有引用要求，绝对不要在正文中提及“Source X”“Page X”“参考文献”或“[cite]”，将所有来源信息内化为你自己的讲解。只生成新的部分，现在请开始你的思考：
    """.trimmingCharacters(in: .newlines)

    static func resumePrompt(context: StudyNoteResumeContext, nextPart: Int) -> String {
        """
        这是一次中断后的精读笔记续写。原计划共有 \(context.totalParts) 个部分，已经完整保存第 1 至第 \(context.completedParts) 部分。请结合上传的完整 PDF、原章节规划和已有正文，只生成第 \(nextPart) 部分。不得重复、改写或概括已经完成的部分，也不要重新输出目录。

        原章节规划：
        \(context.outline)

        已完成正文：
        \(context.existingDraft)

        新部分必须使用且仅使用一个 Markdown 一级标题，标题编号必须是第 \(nextPart) 部分。其余讲解要求与此前相同：内容要详细，解释作者在做什么、为什么这样做、与前后内容的关系，保持原文 notation，并补充理解所需的推导、背景和直觉。只输出新的第 \(nextPart) 部分，现在请开始你的思考：
        """.trimmingCharacters(in: .newlines)
    }

    static func promptForAttempt(basePrompt: String, attempt: Int) -> String {
        precondition((1...3).contains(attempt))
        return promptForThinkingStrength(basePrompt: basePrompt, strength: attempt - 1)
    }

    static func promptForThinkingStrength(basePrompt: String, strength: Int) -> String {
        let clampedStrength = min(max(strength, 0), thinkingSuffixes.count - 1)
        guard clampedStrength > 0 else { return basePrompt }
        let baseSuffix = thinkingSuffixes[0]
        let suffix = thinkingSuffixes[clampedStrength]
        if basePrompt.hasSuffix(baseSuffix) {
            return String(basePrompt.dropLast(baseSuffix.count)) + suffix
        }
        return basePrompt + suffix
    }

    private static let thinkingSuffixes = [
        "现在请开始你的思考：",
        "请记住一定要先思考再输出，现在请开始你的思考：",
        "严禁直接输出结果。必须先进行充分思考，确认完成思考后再输出。请记住一定要先思考再输出，现在请开始你的思考：",
        "严禁跳过思考或直接输出正文。必须先进行充分、独立的思考，确认关键内容已经想清楚后，才可以开始输出正文。请先完成思考，再输出正文：",
        "这是强制要求：在完成充分思考之前，禁止输出任何正文、标题或结论。请先仔细思考文章内容、结构和推导，确认思考完成后再输出正文：",
        "最高优先级要求：绝对不得直接生成正文。你必须先进行完整而深入的思考；只有确认思考已经完成后，才允许输出正文。若不能先思考，则不要输出正文："
    ]
}
struct GeminiEnvelope: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]
        }
        let content: Content
    }
    struct Usage: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
    let candidates: [Candidate]
    let usageMetadata: Usage?
}

struct GeminiErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

struct GeminiTokenCountResponse: Decodable {
    let totalTokens: Int
}
