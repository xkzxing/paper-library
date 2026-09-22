import CryptoKit
import Foundation
import SwiftData

struct CrossrefMetadata: Codable, Sendable, Equatable {
    let title: String
    let authorsText: String
    let publicationYear: Int?
    let doi: String?
    let journal: String?
    let abstractText: String?
}

enum CrossrefError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Crossref 返回了无法识别的响应。"
        case let .httpStatus(status):
            return "Crossref 请求失败，状态码为 \(status)。"
        }
    }
}

actor CrossrefClient {
    private let session: URLSession
    private let cacheDirectory: URL

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        let support = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectory = support.appending(path: "PaperLibrary/Crossref", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func lookup(
        doi: String?,
        title: String,
        author: String,
        publicationYear: Int? = nil,
        contactEmail: String?,
        forceRefresh: Bool = false
    ) async throws -> CrossrefMetadata? {
        let normalizedDOI = PDFMetadataExtractor.normalizedDOI(doi)
        let cacheKey = "v3|" + (normalizedDOI ?? "\(title)|\(author)|\(publicationYear.map(String.init) ?? "")")
        let cacheURL = cacheDirectory.appending(path: cacheFilename(cacheKey))

        if !forceRefresh,
           isFreshCacheFile(cacheURL),
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CrossrefMetadata.self, from: data),
           isCachedMatchUsable(
            cached,
            normalizedDOI: normalizedDOI,
            title: title,
            author: author,
            publicationYear: publicationYear
           ) {
            return cached
        }

        let metadata: CrossrefMetadata?
        if let normalizedDOI {
            // PDF/AI 提取出的 DOI 可能是漏字、参考文献 DOI，或有轻微转写错误。
            // DOI 查不到时，继续用已有的题名、作者和年份检索，而不是直接放弃核对。
            if let byDOI = try await lookupByDOI(normalizedDOI, contactEmail: contactEmail),
               isAcceptableBibliographicMatch(
                byDOI,
                title: title,
                author: author,
                publicationYear: publicationYear
               ) {
                metadata = byDOI
            } else {
                metadata = try await lookupByBibliography(
                    title: title,
                    author: author,
                    publicationYear: publicationYear,
                    contactEmail: contactEmail
                )
            }
        } else {
            metadata = try await lookupByBibliography(
                title: title,
                author: author,
                publicationYear: publicationYear,
                contactEmail: contactEmail
            )
        }

        if let metadata, let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return metadata
    }

    private func isFreshCacheFile(_ url: URL) -> Bool {
        guard let modified = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else { return false }
        return Date().timeIntervalSince(modified) < 30 * 24 * 60 * 60
    }

    private func isCachedMatchUsable(
        _ metadata: CrossrefMetadata,
        normalizedDOI: String?,
        title: String,
        author: String,
        publicationYear: Int?
    ) -> Bool {
        return isAcceptableBibliographicMatch(
            metadata,
            title: title,
            author: author,
            publicationYear: publicationYear
        )
    }

    private func lookupByDOI(_ doi: String, contactEmail: String?) async throws -> CrossrefMetadata? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.crossref.org/v1/works/\(encodedDOI)")
        else { return nil }
        do {
            let data = try await request(url: url, contactEmail: contactEmail)
            let envelope = try JSONDecoder().decode(SingleEnvelope.self, from: data)
            return envelope.message.metadata
        } catch CrossrefError.httpStatus(404) {
            return nil
        }
    }

    private func lookupByBibliography(
        title: String,
        author: String,
        publicationYear: Int?,
        contactEmail: String?
    ) async throws -> CrossrefMetadata? {
        // 有些 Crossref 记录没有作者字段。先用作者缩小范围，未命中再按题名
        // 重试，避免把这些记录直接排除在检索结果之外。
        let authorQueries: [String?] = author.isEmpty ? [nil] : [author, nil]
        for authorQuery in authorQueries {
            var components = URLComponents(string: "https://api.crossref.org/v1/works")!
            var queryItems = [
                URLQueryItem(name: "query.bibliographic", value: title),
                URLQueryItem(name: "rows", value: "10")
            ]
            if let authorQuery {
                queryItems.append(URLQueryItem(name: "query.author", value: authorQuery))
            }
            components.queryItems = queryItems
            guard let url = components.url else { continue }
            let data = try await request(url: url, contactEmail: contactEmail)
            let envelope = try JSONDecoder().decode(QueryEnvelope.self, from: data)
            let ranked = envelope.message.items
                .map(\.metadata)
                .filter {
                    isAcceptableBibliographicMatch(
                        $0,
                        title: title,
                        author: author,
                        publicationYear: publicationYear
                    )
                }
                .map { ($0, titleSimilarity(title, $0.title)) }
                .sorted { $0.1 > $1.1 }
            if let best = ranked.first { return best.0 }
        }
        return nil
    }

    private func request(url: URL, contactEmail: String?) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let contactEmail, !contactEmail.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "mailto", value: contactEmail))
            components.queryItems = items
        }
        guard let finalURL = components.url else { throw CrossrefError.invalidResponse }

        var request = URLRequest(url: finalURL)
        let contact = contactEmail.map { "mailto:\($0)" } ?? "no-contact"
        request.setValue("PaperLibrary/0.1 (\(contact))", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CrossrefError.invalidResponse
            }
            if http.statusCode == 200 { return data }
            if http.statusCode == 404 { throw CrossrefError.httpStatus(404) }
            if http.statusCode == 429 || (500...599).contains(http.statusCode), attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
                continue
            }
            throw CrossrefError.httpStatus(http.statusCode)
        }
        throw CrossrefError.invalidResponse
    }

    private func cacheFilename(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func tokens(_ value: String) -> Set<String> {
            Set(value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 })
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private func isAcceptableBibliographicMatch(
        _ metadata: CrossrefMetadata,
        title: String,
        author: String,
        publicationYear: Int?
    ) -> Bool {
        guard titleSimilarity(title, metadata.title) >= 0.72 else { return false }
        if !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !metadata.authorsText.isEmpty,
           titleSimilarity(author, metadata.authorsText) < 0.20 {
            return false
        }
        if let publicationYear, let candidateYear = metadata.publicationYear,
           abs(publicationYear - candidateYear) > 1 {
            return false
        }
        return true
    }
}

@MainActor
final class MetadataCoordinator: ObservableObject {
    @Published private(set) var isLoading = false
    @Published var errorText: String?

    private let client = CrossrefClient()

    func enrich(work: Work, modelContext: ModelContext) {
        guard !isLoading else { return }
        isLoading = true

        Task {
            do {
                let email = UserDefaults.standard.string(forKey: "crossrefContactEmail")
                guard let metadata = try await client.lookup(
                    doi: work.doi,
                    title: work.title,
                    author: work.authorsText,
                    publicationYear: work.publicationYear,
                    contactEmail: email,
                    forceRefresh: true
                ) else {
                    isLoading = false
                    return
                }
                CrossrefMetadataApplier.apply(metadata, to: work)
                try modelContext.save()
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

}

@MainActor
final class BatchMetadataCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusText: String?
    @Published var errorText: String?

    private let client = CrossrefClient()
    private var task: Task<Void, Never>?

    func refresh(works: [Work], modelContext: ModelContext) {
        guard !isWorking, !works.isEmpty else { return }
        isWorking = true
        errorText = nil

        task = Task {
            var updated = 0
            var skipped = 0
            var failed = 0
            let email = UserDefaults.standard.string(forKey: "crossrefContactEmail")

            for (index, work) in works.enumerated() {
                guard !Task.isCancelled else { break }
                statusText = "Crossref 核对 \(index + 1)/\(works.count)：\(work.title)"
                do {
                    guard let metadata = try await client.lookup(
                        doi: work.doi,
                        title: work.title,
                        author: work.authorsText,
                        publicationYear: work.publicationYear,
                        contactEmail: email,
                        forceRefresh: true
                    ) else {
                        skipped += 1
                        continue
                    }
                    CrossrefMetadataApplier.apply(metadata, to: work)
                    try modelContext.save()
                    updated += 1
                } catch is CancellationError {
                    break
                } catch {
                    modelContext.rollback()
                    failed += 1
                }
            }

            if Task.isCancelled {
                statusText = "已取消 Crossref 核对；已更新 \(updated) 篇。"
            } else {
                statusText = "Crossref 核对完成：更新 \(updated) 篇，未找到 \(skipped) 篇，失败 \(failed) 篇。"
                if failed > 0 {
                    errorText = "\(failed) 篇文献核对失败，其他文献已保存。"
                }
            }
            isWorking = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}

enum CrossrefMetadataApplier {
    static func apply(
        _ metadata: CrossrefMetadata,
        to work: Work,
        version: FileVersion? = nil
    ) {
        let previousDOI = PDFMetadataExtractor.normalizedDOI(work.doi)
        let previousJournal = work.journal
        var conflicts: [String] = []

        if let targetVersion = version ?? work.preferredFileVersion {
            if !metadata.title.isEmpty { targetVersion.bibliographicTitle = metadata.title }
            if !metadata.authorsText.isEmpty {
                targetVersion.bibliographicAuthorsText = metadata.authorsText
            }
            if let year = metadata.publicationYear { targetVersion.bibliographicYear = year }
            if let journal = metadata.journal { targetVersion.bibliographicJournal = journal }
            if let doi = metadata.doi { targetVersion.bibliographicDOI = doi }
            targetVersion.bibliographicMetadataSource = "crossref"
            targetVersion.bibliographicMetadataConfirmed = true
        }

        if work.metadataConfirmed {
            if !metadata.title.isEmpty,
               metadata.title.localizedCaseInsensitiveCompare(work.title) != .orderedSame {
                conflicts.append("标题与 Crossref 记录不同")
            }
            if let year = metadata.publicationYear,
               let existing = work.publicationYear,
               year != existing {
                conflicts.append("PDF 记录年份为 \(existing)，Crossref 记录为 \(year)")
            }
        } else {
            if !metadata.title.isEmpty { work.title = metadata.title }
            if !metadata.authorsText.isEmpty { work.authorsText = metadata.authorsText }
            if let year = metadata.publicationYear { work.publicationYear = year }
        }

        if let verifiedDOI = metadata.doi,
           PDFMetadataExtractor.normalizedDOI(work.doi) != verifiedDOI {
            if work.metadataConfirmed {
                conflicts.append("DOI 与 Crossref 记录不同")
            } else {
                work.doi = verifiedDOI
            }
        }
        if work.journal == nil { work.journal = metadata.journal }
        if work.abstractText == nil { work.abstractText = metadata.abstractText }
        work.crossrefVerifiedDOI = PDFMetadataExtractor.normalizedDOI(metadata.doi)
        work.metadataSource = "crossref"
        work.metadataConfirmed = true

        if previousDOI != PDFMetadataExtractor.normalizedDOI(work.doi) ||
            previousJournal != work.journal {
            work.clearOpenAlexJournalMetrics()
        }

        if !conflicts.isEmpty {
            work.needsReview = true
            work.metadataConflictNote = conflicts.joined(separator: "；")
        }
    }
}

private struct SingleEnvelope: Decodable {
    let message: CrossrefWork
}

private struct QueryEnvelope: Decodable {
    struct Message: Decodable { let items: [CrossrefWork] }
    let message: Message
}

private struct CrossrefWork: Decodable {
    struct Author: Decodable {
        let given: String?
        let family: String?
    }
    struct DateParts: Decodable {
        let dateParts: [[Int]]
        enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
    }

    let title: [String]?
    let author: [Author]?
    let published: DateParts?
    let issued: DateParts?
    let DOI: String?
    let containerTitle: [String]?
    let abstract: String?

    enum CodingKeys: String, CodingKey {
        case title, author, published, issued, DOI, abstract
        case containerTitle = "container-title"
    }

    var metadata: CrossrefMetadata {
        let authors = (author ?? []).map { item in
            [item.given, item.family].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "; ")
        return CrossrefMetadata(
            // Crossref 有时沿用出版商网页的脚注格式，例如 <sup>*</sup>。
            // 脚注不属于正式题名，不能原样显示或写入资料库。
            title: CrossrefTextCleaner.title(title?.first ?? ""),
            authorsText: authors,
            publicationYear: published?.dateParts.first?.first ?? issued?.dateParts.first?.first,
            doi: PDFMetadataExtractor.normalizedDOI(DOI),
            journal: containerTitle?.first,
            abstractText: abstract?.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
        )
    }
}

private enum CrossrefTextCleaner {
    static func title(_ value: String) -> String {
        let withoutFootnoteMarkers = value.replacingOccurrences(
            of: #"<[sS][uU][pP]\b[^>]*>[\s\S]*?</[sS][uU][pP]\s*>"#,
            with: "",
            options: .regularExpression
        )
        return withoutFootnoteMarkers
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
