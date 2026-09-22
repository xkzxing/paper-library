import Foundation
import SwiftData

@Model
final class FileVersion {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var originalFilename: String
    var pageCount: Int
    var fileSize: Int64
    var fileMetadataYear: Int?
    var sha256: String
    var textFingerprint: String?
    var hasAnnotations: Bool
    var importedAt: Date
    var versionTypeRawValue: String
    var isPreferred: Bool
    var bibliographicTitle: String?
    var bibliographicAuthorsText: String?
    var bibliographicYear: Int?
    var bibliographicJournal: String?
    var bibliographicDOI: String?
    var bibliographicMetadataSource: String?
    var bibliographicMetadataConfirmed: Bool = false
    var work: Work?

    init(
        id: UUID = UUID(),
        relativePath: String,
        originalFilename: String,
        pageCount: Int,
        fileSize: Int64,
        fileMetadataYear: Int? = nil,
        sha256: String = "",
        textFingerprint: String? = nil,
        hasAnnotations: Bool = false,
        importedAt: Date = .now,
        versionTypeRawValue: String = "unknown",
        isPreferred: Bool = true,
        bibliographicTitle: String? = nil,
        bibliographicAuthorsText: String? = nil,
        bibliographicYear: Int? = nil,
        bibliographicJournal: String? = nil,
        bibliographicDOI: String? = nil,
        bibliographicMetadataSource: String? = nil,
        bibliographicMetadataConfirmed: Bool = false,
        work: Work? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.fileMetadataYear = fileMetadataYear
        self.sha256 = sha256
        self.textFingerprint = textFingerprint
        self.hasAnnotations = hasAnnotations
        self.importedAt = importedAt
        self.versionTypeRawValue = versionTypeRawValue
        self.isPreferred = isPreferred
        self.bibliographicTitle = bibliographicTitle
        self.bibliographicAuthorsText = bibliographicAuthorsText
        self.bibliographicYear = bibliographicYear
        self.bibliographicJournal = bibliographicJournal
        self.bibliographicDOI = bibliographicDOI
        self.bibliographicMetadataSource = bibliographicMetadataSource
        self.bibliographicMetadataConfirmed = bibliographicMetadataConfirmed
        self.work = work
    }
}
