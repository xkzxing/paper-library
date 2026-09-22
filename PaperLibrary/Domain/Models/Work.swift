import Foundation
import SwiftData

@Model
final class Work {
    @Attribute(.unique) var id: UUID
    var title: String
    var authorsText: String
    @Attribute(originalName: "year") var publicationYear: Int?
    var journal: String?
    var abstractText: String?
    var doi: String?
    var nberNumber: String?
    var ssrnID: String?
    var arxivID: String?
    var repecHandle: String?
    var documentTypeRawValue: String?
    var isbn: String?
    var publisher: String?
    var dateAdded: Date
    var lastOpenedAt: Date?
    var metadataConfirmed: Bool
    var needsReview: Bool
    var duplicateCandidateWorkID: UUID?
    var metadataSource: String
    var crossrefVerifiedDOI: String?
    var metadataConflictNote: String?
    var openAlexJournalMetricsJSON: String?
    var openAlexJournalLookupAttemptedAt: Date?
    var primaryCategory: Category?

    @Relationship(deleteRule: .cascade, inverse: \FileVersion.work)
    var fileVersions: [FileVersion]

    @Relationship(inverse: \Tag.works)
    var tags: [Tag]

    @Relationship(inverse: \PersonalMark.works)
    var personalMarks: [PersonalMark]

    var projects: [ReadingProject]

    @Relationship(deleteRule: .cascade, inverse: \AIAnalysis.work)
    var analyses: [AIAnalysis]

    @Relationship(deleteRule: .cascade, inverse: \StudyNoteGeneration.work)
    var studyNoteGenerations: [StudyNoteGeneration]

    init(
        id: UUID = UUID(),
        title: String,
        authorsText: String = "",
        publicationYear: Int? = nil,
        journal: String? = nil,
        abstractText: String? = nil,
        doi: String? = nil,
        nberNumber: String? = nil,
        ssrnID: String? = nil,
        arxivID: String? = nil,
        repecHandle: String? = nil,
        documentTypeRawValue: String? = nil,
        isbn: String? = nil,
        publisher: String? = nil,
        dateAdded: Date = .now,
        lastOpenedAt: Date? = nil,
        metadataConfirmed: Bool = false,
        needsReview: Bool = false,
        duplicateCandidateWorkID: UUID? = nil,
        metadataSource: String = "pdf",
        crossrefVerifiedDOI: String? = nil,
        metadataConflictNote: String? = nil,
        openAlexJournalMetricsJSON: String? = nil,
        openAlexJournalLookupAttemptedAt: Date? = nil,
        primaryCategory: Category? = nil,
        fileVersions: [FileVersion] = [],
        tags: [Tag] = [],
        personalMarks: [PersonalMark] = [],
        projects: [ReadingProject] = [],
        analyses: [AIAnalysis] = [],
        studyNoteGenerations: [StudyNoteGeneration] = []
    ) {
        self.id = id
        self.title = title
        self.authorsText = authorsText
        self.publicationYear = publicationYear
        self.journal = journal
        self.abstractText = abstractText
        self.doi = doi
        self.nberNumber = nberNumber
        self.ssrnID = ssrnID
        self.arxivID = arxivID
        self.repecHandle = repecHandle
        self.documentTypeRawValue = documentTypeRawValue
        self.isbn = isbn
        self.publisher = publisher
        self.dateAdded = dateAdded
        self.lastOpenedAt = lastOpenedAt
        self.metadataConfirmed = metadataConfirmed
        self.needsReview = needsReview
        self.duplicateCandidateWorkID = duplicateCandidateWorkID
        self.metadataSource = metadataSource
        self.crossrefVerifiedDOI = crossrefVerifiedDOI
        self.metadataConflictNote = metadataConflictNote
        self.openAlexJournalMetricsJSON = openAlexJournalMetricsJSON
        self.openAlexJournalLookupAttemptedAt = openAlexJournalLookupAttemptedAt
        self.primaryCategory = primaryCategory
        self.fileVersions = fileVersions
        self.tags = tags
        self.personalMarks = personalMarks
        self.projects = projects
        self.analyses = analyses
        self.studyNoteGenerations = studyNoteGenerations
    }

    var preferredFileVersion: FileVersion? {
        fileVersions.first(where: \.isPreferred) ?? fileVersions.first
    }

    var crossrefChecked: Bool {
        guard let verified = PDFMetadataExtractor.normalizedDOI(crossrefVerifiedDOI),
              let current = PDFMetadataExtractor.normalizedDOI(doi)
        else {
            return metadataSource.caseInsensitiveCompare("crossref") == .orderedSame
        }
        return verified == current
    }

    var openAlexJournalMetrics: OpenAlexJournalMetrics? {
        guard let openAlexJournalMetricsJSON,
              let data = openAlexJournalMetricsJSON.data(using: .utf8),
              let metrics = try? JSONDecoder().decode(OpenAlexJournalMetrics.self, from: data),
              metrics.matches(doi: doi, journal: journal)
        else { return nil }
        return metrics
    }

    func clearOpenAlexJournalMetrics() {
        openAlexJournalMetricsJSON = nil
        openAlexJournalLookupAttemptedAt = nil
    }
}

enum WorkReviewRules {
    static let pageNumberWarning = "页码可能有误"
    private static let legacyPageNumberWarning = "AI 返回了无法定位到 PDF 的引用页码；分析结果已保留，请复核引用页码。"

    static func hasPageNumberWarning(_ work: Work) -> Bool {
        guard let note = work.metadataConflictNote?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty
        else { return false }
        return note == legacyPageNumberWarning ||
            note == pageNumberWarning ||
            note.contains("；\(pageNumberWarning)")
    }

    static func requiresReview(_ work: Work) -> Bool {
        work.needsReview && !hasOnlyPageNumberWarning(work)
    }

    static func addPageNumberWarning(to work: Work) {
        setPageNumberWarning(true, on: work)
    }

    static func setPageNumberWarning(_ isPresent: Bool, on work: Work) {
        var parts = issueParts(for: work).filter {
            $0 != pageNumberWarning && $0 != legacyPageNumberWarning
        }
        if isPresent {
            parts.append(pageNumberWarning)
        }
        work.metadataConflictNote = parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    static func removeIssues(
        from work: Work,
        whosePrefixMatches prefixes: [String]
    ) {
        let remaining = issueParts(for: work).filter { part in
            !prefixes.contains(where: { part.hasPrefix($0) })
        }
        work.metadataConflictNote = remaining.isEmpty ? nil : remaining.joined(separator: "；")
        work.needsReview = work.duplicateCandidateWorkID != nil || remaining.contains {
            $0 != pageNumberWarning && $0 != legacyPageNumberWarning
        }
    }

    private static func hasOnlyPageNumberWarning(_ work: Work) -> Bool {
        guard let note = work.metadataConflictNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return note == legacyPageNumberWarning || note == pageNumberWarning
    }

    private static func issueParts(for work: Work) -> [String] {
        work.metadataConflictNote?
            .replacingOccurrences(of: legacyPageNumberWarning, with: pageNumberWarning)
            .split(separator: "；")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }
}
