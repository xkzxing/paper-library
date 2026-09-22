import Foundation

struct ImportedPDF: Sendable, Equatable {
    let transactionID: UUID
    let relativePath: String
    let originalFilename: String
    let title: String
    let authorsText: String
    let publicationYear: Int?
    let fileMetadataYear: Int?
    let pageCount: Int
    let fileSize: Int64
    let sha256: String
    let doi: String?
    let nberNumber: String?
    let ssrnID: String?
    let arxivID: String?
    let repecHandle: String?
    let textFingerprint: String?
    let hasAnnotations: Bool
    let suggestedVersionType: String
}

struct ImportRecoveryScan: Sendable, Equatable {
    let recoverableItems: [ImportedPDF]
    let warnings: [String]
}

struct FileRelocationRequest: Sendable, Equatable {
    let fileVersionID: UUID
    let sourceRelativePath: String
    let categoryFolder: String
    let yearFolder: String
    let preferredFilename: String
    let articleFolderName: String?

    init(
        fileVersionID: UUID,
        sourceRelativePath: String,
        categoryFolder: String,
        yearFolder: String,
        preferredFilename: String,
        articleFolderName: String? = nil
    ) {
        self.fileVersionID = fileVersionID
        self.sourceRelativePath = sourceRelativePath
        self.categoryFolder = categoryFolder
        self.yearFolder = yearFolder
        self.preferredFilename = preferredFilename
        self.articleFolderName = articleFolderName
    }
}

struct ArticleFileRelocationRequest: Sendable, Equatable {
    let fileVersionID: UUID
    let sourceRelativePath: String
    let preferredFilename: String
}

struct ArticleRelocationRequest: Sendable, Equatable {
    let workID: UUID
    let files: [ArticleFileRelocationRequest]
    let categoryFolder: String
    let yearFolder: String
    let preferredFolderName: String
}

struct ArticleFileDestination: Sendable, Equatable {
    let fileVersionID: UUID
    let destinationRelativePath: String
}

struct PathRelocation: Codable, Sendable, Equatable {
    let sourceRelativePath: String
    let destinationRelativePath: String
}

struct ArticleRelocationBatch: Sendable, Equatable {
    let id: UUID
    let moves: [PathRelocation]
    let fileDestinations: [ArticleFileDestination]
    let createdDirectoryRelativePaths: [String]
    let emptySourceDirectoryRelativePaths: [String]
}

struct FileRelocation: Sendable, Equatable {
    let fileVersionID: UUID
    let sourceRelativePath: String
    let destinationRelativePath: String
    let noteSourceRelativePath: String?
    let noteDestinationRelativePath: String?
    let noteAssetsSourceRelativePath: String?
    let noteAssetsDestinationRelativePath: String?
    let studyNoteSourceRelativePath: String?
    let studyNoteDestinationRelativePath: String?
    let studyNoteAssetsSourceRelativePath: String?
    let studyNoteAssetsDestinationRelativePath: String?

    init(
        fileVersionID: UUID,
        sourceRelativePath: String,
        destinationRelativePath: String,
        noteSourceRelativePath: String? = nil,
        noteDestinationRelativePath: String? = nil,
        noteAssetsSourceRelativePath: String? = nil,
        noteAssetsDestinationRelativePath: String? = nil,
        studyNoteSourceRelativePath: String? = nil,
        studyNoteDestinationRelativePath: String? = nil,
        studyNoteAssetsSourceRelativePath: String? = nil,
        studyNoteAssetsDestinationRelativePath: String? = nil
    ) {
        self.fileVersionID = fileVersionID
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.noteSourceRelativePath = noteSourceRelativePath
        self.noteDestinationRelativePath = noteDestinationRelativePath
        self.noteAssetsSourceRelativePath = noteAssetsSourceRelativePath
        self.noteAssetsDestinationRelativePath = noteAssetsDestinationRelativePath
        self.studyNoteSourceRelativePath = studyNoteSourceRelativePath
        self.studyNoteDestinationRelativePath = studyNoteDestinationRelativePath
        self.studyNoteAssetsSourceRelativePath = studyNoteAssetsSourceRelativePath
        self.studyNoteAssetsDestinationRelativePath = studyNoteAssetsDestinationRelativePath
    }
}

enum LiteratureNoteKind: Sendable {
    case regular
    case study
}

enum LiteratureCompanionPaths {
    static func noteURL(for pdfURL: URL, kind: LiteratureNoteKind) -> URL {
        let baseURL = pdfURL.deletingPathExtension()
        switch kind {
        case .regular:
            return baseURL.appendingPathExtension("md")
        case .study:
            return baseURL.deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)-精读笔记.md")
        }
    }

    static func assetsURL(for pdfURL: URL, kind: LiteratureNoteKind) -> URL {
        let baseURL = pdfURL.deletingPathExtension()
        switch kind {
        case .regular:
            return baseURL.appendingPathExtension("assets")
        case .study:
            return baseURL.deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)-精读笔记.assets", directoryHint: .isDirectory)
        }
    }

    static func allURLs(for pdfURL: URL) -> [URL] {
        [
            noteURL(for: pdfURL, kind: .regular),
            assetsURL(for: pdfURL, kind: .regular),
            noteURL(for: pdfURL, kind: .study),
            assetsURL(for: pdfURL, kind: .study),
        ]
    }
}

struct LiteratureNoteResult: Sendable, Equatable {
    let url: URL
    let created: Bool
}

struct RelocationBatch: Sendable, Equatable {
    let id: UUID
    let relocations: [FileRelocation]
}

enum PDFImportError: LocalizedError {
    case notPDF
    case unreadablePDF
    case libraryRootUnavailable
    case invalidTransactionPath

    var errorDescription: String? {
        switch self {
        case .notPDF:
            return "只能导入 PDF 文件。"
        case .unreadablePDF:
            return "这个 PDF 无法读取或已经损坏。"
        case .libraryRootUnavailable:
            return "资料库文件夹当前不可用。"
        case .invalidTransactionPath:
            return "导入事务包含不安全的文件路径。"
        }
    }
}
