import Foundation

struct BibliographicSnapshot: Sendable, Equatable {
    let title: String
    let authorsText: String
    let publicationYear: Int?
    let doi: String?
    let journal: String?
}

struct RemoteBibTeXRecord: Sendable, Equatable {
    let entry: BibTeXEntry
    let metadata: BibliographicSnapshot
    let sourceName: String
}

struct BibTeXDifference: Identifiable, Sendable, Equatable {
    let field: String
    let localValue: String
    let onlineValue: String

    var id: String { field }
}

enum BibTeXRemoteError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case notFound
    case invalidBibTeX
    case incompleteBibTeX

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "在线书目服务返回了无法识别的响应。"
        case let .httpStatus(status):
            return "在线书目请求失败，状态码为 \(status)。"
        case .notFound:
            return "在线书目服务没有找到足够可信的匹配记录。"
        case .invalidBibTeX:
            return "在线服务返回的 BibTeX 格式无效。"
        case .incompleteBibTeX:
            return "在线 BibTeX 缺少作者、年份或标题，无法生成引用键。"
        }
    }
}

protocol BibTeXRemoteFetching: Sendable {
    func fetch(
        for local: BibliographicSnapshot,
        contactEmail: String?
    ) async throws -> RemoteBibTeXRecord
}

actor BibTeXRemoteClient: BibTeXRemoteFetching {
    private let session: URLSession
    private let crossref: CrossrefClient

    init(session: URLSession = .shared) {
        self.session = session
        crossref = CrossrefClient(session: session)
    }

    func fetch(
        for local: BibliographicSnapshot,
        contactEmail: String?
    ) async throws -> RemoteBibTeXRecord {
        var doi = PDFMetadataExtractor.normalizedDOI(local.doi)
        if doi == nil {
            let metadata = try await crossref.lookup(
                doi: nil,
                title: local.title,
                author: local.authorsText,
                publicationYear: local.publicationYear,
                contactEmail: contactEmail,
                forceRefresh: true
            )
            doi = metadata?.doi
        }

        if let doi {
            do {
                return try await fetchFromDOI(doi, contactEmail: contactEmail)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let semantic = try? await fetchFromSemanticScholar(local, doi: doi) {
                    return semantic
                }
                throw error
            }
        }

        return try await fetchFromSemanticScholar(local, doi: nil)
    }

    private func fetchFromDOI(
        _ doi: String,
        contactEmail: String?
    ) async throws -> RemoteBibTeXRecord {
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://doi.org/\(encodedDOI)")
        else { throw BibTeXRemoteError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/x-bibtex", forHTTPHeaderField: "Accept")
        let contact = contactEmail.map { "mailto:\($0)" } ?? "no-contact"
        request.setValue("PaperLibrary/0.1 (\(contact))", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let data = try await responseData(for: request)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw BibTeXRemoteError.invalidResponse
        }
        return try makeRemoteRecord(rawBibTeX: raw, suppliedDOI: doi, sourceName: "DOI")
    }

    private func fetchFromSemanticScholar(
        _ local: BibliographicSnapshot,
        doi: String?
    ) async throws -> RemoteBibTeXRecord {
        let fields = "title,authors,year,externalIds,citationStyles,journal"
        let data: Data
        if let doi {
            let identifier = "DOI:\(doi)"
            let allowed = CharacterSet.urlPathAllowed
                .subtracting(CharacterSet(charactersIn: "/"))
            guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "https://api.semanticscholar.org/graph/v1/paper/\(encoded)?fields=\(fields)")
            else { throw BibTeXRemoteError.invalidResponse }
            data = try await responseData(for: URLRequest(url: url))
            let paper = try JSONDecoder().decode(SemanticScholarPaper.self, from: data)
            return try makeSemanticScholarRecord(paper)
        }

        var components = URLComponents(
            string: "https://api.semanticscholar.org/graph/v1/paper/search"
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: local.title),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fields", value: fields),
        ]
        guard let url = components.url else { throw BibTeXRemoteError.invalidResponse }
        data = try await responseData(for: URLRequest(url: url))
        let envelope = try JSONDecoder().decode(SemanticScholarSearchEnvelope.self, from: data)
        let ranked = envelope.data.compactMap { paper -> (SemanticScholarPaper, Double)? in
            let score = BibTeXComparisonRules.titleSimilarity(local.title, paper.title)
            guard score >= 0.72 else { return nil }
            let remoteAuthors = paper.authors.map(\.name).joined(separator: "; ")
            if !local.authorsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !remoteAuthors.isEmpty,
               BibTeXComparisonRules.authorSimilarity(local.authorsText, remoteAuthors) < 0.5 {
                return nil
            }
            if let localYear = local.publicationYear, let remoteYear = paper.year,
               abs(localYear - remoteYear) > 1 {
                return nil
            }
            return (paper, score)
        }.sorted { $0.1 > $1.1 }
        guard let paper = ranked.first?.0 else { throw BibTeXRemoteError.notFound }
        return try makeSemanticScholarRecord(paper)
    }

    private func makeSemanticScholarRecord(
        _ paper: SemanticScholarPaper
    ) throws -> RemoteBibTeXRecord {
        guard let raw = paper.citationStyles?.bibtex else {
            throw BibTeXRemoteError.notFound
        }
        let authorsText = paper.authors.map(\.name).joined(separator: "; ")
        let doi = PDFMetadataExtractor.normalizedDOI(paper.externalIds?["DOI"])
        let metadata = BibliographicSnapshot(
            title: paper.title,
            authorsText: authorsText,
            publicationYear: paper.year,
            doi: doi,
            journal: paper.journal?.name
        )
        return try makeRemoteRecord(
            rawBibTeX: raw,
            suppliedMetadata: metadata,
            suppliedDOI: doi,
            sourceName: "Semantic Scholar"
        )
    }

    private func makeRemoteRecord(
        rawBibTeX: String,
        suppliedMetadata: BibliographicSnapshot? = nil,
        suppliedDOI: String?,
        sourceName: String
    ) throws -> RemoteBibTeXRecord {
        let parsed = try BibTeXRecordParser.parse(rawBibTeX)
        let parsedMetadata = BibliographicSnapshot(
            title: BibTeXRecordParser.plainText(parsed.fields["title"] ?? ""),
            authorsText: BibTeXRecordParser.plainText(parsed.fields["author"] ?? ""),
            publicationYear: parsed.fields["year"].flatMap {
                Int(BibTeXRecordParser.plainText($0).prefix(4))
            },
            doi: PDFMetadataExtractor.normalizedDOI(parsed.fields["doi"]) ?? suppliedDOI,
            journal: BibTeXRecordParser.plainText(
                parsed.fields["journal"] ?? parsed.fields["booktitle"] ?? ""
            )
        )
        let metadata = suppliedMetadata ?? parsedMetadata
        guard !metadata.title.isEmpty,
              !metadata.authorsText.isEmpty,
              metadata.publicationYear != nil
        else { throw BibTeXRemoteError.incompleteBibTeX }
        let key = try BibTeXExporter.citationKey(
            authorsText: metadata.authorsText,
            title: metadata.title,
            publicationYear: metadata.publicationYear
        )
        let content = BibTeXRecordParser.replacingCitationKey(
            in: rawBibTeX,
            parsed: parsed,
            with: key
        )
        return RemoteBibTeXRecord(
            entry: BibTeXEntry(
                citationKey: key,
                content: content.hasSuffix("\n") ? content : content + "\n"
            ),
            metadata: metadata,
            sourceName: sourceName
        )
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BibTeXRemoteError.invalidResponse
            }
            if http.statusCode == 200 { return data }
            if http.statusCode == 404 { throw BibTeXRemoteError.notFound }
            if http.statusCode == 429 || (500...599).contains(http.statusCode), attempt == 0 {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            throw BibTeXRemoteError.httpStatus(http.statusCode)
        }
        throw BibTeXRemoteError.invalidResponse
    }
}

enum BibTeXComparisonRules {
    static func differences(
        local: BibliographicSnapshot,
        online: BibliographicSnapshot
    ) -> [BibTeXDifference] {
        var results: [BibTeXDifference] = []
        compare(
            field: "标题",
            local: local.title,
            online: online.title,
            equivalent: titleSimilarity(local.title, online.title) >= 0.96,
            into: &results
        )
        compare(
            field: "作者",
            local: local.authorsText,
            online: online.authorsText,
            equivalent: normalizedSurnames(local.authorsText) == normalizedSurnames(online.authorsText),
            into: &results
        )
        if let localYear = local.publicationYear {
            let onlineYear = online.publicationYear.map(String.init) ?? "缺失"
            if online.publicationYear != localYear {
                results.append(BibTeXDifference(
                    field: "年份",
                    localValue: String(localYear),
                    onlineValue: onlineYear
                ))
            }
        } else if let onlineYear = online.publicationYear {
            results.append(BibTeXDifference(
                field: "年份",
                localValue: "缺失",
                onlineValue: String(onlineYear)
            ))
        }
        if let localDOI = PDFMetadataExtractor.normalizedDOI(local.doi) {
            let onlineDOI = PDFMetadataExtractor.normalizedDOI(online.doi)
            if localDOI != onlineDOI {
                results.append(BibTeXDifference(
                    field: "DOI",
                    localValue: localDOI,
                    onlineValue: onlineDOI ?? "缺失"
                ))
            }
        } else if let onlineDOI = PDFMetadataExtractor.normalizedDOI(online.doi) {
            results.append(BibTeXDifference(
                field: "DOI",
                localValue: "缺失",
                onlineValue: onlineDOI
            ))
        }
        if let localJournal = nonempty(local.journal) {
            let onlineJournal = nonempty(online.journal)
            compare(
                field: "期刊或会议",
                local: localJournal,
                online: onlineJournal ?? "缺失",
                equivalent: normalizedText(localJournal) == normalizedText(onlineJournal ?? ""),
                into: &results
            )
        } else if let onlineJournal = nonempty(online.journal) {
            results.append(BibTeXDifference(
                field: "期刊或会议",
                localValue: "缺失",
                onlineValue: onlineJournal
            ))
        }
        return results
    }

    static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalizedText(lhs).split(separator: " ").map(String.init))
        let right = Set(normalizedText(rhs).split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    static func authorSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalizedSurnames(lhs))
        let right = Set(normalizedSurnames(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func compare(
        field: String,
        local: String,
        online: String,
        equivalent: Bool,
        into results: inout [BibTeXDifference]
    ) {
        guard !equivalent else { return }
        let localValue = local.trimmingCharacters(in: .whitespacesAndNewlines)
        let onlineValue = online.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !onlineValue.isEmpty else { return }
        results.append(BibTeXDifference(
            field: field,
            localValue: localValue.isEmpty ? "缺失" : local,
            onlineValue: online
        ))
    }

    private static func normalizedSurnames(_ authors: String) -> [String] {
        let separated = authors.replacingOccurrences(
            of: #"\s+and\s+"#,
            with: ";",
            options: [.regularExpression, .caseInsensitive]
        ).replacingOccurrences(of: " & ", with: ";")
        return separated.split(separator: ";").map { raw in
            let author = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let surname: String
            if let comma = author.firstIndex(of: ",") {
                surname = String(author[..<comma])
            } else {
                surname = author.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? author
            }
            return normalizedText(surname)
        }
    }

    private static func normalizedText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ParsedBibTeXRecord {
    let citationKeyRange: Range<String.Index>
    let fields: [String: String]
}

enum BibTeXRecordParser {
    static func parse(_ source: String) throws -> ParsedBibTeXRecord {
        guard let at = source.firstIndex(of: "@"),
              let opening = source[at...].firstIndex(where: { $0 == "{" || $0 == "(" })
        else { throw BibTeXRemoteError.invalidBibTeX }
        let closing: Character = source[opening] == "{" ? "}" : ")"
        var cursor = source.index(after: opening)
        skipWhitespace(in: source, cursor: &cursor)
        let keyStart = cursor
        guard let comma = source[cursor...].firstIndex(of: ",") else {
            throw BibTeXRemoteError.invalidBibTeX
        }
        let keyEnd = trimmingEnd(in: source, from: keyStart, to: comma)
        guard keyStart < keyEnd else { throw BibTeXRemoteError.invalidBibTeX }
        cursor = source.index(after: comma)
        var fields: [String: String] = [:]
        var foundClosingDelimiter = false

        while cursor < source.endIndex {
            skipWhitespaceAndCommas(in: source, cursor: &cursor)
            guard cursor < source.endIndex else { break }
            if source[cursor] == closing {
                foundClosingDelimiter = true
                cursor = source.index(after: cursor)
                break
            }
            let nameStart = cursor
            while cursor < source.endIndex,
                  source[cursor].isLetter || source[cursor].isNumber || source[cursor] == "-" {
                cursor = source.index(after: cursor)
            }
            let name = source[nameStart..<cursor].lowercased()
            skipWhitespace(in: source, cursor: &cursor)
            guard !name.isEmpty, cursor < source.endIndex, source[cursor] == "=" else {
                throw BibTeXRemoteError.invalidBibTeX
            }
            cursor = source.index(after: cursor)
            skipWhitespace(in: source, cursor: &cursor)
            fields[name] = try parseValue(in: source, cursor: &cursor, outerClosing: closing)
        }
        skipWhitespace(in: source, cursor: &cursor)
        guard foundClosingDelimiter, cursor == source.endIndex else {
            throw BibTeXRemoteError.invalidBibTeX
        }
        return ParsedBibTeXRecord(citationKeyRange: keyStart..<keyEnd, fields: fields)
    }

    static func replacingCitationKey(
        in source: String,
        parsed: ParsedBibTeXRecord,
        with key: String
    ) -> String {
        source.replacingCharacters(in: parsed.citationKeyRange, with: key)
    }

    static func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseValue(
        in source: String,
        cursor: inout String.Index,
        outerClosing: Character
    ) throws -> String {
        guard cursor < source.endIndex else { throw BibTeXRemoteError.invalidBibTeX }
        if source[cursor] == "{" {
            var depth = 1
            cursor = source.index(after: cursor)
            let start = cursor
            var escaped = false
            while cursor < source.endIndex {
                let character = source[cursor]
                if character == "\\" {
                    escaped.toggle()
                    cursor = source.index(after: cursor)
                    continue
                }
                if !escaped {
                    if character == "{" { depth += 1 }
                    if character == "}" {
                        depth -= 1
                        if depth == 0 {
                            let value = String(source[start..<cursor])
                            cursor = source.index(after: cursor)
                            return value
                        }
                    }
                }
                escaped = false
                cursor = source.index(after: cursor)
            }
            throw BibTeXRemoteError.invalidBibTeX
        }
        if source[cursor] == "\"" {
            cursor = source.index(after: cursor)
            let start = cursor
            var escaped = false
            while cursor < source.endIndex {
                let character = source[cursor]
                if character == "\"", !escaped {
                    let value = String(source[start..<cursor])
                    cursor = source.index(after: cursor)
                    return value
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                cursor = source.index(after: cursor)
            }
            throw BibTeXRemoteError.invalidBibTeX
        }
        let start = cursor
        while cursor < source.endIndex,
              source[cursor] != ",", source[cursor] != outerClosing {
            cursor = source.index(after: cursor)
        }
        return String(source[start..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipWhitespace(in source: String, cursor: inout String.Index) {
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
    }

    private static func skipWhitespaceAndCommas(in source: String, cursor: inout String.Index) {
        while cursor < source.endIndex,
              source[cursor].isWhitespace || source[cursor] == "," {
            cursor = source.index(after: cursor)
        }
    }

    private static func trimmingEnd(
        in source: String,
        from start: String.Index,
        to end: String.Index
    ) -> String.Index {
        var result = end
        while result > start {
            let previous = source.index(before: result)
            guard source[previous].isWhitespace else { break }
            result = previous
        }
        return result
    }
}

private struct SemanticScholarSearchEnvelope: Decodable {
    let data: [SemanticScholarPaper]
}

private struct SemanticScholarPaper: Decodable {
    struct Author: Decodable { let name: String }
    struct CitationStyles: Decodable { let bibtex: String? }
    struct Journal: Decodable { let name: String? }

    let title: String
    let authors: [Author]
    let year: Int?
    let externalIds: [String: String]?
    let citationStyles: CitationStyles?
    let journal: Journal?
}
