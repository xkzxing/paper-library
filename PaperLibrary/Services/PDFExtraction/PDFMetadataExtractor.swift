import Foundation
import PDFKit

struct ExtractedPDFMetadata: Sendable, Equatable {
    let title: String
    let authorsText: String
    let publicationYear: Int?
    let fileMetadataYear: Int?
    let pageCount: Int
    let doi: String?
    let nberNumber: String?
    let ssrnID: String?
    let arxivID: String?
    let repecHandle: String?
    let textFingerprint: String?
    let hasAnnotations: Bool
    let suggestedVersionType: String
}

enum PDFMetadataExtractor {
    static func extract(from url: URL) throws -> ExtractedPDFMetadata {
        guard let document = PDFDocument(url: url) else {
            throw PDFImportError.unreadablePDF
        }

        let attributes = document.documentAttributes ?? [:]
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let embeddedTitle = nonempty(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        let embeddedAuthor = nonempty(attributes[PDFDocumentAttribute.authorAttribute] as? String)
        let creationDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        let sampledPageTexts = (0..<min(document.pageCount, 20))
            .compactMap { document.page(at: $0)?.string }
        let sampledText = sampledPageTexts
            .joined(separator: "\n")
        let firstPagesText = String(sampledText.prefix(250_000))
        let inferredCandidates = sampledPageTexts.prefix(10)
            .map { text in
                (metadata: inferredBibliographicMetadata(from: text, fallbackTitle: fallbackTitle), text: text)
            }
        let inferred: (title: String?, authorsText: String?)
        if let best = inferredCandidates.max(by: {
            bibliographicCandidateScore($0) < bibliographicCandidateScore($1)
        }) {
            inferred = best.metadata
        } else {
            inferred = (title: nil, authorsText: nil)
        }
        let title = isFilenameFallback(embeddedTitle, fallbackTitle: fallbackTitle)
            ? (inferred.title ?? fallbackTitle)
            : (embeddedTitle ?? inferred.title ?? fallbackTitle)
        let author = embeddedAuthor ?? inferred.authorsText ?? ""
        let doi = extractDOI(from: firstPagesText)
        let nberNumber = firstCapture(
            in: firstPagesText,
            pattern: #"(?i)NBER\s+Working\s+Paper\s+(?:No\.?\s*)?(\d{3,6})"#
        )
        let ssrnID = extractSSRNID(from: firstPagesText, fallbackTitle: fallbackTitle)
        let arxivID = firstCapture(
            in: firstPagesText,
            pattern: #"(?i)arXiv\s*:\s*([0-9]{4}\.[0-9]{4,5}(?:v\d+)?)"#
        )
        let publicationYear = extractPublicationYear(from: String(firstPagesText.prefix(20_000)))
        let hasAnnotations = (0..<document.pageCount).contains {
            !(document.page(at: $0)?.annotations.isEmpty ?? true)
        }

        return ExtractedPDFMetadata(
            title: title,
            authorsText: author,
            publicationYear: publicationYear,
            fileMetadataYear: creationDate.map {
                Calendar(identifier: .gregorian).component(.year, from: $0)
            },
            pageCount: document.pageCount,
            doi: doi,
            nberNumber: nberNumber,
            ssrnID: ssrnID,
            arxivID: arxivID,
            repecHandle: firstCapture(in: firstPagesText, pattern: #"(?i)(RePEc:[A-Za-z0-9:_\-\.]+)"#),
            textFingerprint: textFingerprint(firstPagesText),
            hasAnnotations: hasAnnotations,
            suggestedVersionType: suggestedVersionType(
                from: firstPagesText,
                doi: doi,
                nberNumber: nberNumber,
                ssrnID: ssrnID,
                arxivID: arxivID
            )
        )
    }

    static func inferredBibliographicMetadata(
        from firstPageText: String,
        fallbackTitle: String
    ) -> (title: String?, authorsText: String?) {
        let lines = firstPageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return (nil, nil) }

        let anchorIndex = lines.firstIndex(where: { line in
            let lower = line.lowercased()
            return lower == "abstract" || lower.hasPrefix("first version:") ||
                lower.hasPrefix("this version:") || lower.hasPrefix("latest version:") ||
                lower.hasPrefix("revised:") || lower.hasPrefix("draft:")
        }) ?? min(lines.count, 8)
        guard anchorIndex > 0 else { return (nil, nil) }

        var header = Array(lines.prefix(anchorIndex))
        var authorsText: String?
        if let authorIndex = header.indices.reversed().first(where: { looksLikeAuthorLine(header[$0]) }) {
            authorsText = normalizedAuthors(from: header.remove(at: authorIndex))
        }

        let title = header
            .prefix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*")))
        let usableTitle = title.isEmpty || title.caseInsensitiveCompare(fallbackTitle) == .orderedSame
            ? nil
            : title
        return (usableTitle, authorsText)
    }

    private static func bibliographicCandidateScore(
        _ candidate: (metadata: (title: String?, authorsText: String?), text: String)
    ) -> Int {
        var score = 0
        if candidate.metadata.title != nil { score += 2 }
        if candidate.metadata.authorsText != nil { score += 4 }
        let lower = String(candidate.text.prefix(10_000)).lowercased()
        if lower.contains("abstract") { score += 2 }
        if lower.contains("isbn") { score += 2 }
        if lower.contains("doi") || lower.contains("ssrn") || lower.contains("nber") { score += 1 }
        return score
    }

    static func normalizedDOI(_ value: String?) -> String? {
        guard var value = nonempty(value)?.lowercased() else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;)]}>\n\t"))
        return value.hasPrefix("10.") ? value : nil
    }

    private static func extractDOI(from text: String) -> String? {
        let pattern = #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        return normalizedDOI(String(text[swiftRange]))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSSRNID(from text: String, fallbackTitle: String) -> String? {
        let patterns = [
            #"(?i)(?:papers\.)?ssrn\.com/[^\s]*?(?:abstract_id=|abstract=)(\d{5,10})"#,
            #"(?i)SSRN\s+(?:ID\s*)?(\d{5,10})"#,
            #"(?i)^ssrn[-_ ](\d{5,10})$"#
        ]
        for (source, pattern) in [(text, patterns[0]), (text, patterns[1]), (fallbackTitle, patterns[2])] {
            if let value = firstCapture(in: source, pattern: pattern) { return value }
        }
        return nil
    }

    private static func looksLikeAuthorLine(_ line: String) -> Bool {
        if line.range(of: #"[†‡]"#, options: .regularExpression) != nil { return true }
        if line.lowercased().hasPrefix("by ") { return true }
        return false
    }

    private static func normalizedAuthors(from line: String) -> String? {
        let withoutPrefix = line.replacingOccurrences(
            of: #"(?i)^by\s+"#,
            with: "",
            options: .regularExpression
        )
        let markerPattern = #"([^†‡*]+)[†‡*]"#
        if let regex = try? NSRegularExpression(pattern: markerPattern) {
            let matches = regex.matches(
                in: withoutPrefix,
                range: NSRange(withoutPrefix.startIndex..., in: withoutPrefix)
            )
            let names = matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: withoutPrefix) else { return nil }
                return nonempty(String(withoutPrefix[range]))
            }
            if !names.isEmpty { return names.joined(separator: "; ") }
        }
        let cleaned = withoutPrefix
            .replacingOccurrences(of: #"[†‡*]"#, with: "", options: .regularExpression)
        return nonempty(cleaned)
    }

    private static func isFilenameFallback(_ title: String?, fallbackTitle: String) -> Bool {
        guard let title = nonempty(title) else { return true }
        return title.caseInsensitiveCompare(fallbackTitle) == .orderedSame ||
            title.range(of: #"(?i)^ssrn[-_ ]\d+$"#, options: .regularExpression) != nil
    }

    private static func extractPublicationYear(from text: String) -> Int? {
        let patterns = [
            #"(?i)(?:published|publication|revised|revision|draft|date|copyright|©)\s*[:;,\-]?\s*((?:19|20)\d{2})"#,
            #"(?i)(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+((?:19|20)\d{2})"#
        ]
        let validRange = 1900...(Calendar.current.component(.year, from: .now) + 1)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let yearRange = Range(match.range(at: 1), in: text),
                  let year = Int(text[yearRange]),
                  validRange.contains(year)
            else { continue }
            return year
        }
        return nil
    }

    private static func textFingerprint(_ text: String) -> String? {
        let tokens = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
        guard !tokens.isEmpty else { return nil }

        var vector = Array(repeating: 0, count: 64)
        for token in tokens.prefix(50_000) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            for bit in 0..<64 {
                vector[bit] += (hash & (1 << UInt64(bit))) == 0 ? -1 : 1
            }
        }

        var fingerprint: UInt64 = 0
        for bit in 0..<64 where vector[bit] >= 0 {
            fingerprint |= 1 << UInt64(bit)
        }
        return String(format: "%016llx", fingerprint)
    }

    private static func suggestedVersionType(
        from text: String,
        doi: String?,
        nberNumber: String?,
        ssrnID: String?,
        arxivID: String?
    ) -> String {
        let lowercased = String(text.prefix(30_000)).lowercased()
        if lowercased.contains("annotated") { return "annotatedCopy" }
        if nberNumber != nil || ssrnID != nil || lowercased.contains("nber working paper") ||
            lowercased.contains("working paper") {
            return "workingPaper"
        }
        if arxivID != nil || lowercased.contains("preprint") { return "preprint" }
        return doi == nil ? "unknown" : "published"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum LocalMetadataRepairRules {
    static func needsRepair(work: Work, version: FileVersion) -> Bool {
        version.versionTypeRawValue == "unknown"
    }

    @discardableResult
    static func apply(_ metadata: ExtractedPDFMetadata, to work: Work, version: FileVersion) -> Bool {
        guard !work.metadataConfirmed, !work.crossrefChecked else { return false }
        var changed = false

        // 本地规则只补充强标识符和文件版本，不再判定标题、作者和年份。
        if work.doi == nil, let value = metadata.doi { work.doi = value; changed = true }
        if work.nberNumber == nil, let value = metadata.nberNumber { work.nberNumber = value; changed = true }
        if work.ssrnID == nil, let value = metadata.ssrnID { work.ssrnID = value; changed = true }
        if work.arxivID == nil, let value = metadata.arxivID { work.arxivID = value; changed = true }
        if work.repecHandle == nil, let value = metadata.repecHandle { work.repecHandle = value; changed = true }
        if version.versionTypeRawValue == "unknown", metadata.suggestedVersionType != "unknown" {
            version.versionTypeRawValue = metadata.suggestedVersionType
            changed = true
        }
        return changed
    }

    static func isPlaceholderTitle(_ title: String, originalFilename: String) -> Bool {
        let stem = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent
        return title.caseInsensitiveCompare(stem) == .orderedSame ||
            title.range(of: #"(?i)^ssrn[-_ ]\d+$"#, options: .regularExpression) != nil
    }
}
