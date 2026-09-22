import Foundation
import PDFKit

enum PDFTextExtractionError: LocalizedError {
    case unreadablePDF
    case noExtractableText

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "无法读取 PDF 正文。"
        case .noExtractableText: return "PDF 没有可提取的文字，可能是扫描件。"
        }
    }
}

enum PDFTextExtractor {
    private struct PageText {
        let page: Int
        let text: String
    }

    static func extract(
        from url: URL,
        workID: UUID,
        fileVersionID: UUID,
        targetLength: Int = 1_400,
        maximumLength: Int = 2_200,
        overlapLength: Int = 250
    ) throws -> [SearchTextChunk] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url) else {
            throw PDFTextExtractionError.unreadablePDF
        }
        var extractedPages: [PageText] = []
        extractedPages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let raw = document.page(at: index)?.string else { continue }
            let text = normalized(raw)
            if !text.isEmpty {
                extractedPages.append(PageText(page: index + 1, text: text))
            }
        }
        try Task.checkCancellation()
        let pages = removingRepeatedMargins(from: extractedPages)
        guard pages.reduce(0, { $0 + $1.text.count }) >= 80 else {
            throw PDFTextExtractionError.noExtractableText
        }
        let chunks = makeChunks(
            pages: pages,
            workID: workID,
            fileVersionID: fileVersionID,
            targetLength: targetLength,
            maximumLength: maximumLength,
            overlapLength: overlapLength
        )
        try Task.checkCancellation()
        return chunks
    }

    static func makeChunks(
        pageTexts: [(page: Int, text: String)],
        workID: UUID,
        fileVersionID: UUID,
        targetLength: Int = 1_400,
        maximumLength: Int = 2_200,
        overlapLength: Int = 250
    ) -> [SearchTextChunk] {
        makeChunks(
            pages: pageTexts.map { PageText(page: $0.page, text: normalized($0.text)) },
            workID: workID,
            fileVersionID: fileVersionID,
            targetLength: targetLength,
            maximumLength: maximumLength,
            overlapLength: overlapLength
        )
    }

    private static func makeChunks(
        pages: [PageText],
        workID: UUID,
        fileVersionID: UUID,
        targetLength: Int,
        maximumLength: Int,
        overlapLength: Int
    ) -> [SearchTextChunk] {
        var units: [(page: Int, text: String)] = []
        for page in pages {
            if Task.isCancelled { break }
            let paragraphs = page.text.components(separatedBy: "\n\n")
                .map(normalized)
                .filter { !$0.isEmpty }
            if paragraphs.isEmpty {
                units.append((page.page, page.text))
            } else {
                units.append(contentsOf: paragraphs.map { (page.page, $0) })
            }
        }

        var chunks: [SearchTextChunk] = []
        var buffer: [(page: Int, text: String)] = []
        var length = 0

        func appendChunk() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.map(\.text).joined(separator: "\n\n")
            let ordinal = chunks.count
            chunks.append(SearchTextChunk(
                id: "\(fileVersionID.uuidString):\(ordinal)",
                workID: workID,
                fileVersionID: fileVersionID,
                ordinal: ordinal,
                startPage: buffer.first?.page ?? 1,
                endPage: buffer.last?.page ?? 1,
                text: joined,
                searchableText: searchable(joined)
            ))
        }

        for unit in units {
            if Task.isCancelled { break }
            let pieces = splitLongText(unit.text, maximumLength: maximumLength)
            for piece in pieces {
                if Task.isCancelled { break }
                if !buffer.isEmpty, length + piece.count + 2 > maximumLength {
                    appendChunk()
                    buffer = trailingOverlap(from: buffer, maximumLength: overlapLength)
                    length = buffer.reduce(0) { $0 + $1.text.count + 2 }
                }
                buffer.append((unit.page, piece))
                length += piece.count + 2
                if length >= targetLength {
                    appendChunk()
                    buffer = trailingOverlap(from: buffer, maximumLength: overlapLength)
                    length = buffer.reduce(0) { $0 + $1.text.count + 2 }
                }
            }
        }
        if !buffer.isEmpty {
            let lastText = buffer.map(\.text).joined(separator: "\n\n")
            if chunks.last?.text != lastText { appendChunk() }
        }
        return chunks
    }

    private static func splitLongText(_ text: String, maximumLength: Int) -> [String] {
        guard text.count > maximumLength else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let tentative = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
            var end = tentative
            if tentative < text.endIndex,
               let boundary = text[start..<tentative].lastIndex(where: { ".!?。！？；;\n".contains($0) }) {
                end = text.index(after: boundary)
            }
            result.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
        }
        return result.filter { !$0.isEmpty }
    }

    private static func trailingOverlap(
        from units: [(page: Int, text: String)],
        maximumLength: Int
    ) -> [(page: Int, text: String)] {
        var result: [(page: Int, text: String)] = []
        var length = 0
        for unit in units.reversed() {
            if !result.isEmpty, length + unit.text.count > maximumLength { break }
            result.insert(unit, at: 0)
            length += unit.text.count
            if length >= maximumLength { break }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "-\n", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingRepeatedMargins(from pages: [PageText]) -> [PageText] {
        guard pages.count >= 3 else { return pages }
        var frequencies: [String: Int] = [:]
        for page in pages {
            let lines = page.text.components(separatedBy: "\n").filter { !$0.isEmpty }
            let edgeLines = Array(lines.prefix(3)) + Array(lines.suffix(3))
            for line in Set(edgeLines) where line.count <= 120 {
                frequencies[line, default: 0] += 1
            }
        }
        let threshold = max(3, Int(ceil(Double(pages.count) * 0.6)))
        let repeated = Set(frequencies.compactMap { line, count in
            count >= threshold ? line : nil
        })
        guard !repeated.isEmpty else { return pages }
        return pages.compactMap { page in
            let lines = page.text.components(separatedBy: "\n")
            let kept = lines.enumerated().filter { index, line in
                let isMargin = index < 3 || index >= max(0, lines.count - 3)
                return !isMargin || !repeated.contains(line)
            }.map(\.element)
            let text = normalized(kept.joined(separator: "\n"))
            return text.isEmpty ? nil : PageText(page: page.page, text: text)
        }
    }

    static func searchable(_ text: String) -> String {
        let normalized = LibrarySearchRules.normalize(text)
        let cjk = normalized.unicodeScalars.filter { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value))
        }.map(String.init)
        let bigrams = cjk.count > 1
            ? zip(cjk, cjk.dropFirst()).map { $0 + $1 }
            : cjk
        return ([normalized] + bigrams).joined(separator: " ")
    }
}
