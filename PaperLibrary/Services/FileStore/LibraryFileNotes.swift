import Foundation

extension LibraryFileActor {
  func extractMetadata(at relativePath: String, in libraryRoot: URL) throws -> ExtractedPDFMetadata
  {
    let url = try safeURL(for: relativePath, inside: libraryRoot)
    guard fileManager.fileExists(atPath: url.path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try PDFMetadataExtractor.extract(from: url)
  }

  func createLiteratureNote(
    forPDFAt relativePath: String,
    title: String,
    kind: LiteratureNoteKind = .regular,
    in libraryRoot: URL
  ) throws -> LiteratureNoteResult {
    let pdfURL = try safeURL(for: relativePath, inside: libraryRoot)
    guard pdfURL.pathExtension.lowercased() == "pdf",
      fileManager.fileExists(atPath: pdfURL.path)
    else { throw CocoaError(.fileNoSuchFile) }

    let noteURL = try safeURL(
      for: LiteratureCompanionPaths.noteURL(for: pdfURL, kind: kind), inside: libraryRoot)
    if fileManager.fileExists(atPath: noteURL.path) {
      let values = try noteURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { throw CocoaError(.fileWriteInvalidFileName) }
      return LiteratureNoteResult(url: noteURL, created: false)
    }

    let heading =
      title
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let contents = Data(
      "<h1 style=\"text-align: center; font-style: italic\">\(heading)</h1>\n".utf8)
    do {
      try contents.write(to: noteURL, options: .withoutOverwriting)
      return LiteratureNoteResult(url: noteURL, created: true)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      return LiteratureNoteResult(url: noteURL, created: false)
    }
  }

  func existingLiteratureNote(
    forPDFAt relativePath: String,
    kind: LiteratureNoteKind,
    in libraryRoot: URL
  ) throws -> URL? {
    let pdfURL = try safeURL(for: relativePath, inside: libraryRoot)
    guard pdfURL.pathExtension.lowercased() == "pdf",
      fileManager.fileExists(atPath: pdfURL.path)
    else { throw CocoaError(.fileNoSuchFile) }

    let noteURL = try safeURL(
      for: LiteratureCompanionPaths.noteURL(for: pdfURL, kind: kind), inside: libraryRoot)
    guard fileManager.fileExists(atPath: noteURL.path) else { return nil }
    let values = try noteURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else { throw CocoaError(.fileReadInvalidFileName) }
    return noteURL
  }
}
