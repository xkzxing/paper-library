import Foundation

struct BibTeXEntry: Equatable, Sendable {
    let citationKey: String
    let content: String
}

enum BibTeXExportError: LocalizedError, Equatable {
    case metadataNotConfirmed
    case needsReview
    case missingTitle
    case placeholderTitle
    case missingAuthors
    case missingYear
    case invalidYear
    case invalidDOI

    var errorDescription: String? {
        switch self {
        case .metadataNotConfirmed:
            return "请先核对并确认这篇文献的书目信息，再导出 BibTeX。"
        case .needsReview:
            return "这篇文献仍有待处理问题，请先完成检查再导出 BibTeX。"
        case .missingTitle:
            return "缺少文章标题，无法导出 BibTeX。"
        case .placeholderTitle:
            return "当前标题仍像文件名，请先填写并确认真实文章标题。"
        case .missingAuthors:
            return "缺少作者，无法导出 BibTeX。"
        case .missingYear:
            return "缺少发表年份，无法导出 BibTeX。"
        case .invalidYear:
            return "发表年份不在合理范围内，请检查后再导出。"
        case .invalidDOI:
            return "DOI 格式无效，请修正或清空后再导出。"
        }
    }
}

enum BibTeXExporter {
    static func makeEntry(for work: Work) throws -> BibTeXEntry {
        guard work.metadataConfirmed else { throw BibTeXExportError.metadataNotConfirmed }
        guard !WorkReviewRules.requiresReview(work) else { throw BibTeXExportError.needsReview }

        let title = singleLine(work.title)
        guard !title.isEmpty else { throw BibTeXExportError.missingTitle }
        if let version = work.preferredFileVersion,
           LocalMetadataRepairRules.isPlaceholderTitle(
               title,
               originalFilename: version.originalFilename
           ) {
            throw BibTeXExportError.placeholderTitle
        }

        let authors = parsedAuthors(work.authorsText)
        guard !authors.isEmpty else { throw BibTeXExportError.missingAuthors }
        guard let year = work.publicationYear else { throw BibTeXExportError.missingYear }
        let maximumYear = Calendar.current.component(.year, from: .now) + 1
        guard (1000...maximumYear).contains(year) else { throw BibTeXExportError.invalidYear }

        let doi: String?
        if let rawDOI = nonempty(work.doi) {
            guard let normalized = PDFMetadataExtractor.normalizedDOI(rawDOI) else {
                throw BibTeXExportError.invalidDOI
            }
            doi = normalized
        } else {
            doi = nil
        }

        let entryType = inferredEntryType(for: work)
        let citationKey = try citationKey(
            authorsText: work.authorsText,
            title: title,
            publicationYear: year
        )
        var fields: [(String, String)] = [
            ("author", authors.map(escaped).joined(separator: " and ")),
            // 双层花括号防止参考文献样式擅自改变题名大小写。
            ("title", "{\(escaped(title))}"),
            ("year", String(year)),
        ]

        switch entryType {
        case "article":
            if let journal = nonempty(work.journal) {
                fields.append(("journal", escaped(singleLine(journal))))
            }
        case "book":
            if let publisher = nonempty(work.publisher) {
                fields.append(("publisher", escaped(singleLine(publisher))))
            }
        case "techreport":
            if let publisher = nonempty(work.publisher) {
                fields.append(("institution", escaped(singleLine(publisher))))
            }
            fields.append(("type", work.documentTypeRawValue == "workingPaper"
                ? "Working Paper"
                : "Research Report"))
        default:
            if let publisher = nonempty(work.publisher) {
                fields.append(("publisher", escaped(singleLine(publisher))))
            }
        }

        if let isbn = nonempty(work.isbn) {
            fields.append(("isbn", escaped(singleLine(isbn))))
        }
        if let doi {
            fields.append(("doi", escaped(doi)))
        }

        let notes = identifierNotes(for: work)
        if !notes.isEmpty {
            fields.append(("note", escaped(notes.joined(separator: "; "))))
        }

        let renderedFieldLines: [String] = fields.enumerated().map { index, field in
            let comma = index == fields.count - 1 ? "" : ","
            return "  \(field.0) = {\(field.1)}\(comma)"
        }
        let renderedFields = renderedFieldLines.joined(separator: "\n")
        let content = "@\(entryType){\(citationKey),\n\(renderedFields)\n}\n"
        return BibTeXEntry(citationKey: citationKey, content: content)
    }

    private static func inferredEntryType(for work: Work) -> String {
        let hasJournal = nonempty(work.journal) != nil
        let hasPublisher = nonempty(work.publisher) != nil
        switch work.documentTypeRawValue {
        case "article" where hasJournal:
            return "article"
        case "book" where hasPublisher:
            return "book"
        case "workingPaper" where hasPublisher,
             "report" where hasPublisher:
            return "techreport"
        default:
            if hasJournal { return "article" }
            if nonempty(work.isbn) != nil, hasPublisher { return "book" }
            return "misc"
        }
    }

    static func citationKey(
        authorsText: String,
        title: String,
        publicationYear: Int?
    ) throws -> String {
        let authors = parsedAuthors(authorsText)
        guard let firstAuthor = authors.first else { throw BibTeXExportError.missingAuthors }
        guard let year = publicationYear else { throw BibTeXExportError.missingYear }
        let firstSurnameWords = asciiWords(surname(from: firstAuthor))
        let firstSurname = firstSurnameWords.map(capitalizedKeyWord).joined()
        let otherInitials = authors.dropFirst().compactMap { author -> Character? in
            asciiWords(surname(from: author)).first?.first
        }.map { String($0).uppercased() }.joined()
        let ignoredWords: Set<String> = [
            "a", "an", "and", "as", "at", "by", "for", "from", "in", "into", "of", "on",
            "or", "the", "to", "via", "with", "without",
        ]
        let titleWord = asciiWords(title).first(where: { !ignoredWords.contains($0) }) ?? "work"
        let firstSurnamePart = firstSurname.isEmpty ? "Ref" : firstSurname
        return "\(firstSurnamePart)\(otherInitials)\(year)\(capitalizedKeyWord(titleWord))"
    }

    private static func parsedAuthors(_ authorsText: String) -> [String] {
        let normalized = singleLine(authorsText)
        guard !normalized.isEmpty else { return [] }
        let separatedAuthors = normalized.contains(";")
            ? normalized
            : normalized.replacingOccurrences(of: " and ", with: ";", options: .caseInsensitive)
                .replacingOccurrences(of: " & ", with: ";")
        return separatedAuthors.split(separator: ";")
            .map { singleLine(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func surname(from author: String) -> String {
        if let comma = author.firstIndex(of: ",") {
            return String(author[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return author.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? author
    }

    private static func asciiWords(_ value: String) -> [String] {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let unaccented = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return unaccented.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func capitalizedKeyWord(_ value: String) -> String {
        guard let first = value.first else { return "" }
        return String(first).uppercased() + value.dropFirst().lowercased()
    }

    private static func identifierNotes(for work: Work) -> [String] {
        var notes: [String] = []
        if let value = nonempty(work.nberNumber) { notes.append("NBER \(singleLine(value))") }
        if let value = nonempty(work.ssrnID) { notes.append("SSRN \(singleLine(value))") }
        if let value = nonempty(work.arxivID) { notes.append("arXiv \(singleLine(value))") }
        if let value = nonempty(work.repecHandle) { notes.append("RePEc \(singleLine(value))") }
        return notes
    }

    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "{\\textbackslash}"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "#", "$", "%", "&", "_": result += "\\\(character)"
            case "^": result += "\\textasciicircum{}"
            case "~": result += "\\textasciitilde{}"
            default: result.append(character)
            }
        }
        return result
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
