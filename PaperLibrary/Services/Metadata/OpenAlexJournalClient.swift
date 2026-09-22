import Foundation
import SwiftData

struct OpenAlexJournalMetrics: Codable, Sendable, Equatable {
    enum MatchMethod: String, Codable, Sendable {
        case doi
        case journalTitle

        var localizedName: String {
            switch self {
            case .doi: return "DOI 精确匹配"
            case .journalTitle: return "期刊名称匹配"
            }
        }
    }

    let sourceID: String
    let sourceName: String
    let issnL: String?
    let issns: [String]
    let twoYearMeanCitedness: Double?
    let hIndex: Int?
    let i10Index: Int?
    let worksCount: Int
    let citedByCount: Int
    let sourceUpdatedDate: String?
    let fetchedAt: Date
    let matchMethod: MatchMethod
    let requestedDOI: String?
    let requestedJournal: String?

    var sourceURL: URL? {
        let key = sourceID.split(separator: "/").last.map(String.init) ?? sourceID
        return URL(string: "https://openalex.org/\(key)")
    }

    func matches(doi: String?, journal: String?) -> Bool {
        if let requestedDOI {
            return PDFMetadataExtractor.normalizedDOI(doi) == requestedDOI
        }
        guard let requestedJournal else { return false }
        return Self.normalizedTitle(journal) == Self.normalizedTitle(requestedJournal)
    }

    private static func normalizedTitle(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum OpenAlexJournalError: LocalizedError {
    case invalidRequest(String)
    case invalidResponse(stage: String, detail: String)
    case httpStatus(stage: String, status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(detail):
            return "OpenAlex 请求无法建立：\(detail)"
        case let .invalidResponse(stage, detail):
            return "OpenAlex 在\(stage)阶段返回了无法识别的数据：\(detail)"
        case let .httpStatus(stage, status, detail):
            let suffix = detail.isEmpty ? "" : " 响应内容：\(detail)"
            return "OpenAlex 在\(stage)阶段请求失败，状态码为 \(status)。\(suffix)"
        }
    }
}

actor OpenAlexJournalClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lookup(doi: String?, journal: String?) async throws -> OpenAlexJournalMetrics? {
        let normalizedDOI = PDFMetadataExtractor.normalizedDOI(doi)
        if let normalizedDOI,
           let sourceID = try await sourceID(forDOI: normalizedDOI),
           let source = try await source(id: sourceID) {
            return source.metrics(
                matchMethod: .doi,
                requestedDOI: normalizedDOI,
                requestedJournal: journal
            )
        }

        let trimmedJournal = journal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedJournal.isEmpty,
              let candidate = try await sourceCandidate(named: trimmedJournal),
              let source = try await source(id: candidate.id)
        else { return nil }
        return source.metrics(
            matchMethod: .journalTitle,
            requestedDOI: nil,
            requestedJournal: trimmedJournal
        )
    }

    private func sourceID(forDOI doi: String) async throws -> String? {
        var components = URLComponents(string: "https://api.openalex.org")!
        components.path = "/works/doi:\(doi)"
        components.queryItems = [URLQueryItem(name: "select", value: "primary_location")]
        guard let url = components.url else {
            throw OpenAlexJournalError.invalidRequest("DOI 包含无法编码的字符。")
        }
        do {
            let data = try await request(url, stage: "按 DOI 查找论文")
            let work = try JSONDecoder().decode(OpenAlexWork.self, from: data)
            guard work.primaryLocation?.source?.type == "journal" else { return nil }
            return work.primaryLocation?.source?.id
        } catch OpenAlexJournalError.httpStatus(_, 404, _) {
            return nil
        } catch let error as DecodingError {
            throw OpenAlexJournalError.invalidResponse(
                stage: "按 DOI 查找论文",
                detail: decodingDetail(error)
            )
        }
    }

    private func sourceCandidate(named journal: String) async throws -> OpenAlexSourceSummary? {
        var components = URLComponents(string: "https://api.openalex.org/sources")!
        components.queryItems = [
            URLQueryItem(name: "search", value: journal),
            URLQueryItem(name: "filter", value: "type:journal"),
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "select", value: "id,display_name,alternate_titles,type"),
        ]
        guard let url = components.url else {
            throw OpenAlexJournalError.invalidRequest("期刊名称包含无法编码的字符。")
        }
        do {
            let data = try await request(url, stage: "按期刊名称查找")
            let envelope = try JSONDecoder().decode(OpenAlexSourceSearchEnvelope.self, from: data)
            let ranked = envelope.results
                .filter { $0.type == "journal" }
                .map { ($0, titleSimilarity(journal, $0.displayName, alternatives: $0.alternateTitles ?? [])) }
                .filter { $0.1 >= 0.72 }
                .sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { return nil }
            if ranked.count > 1, best.1 - ranked[1].1 < 0.08, best.1 < 0.98 {
                return nil
            }
            return best.0
        } catch let error as DecodingError {
            throw OpenAlexJournalError.invalidResponse(
                stage: "按期刊名称查找",
                detail: decodingDetail(error)
            )
        }
    }

    private func source(id: String) async throws -> OpenAlexSource? {
        let sourceKey = id.split(separator: "/").last.map(String.init) ?? id
        guard sourceKey.hasPrefix("S") else {
            throw OpenAlexJournalError.invalidResponse(
                stage: "读取期刊标识符",
                detail: "返回的标识符不是有效的期刊来源编号：\(id)"
            )
        }
        var components = URLComponents(string: "https://api.openalex.org/sources/\(sourceKey)")!
        components.queryItems = [URLQueryItem(
            name: "select",
            value: "id,display_name,issn_l,issn,type,summary_stats,works_count,cited_by_count,updated_date"
        )]
        guard let url = components.url else {
            throw OpenAlexJournalError.invalidRequest("期刊来源编号无法编码：\(sourceKey)")
        }
        do {
            let data = try await request(url, stage: "读取期刊评价")
            let source = try JSONDecoder().decode(OpenAlexSource.self, from: data)
            return source.type == "journal" ? source : nil
        } catch OpenAlexJournalError.httpStatus(_, 404, _) {
            return nil
        } catch let error as DecodingError {
            throw OpenAlexJournalError.invalidResponse(
                stage: "读取期刊评价",
                detail: decodingDetail(error)
            )
        }
    }

    private func request(_ url: URL, stage: String) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("PaperLibrary/0.1", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAlexJournalError.invalidResponse(stage: stage, detail: "缺少 HTTP 响应。")
            }
            if http.statusCode == 200 { return data }
            if (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
                continue
            }
            throw OpenAlexJournalError.httpStatus(
                stage: stage,
                status: http.statusCode,
                detail: responseDetail(data)
            )
        }
        throw OpenAlexJournalError.invalidResponse(stage: stage, detail: "重试后仍未获得响应。")
    }

    private func responseDetail(_ data: Data) -> String {
        String(decoding: data.prefix(600), as: UTF8.self)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func titleSimilarity(
        _ requested: String,
        _ candidate: String,
        alternatives: [String]
    ) -> Double {
        ([candidate] + alternatives).map { jaccardSimilarity(requested, $0) }.max() ?? 0
    }

    private func jaccardSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func tokens(_ value: String) -> Set<String> {
            Set(value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0 != "the" })
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            return "缺少字段 \(key.stringValue)，位置 \(codingPath(context.codingPath))。"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "字段类型不符，位置 \(codingPath(context.codingPath))：\(context.debugDescription)"
        case let .dataCorrupted(context):
            return "数据损坏，位置 \(codingPath(context.codingPath))：\(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func codingPath(_ path: [CodingKey]) -> String {
        path.map(\.stringValue).joined(separator: ".")
    }
}

@MainActor
final class OpenAlexJournalMetricsCoordinator: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var lookupMessage: String?
    @Published var errorText: String?

    private static let client = OpenAlexJournalClient()
    private let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
    private let unsuccessfulRetryInterval: TimeInterval = 7 * 24 * 60 * 60

    func refresh(work: Work, modelContext: ModelContext, force: Bool = false) async {
        guard !isLoading else { return }
        let hasIdentifier = PDFMetadataExtractor.normalizedDOI(work.doi) != nil
        let hasJournal = !(work.journal ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasIdentifier || hasJournal else {
            lookupMessage = "需要 DOI 或期刊名称才能查询 OpenAlex。"
            return
        }
        if !force {
            if let metrics = work.openAlexJournalMetrics,
               Date().timeIntervalSince(metrics.fetchedAt) < refreshInterval {
                return
            }
            if work.openAlexJournalMetrics == nil,
               let attemptedAt = work.openAlexJournalLookupAttemptedAt,
               Date().timeIntervalSince(attemptedAt) < unsuccessfulRetryInterval {
                lookupMessage = "最近一次查询未找到匹配期刊，可使用刷新按钮重新查询。"
                return
            }
        }

        isLoading = true
        errorText = nil
        lookupMessage = nil
        defer { isLoading = false }
        do {
            let metrics = try await Self.client.lookup(doi: work.doi, journal: work.journal)
            work.openAlexJournalLookupAttemptedAt = .now
            if let metrics {
                work.openAlexJournalMetricsJSON = String(
                    decoding: try JSONEncoder().encode(metrics),
                    as: UTF8.self
                )
                lookupMessage = nil
            } else {
                work.openAlexJournalMetricsJSON = nil
                lookupMessage = "OpenAlex 未找到与当前 DOI 或期刊名称可靠匹配的期刊。"
            }
            try modelContext.save()
        } catch is CancellationError {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct OpenAlexWork: Decodable {
    struct Location: Decodable {
        let source: OpenAlexWorkSource?
    }

    let primaryLocation: Location?

    enum CodingKeys: String, CodingKey {
        case primaryLocation = "primary_location"
    }
}

private struct OpenAlexWorkSource: Decodable {
    let id: String
    let type: String?
}

private struct OpenAlexSourceSearchEnvelope: Decodable {
    let results: [OpenAlexSourceSummary]
}

private struct OpenAlexSourceSummary: Decodable {
    let id: String
    let displayName: String
    let alternateTitles: [String]?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name"
        case alternateTitles = "alternate_titles"
    }
}

private struct OpenAlexSource: Decodable {
    struct SummaryStats: Decodable {
        let twoYearMeanCitedness: Double?
        let hIndex: Int?
        let i10Index: Int?

        enum CodingKeys: String, CodingKey {
            case twoYearMeanCitedness = "2yr_mean_citedness"
            case hIndex = "h_index"
            case i10Index = "i10_index"
        }
    }

    let id: String
    let displayName: String
    let issnL: String?
    let issn: [String]?
    let type: String?
    let summaryStats: SummaryStats?
    let worksCount: Int
    let citedByCount: Int
    let updatedDate: String?

    enum CodingKeys: String, CodingKey {
        case id, issn, type
        case displayName = "display_name"
        case issnL = "issn_l"
        case summaryStats = "summary_stats"
        case worksCount = "works_count"
        case citedByCount = "cited_by_count"
        case updatedDate = "updated_date"
    }

    func metrics(
        matchMethod: OpenAlexJournalMetrics.MatchMethod,
        requestedDOI: String?,
        requestedJournal: String?
    ) -> OpenAlexJournalMetrics {
        OpenAlexJournalMetrics(
            sourceID: id,
            sourceName: displayName,
            issnL: issnL,
            issns: issn ?? [],
            twoYearMeanCitedness: summaryStats?.twoYearMeanCitedness,
            hIndex: summaryStats?.hIndex,
            i10Index: summaryStats?.i10Index,
            worksCount: worksCount,
            citedByCount: citedByCount,
            sourceUpdatedDate: updatedDate,
            fetchedAt: .now,
            matchMethod: matchMethod,
            requestedDOI: requestedDOI,
            requestedJournal: requestedJournal
        )
    }
}
