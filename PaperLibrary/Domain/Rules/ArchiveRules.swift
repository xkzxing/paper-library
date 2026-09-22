import Foundation

enum AuthorYearReferencePreferences {
    static let authorLimitKey = "authorYearReferenceAuthorLimit"
    static let defaultAuthorLimit = 4
    static let allowedAuthorLimits = 1...20
}

enum ArchiveRules {
    static func authorYearReference(
        authorsText: String,
        publicationYear: Int?,
        authorLimit: Int = AuthorYearReferencePreferences.defaultAuthorLimit
    ) -> String? {
        guard let publicationYear else { return nil }

        let normalized = authorsText
            .replacingOccurrences(
                of: #"\s+and\s+"#,
                with: ";",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s*&\s*"#,
                with: ";",
                options: .regularExpression
            )
        let surnames = normalized
            .split(separator: ";")
            .map { surname(from: String($0)) }
            .filter { !$0.isEmpty }
        guard !surnames.isEmpty else { return nil }

        let effectiveAuthorLimit = max(1, authorLimit)
        let authors: String
        if surnames.count > effectiveAuthorLimit {
            authors = surnames.prefix(effectiveAuthorLimit).joined(separator: ", ") + " et al"
        } else if surnames.count == 1 {
            authors = surnames[0]
        } else if surnames.count == 2 {
            authors = "\(surnames[0]) & \(surnames[1])"
        } else {
            authors = surnames.dropLast().joined(separator: ", ") + " & " + surnames.last!
        }
        return "\(authors) (\(publicationYear))"
    }

    static func categoryFolderName(_ categoryName: String?) -> String {
        sanitizedComponent(categoryName ?? "Uncategorized", fallback: "Uncategorized")
    }

    static func yearFolderName(_ publicationYear: Int?) -> String {
        publicationYear.map(String.init) ?? "Unknown Year"
    }

    static func articleRelocationRequest(for work: Work, categoryName: String? = nil) -> ArticleRelocationRequest? {
        guard let preferred = work.preferredFileVersion, !work.fileVersions.isEmpty else { return nil }
        let versions = Array(work.fileVersions)
        return ArticleRelocationRequest(
            workID: work.id,
            files: versions.map { version in
                ArticleFileRelocationRequest(
                    fileVersionID: version.id,
                    sourceRelativePath: version.relativePath,
                    preferredFilename: filename(
                        for: work,
                        version: version,
                        includeVersionSuffix: versions.count > 1 && version.id != preferred.id
                    )
                )
            },
            categoryFolder: categoryFolderName(categoryName ?? work.primaryCategory?.name),
            yearFolder: yearFolderName(work.publicationYear),
            preferredFolderName: articleFolderName(for: work)
        )
    }

    static func articleRelocationRequest(
        for work: Work,
        title: String,
        authorsText: String,
        publicationYear: Int?,
        categoryName: String?,
        metadataConfirmed: Bool,
        preferredVersion: FileVersion? = nil
    ) -> ArticleRelocationRequest? {
        guard let preferred = preferredVersion ?? work.preferredFileVersion,
              work.fileVersions.contains(where: { $0.id == preferred.id })
        else { return nil }
        let versions = Array(work.fileVersions)
        return ArticleRelocationRequest(
            workID: work.id,
            files: versions.map { version in
                ArticleFileRelocationRequest(
                    fileVersionID: version.id,
                    sourceRelativePath: version.relativePath,
                    preferredFilename: filename(
                        title: title,
                        authorsText: authorsText,
                        publicationYear: publicationYear,
                        metadataConfirmed: metadataConfirmed,
                        version: version,
                        includeVersionSuffix: versions.count > 1 && version.id != preferred.id
                    )
                )
            },
            categoryFolder: categoryFolderName(categoryName),
            yearFolder: yearFolderName(publicationYear),
            preferredFolderName: articleFolderName(
                title: title,
                authorsText: authorsText,
                publicationYear: publicationYear,
                metadataConfirmed: metadataConfirmed,
                preferredVersion: preferred
            )
        )
    }

    static func filename(for work: Work, version: FileVersion, includeVersionSuffix: Bool) -> String {
        filename(
            title: work.title,
            authorsText: work.authorsText,
            publicationYear: work.publicationYear,
            metadataConfirmed: canUseStructuredFilename(for: work, version: version),
            version: version,
            includeVersionSuffix: includeVersionSuffix
        )
    }

    static func articleFolderName(for work: Work) -> String {
        guard let preferred = work.preferredFileVersion else { return "Untitled Paper" }
        return articleFolderName(
            title: work.title,
            authorsText: work.authorsText,
            publicationYear: work.publicationYear,
            metadataConfirmed: canUseStructuredFilename(for: work, version: preferred),
            preferredVersion: preferred
        )
    }

    static func articleFolderName(
        title: String,
        authorsText: String,
        publicationYear: Int?,
        metadataConfirmed: Bool,
        preferredVersion: FileVersion
    ) -> String {
        let filename = filename(
            title: title,
            authorsText: authorsText,
            publicationYear: publicationYear,
            metadataConfirmed: metadataConfirmed,
            version: preferredVersion,
            includeVersionSuffix: false
        )
        return sanitizedComponent(
            URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            fallback: "Untitled Paper",
            maximumLength: 180,
            maximumUTF8Bytes: 220
        )
    }

    static func canUseStructuredFilename(for work: Work, version: FileVersion) -> Bool {
        guard work.publicationYear != nil,
              !work.authorsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !LocalMetadataRepairRules.isPlaceholderTitle(
                work.title,
                originalFilename: version.originalFilename
              )
        else { return false }

        if work.metadataConfirmed { return true }
        return ["ai", "crossref"].contains(work.metadataSource.lowercased())
    }

    static func filename(
        title: String,
        authorsText: String,
        publicationYear: Int?,
        metadataConfirmed: Bool,
        version: FileVersion,
        includeVersionSuffix: Bool
    ) -> String {
        guard metadataConfirmed, let year = publicationYear else {
            let original = sanitizedFilename(version.originalFilename)
            guard includeVersionSuffix else { return original }
            let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
            let suffix = " - \(versionLabel(version.versionTypeRawValue))"
            let cleanBase = sanitizedComponent(
                base,
                fallback: "Untitled Paper",
                maximumLength: 180,
                maximumUTF8Bytes: max(1, 235 - suffix.utf8.count)
            )
            return "\(cleanBase)\(suffix).pdf"
        }

        let author = authorPrefix(from: authorsText)
        let shortTitle = shortenedTitle(title)
        let base = "\(author) - \(year) - \(shortTitle)"
        let suffix = includeVersionSuffix ? " - \(versionLabel(version.versionTypeRawValue))" : ""
        let cleanBase = sanitizedComponent(
            base,
            fallback: "Untitled Paper",
            maximumLength: 180,
            maximumUTF8Bytes: max(1, 235 - suffix.utf8.count)
        )
        return "\(cleanBase)\(suffix).pdf"
    }

    static func sanitizedComponent(
        _ value: String,
        fallback: String,
        maximumLength: Int = 80,
        maximumUTF8Bytes: Int = 220
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let candidate = cleaned.isEmpty ? fallback : cleaned
        var result = ""
        for character in candidate.prefix(maximumLength) {
            let next = result + String(character)
            guard next.utf8.count <= maximumUTF8Bytes else { break }
            result = next
        }
        return result.isEmpty ? String(fallback.prefix(maximumLength)) : result
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let base = filename.lowercased().hasSuffix(".pdf")
            ? String(filename.dropLast(4))
            : filename
        let cleanBase = sanitizedComponent(
            base,
            fallback: "Untitled Paper",
            maximumLength: 180,
            maximumUTF8Bytes: 235
        )
        return "\(cleanBase).pdf"
    }

    private static func shortenedTitle(_ title: String) -> String {
        let clean = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(120))
    }

    private static func authorPrefix(from authorsText: String) -> String {
        let normalized = authorsText
            .replacingOccurrences(of: " and ", with: ";", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ";")
        let authors = normalized
            .split(separator: ";")
            .map { surname(from: String($0)) }
            .filter { !$0.isEmpty }

        switch authors.count {
        case 0:
            return "Unknown Author"
        case 1:
            return authors[0]
        case 2:
            return "\(authors[0]) & \(authors[1])"
        default:
            return "\(authors[0]) et al."
        }
    }

    private static func surname(from author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    private static func versionLabel(_ rawValue: String) -> String {
        switch rawValue {
        case "published": return "正式发表版"
        case "workingPaper": return "工作论文"
        case "acceptedManuscript": return "录用稿"
        case "preprint": return "预印本"
        case "supplement": return "补充材料"
        case "annotatedCopy": return "带标注副本"
        default: return "其他版本"
        }
    }
}
