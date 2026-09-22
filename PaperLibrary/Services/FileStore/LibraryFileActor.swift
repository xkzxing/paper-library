import CryptoKit
import Foundation

struct RelocationTransactionRecord: Codable, Sendable {
  struct Move: Codable, Sendable {
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
  }
  let id: UUID
  let createdAt: Date
  let moves: [Move]
}

struct ArticleRelocationTransactionRecord: Codable, Sendable {
  let kind: String
  let id: UUID
  let createdAt: Date
  let moves: [PathRelocation]
  let fileDestinations: [ArticleFileDestinationRecord]
  let createdDirectoryRelativePaths: [String]
  let emptySourceDirectoryRelativePaths: [String]
  var completedMoveCount: Int

  struct ArticleFileDestinationRecord: Codable, Sendable {
    let fileVersionID: UUID
    let destinationRelativePath: String
  }
}

enum ImportTransactionState: String, Codable, Sendable {
  case copying
  case staged
  case moved
}

struct ImportTransactionRecord: Codable, Sendable {
  let id: UUID
  let sourceFilename: String
  let temporaryRelativePath: String
  let destinationRelativePath: String
  var state: ImportTransactionState
  let createdAt: Date
  var updatedAt: Date
}

actor LibraryFileActor {
  let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func importedPDF(
    transactionID: UUID,
    relativePath: String,
    originalFilename: String,
    metadata: ExtractedPDFMetadata,
    fileSize: Int64,
    sha256: String
  ) -> ImportedPDF {
    ImportedPDF(
      transactionID: transactionID,
      relativePath: relativePath,
      originalFilename: originalFilename,
      title: metadata.title,
      authorsText: metadata.authorsText,
      publicationYear: metadata.publicationYear,
      fileMetadataYear: metadata.fileMetadataYear,
      pageCount: metadata.pageCount,
      fileSize: fileSize,
      sha256: sha256,
      doi: metadata.doi,
      nberNumber: metadata.nberNumber,
      ssrnID: metadata.ssrnID,
      arxivID: metadata.arxivID,
      repecHandle: metadata.repecHandle,
      textFingerprint: metadata.textFingerprint,
      hasAnnotations: metadata.hasAnnotations,
      suggestedVersionType: metadata.suggestedVersionType
    )
  }

  func uniqueDestination(
    in directory: URL,
    preferredFilename: String,
    reservedPaths: Set<String> = [],
    currentSourceURL: URL? = nil,
    currentCompanionURLs: [URL] = []
  ) -> URL {
    let filenameURL = URL(fileURLWithPath: preferredFilename)
    let base = filenameURL.deletingPathExtension().lastPathComponent
    let extensionName = filenameURL.pathExtension
    let extensionSuffix = extensionName.isEmpty ? "" : ".\(extensionName)"
    let companionSuffixes = [
      extensionSuffix,
      ".md",
      ".assets",
      "-精读笔记.md",
      "-精读笔记.assets",
    ]
    let maximumSuffixByteCount = companionSuffixes.map(\.utf8.count).max() ?? 0

    func candidateURL(numberSuffix: String) -> URL {
      let candidateBase = truncatedFilenameComponent(
        base,
        maximumUTF8Bytes: 255 - numberSuffix.utf8.count - maximumSuffixByteCount
      )
      return directory.appending(path: "\(candidateBase)\(numberSuffix)\(extensionSuffix)")
    }

    func companionIsAvailable(for candidate: URL) -> Bool {
      for companion in LiteratureCompanionPaths.allURLs(for: candidate) {
        if currentCompanionURLs.contains(where: {
          companion.standardizedFileURL == $0.standardizedFileURL
        }) {
          continue
        }
        if fileManager.fileExists(atPath: companion.path)
          || reservedPaths.contains(companion.standardizedFileURL.path)
        {
          return false
        }
      }
      return true
    }

    let originalURL = candidateURL(numberSuffix: "")
    guard
      fileManager.fileExists(atPath: originalURL.path)
        || reservedPaths.contains(originalURL.standardizedFileURL.path)
        || !companionIsAvailable(for: originalURL)
    else { return originalURL }

    var counter = 2

    while true {
      let suffix = " (\(counter))"
      let candidate = candidateURL(numberSuffix: suffix)
      if candidate.standardizedFileURL == currentSourceURL?.standardizedFileURL,
        !reservedPaths.contains(candidate.standardizedFileURL.path),
        companionIsAvailable(for: candidate)
      {
        return candidate
      }
      if !fileManager.fileExists(atPath: candidate.path)
        && !reservedPaths.contains(candidate.standardizedFileURL.path)
        && companionIsAvailable(for: candidate)
      {
        return candidate
      }
      counter += 1
    }
  }

  func uniqueArticleDirectory(
    in parent: URL,
    preferredName: String,
    currentSourceURL: URL?,
    reservedPaths: Set<String>
  ) -> URL {
    let cleanName = ArchiveRules.sanitizedComponent(
      preferredName,
      fallback: "Untitled Paper",
      maximumLength: 180,
      maximumUTF8Bytes: 220
    )
    var counter = 1
    while true {
      let suffix = counter == 1 ? "" : " (\(counter))"
      let base = truncatedFilenameComponent(
        cleanName,
        maximumUTF8Bytes: 255 - suffix.utf8.count
      )
      let candidate = parent.appending(path: "\(base)\(suffix)", directoryHint: .isDirectory)
      let path = candidate.standardizedFileURL.path
      if candidate.standardizedFileURL == currentSourceURL?.standardizedFileURL,
        !containsPath(path, in: reservedPaths)
      {
        return candidate
      }
      if !fileManager.fileExists(atPath: path), !containsPath(path, in: reservedPaths) {
        return candidate
      }
      counter += 1
    }
  }

  func uniqueArticlePDFName(
    preferredFilename: String,
    occupiedNames: inout Set<String>
  ) -> String {
    let filenameURL = URL(fileURLWithPath: preferredFilename)
    let originalBase = filenameURL.deletingPathExtension().lastPathComponent
    var counter = 1
    while true {
      let numberSuffix = counter == 1 ? "" : " (\(counter))"
      let base = truncatedFilenameComponent(
        originalBase,
        maximumUTF8Bytes: 255 - numberSuffix.utf8.count - "-精读笔记.assets".utf8.count
      )
      let candidate = "\(base)\(numberSuffix).pdf"
      let candidateURL = URL(fileURLWithPath: candidate)
      let companionNames = LiteratureCompanionPaths.allURLs(for: candidateURL).map(
        \.lastPathComponent)
      if !containsFilename(candidate, in: occupiedNames),
        companionNames.allSatisfy({ !containsFilename($0, in: occupiedNames) })
      {
        occupiedNames.insert(candidate)
        for name in companionNames { occupiedNames.insert(name) }
        return candidate
      }
      counter += 1
    }
  }

  func uniqueRelatedItemName(
    preferredName: String,
    occupiedNames: inout Set<String>
  ) -> String {
    let itemURL = URL(fileURLWithPath: preferredName)
    let pathExtension = itemURL.pathExtension
    let originalBase =
      pathExtension.isEmpty
      ? preferredName
      : itemURL.deletingPathExtension().lastPathComponent
    var counter = 1
    while true {
      let numberSuffix = counter == 1 ? "" : " (\(counter))"
      let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
      let base = truncatedFilenameComponent(
        originalBase,
        maximumUTF8Bytes: 255 - numberSuffix.utf8.count - extensionSuffix.utf8.count
      )
      let candidate = "\(base)\(numberSuffix)\(extensionSuffix)"
      if !containsFilename(candidate, in: occupiedNames) {
        occupiedNames.insert(candidate)
        return candidate
      }
      counter += 1
    }
  }

  func truncatedFilenameComponent(_ value: String, maximumUTF8Bytes: Int) -> String {
    var result = ""
    for character in value where (result + String(character)).utf8.count <= maximumUTF8Bytes {
      result.append(character)
    }
    return result
  }

  func containsFilename(_ filename: String, in names: Set<String>) -> Bool {
    names.contains { $0.localizedCaseInsensitiveCompare(filename) == .orderedSame }
  }

  func containsPath(_ path: String, in paths: Set<String>) -> Bool {
    paths.contains { $0.localizedCaseInsensitiveCompare(path) == .orderedSame }
  }

  func transactionJournalURL(for transactionID: UUID, in libraryRoot: URL) throws -> URL {
    try safeURL(
      for: ".paperlib/imports/\(transactionID.uuidString).json",
      inside: libraryRoot
    )
  }

  func write(_ record: ImportTransactionRecord, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: url, options: .atomic)
  }

  func relocationJournalURL(for transactionID: UUID, in libraryRoot: URL) throws -> URL {
    try safeURL(
      for: ".paperlib/operations/\(transactionID.uuidString).json",
      inside: libraryRoot
    )
  }

  func writeRelocationRecord(
    _ record: RelocationTransactionRecord,
    in libraryRoot: URL
  ) throws {
    let directory = try safeURL(for: ".paperlib/operations", inside: libraryRoot)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(record)
    try data.write(
      to: try relocationJournalURL(for: record.id, in: libraryRoot),
      options: .atomic
    )
  }

  func writeArticleRelocationRecord(
    _ record: ArticleRelocationTransactionRecord,
    in libraryRoot: URL
  ) throws {
    let directory = try safeURL(for: ".paperlib/operations", inside: libraryRoot)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(
      to: try relocationJournalURL(for: record.id, in: libraryRoot),
      options: .atomic
    )
  }

  func fileSize(at url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
  }

  func sha256(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()

    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func relativePath(of url: URL, inside libraryRoot: URL) throws -> String {
    let safeURL = try safeURL(for: url, inside: libraryRoot)
    let rootPath = libraryRoot.standardizedFileURL.path
    return String(safeURL.path.dropFirst(rootPath.count + 1))
  }

  func safeURL(for relativePath: String, inside libraryRoot: URL) throws -> URL {
    do {
      return try LibraryPathSafety.url(for: relativePath, inside: libraryRoot)
    } catch {
      throw PDFImportError.invalidTransactionPath
    }
  }

  func safeURL(for url: URL, inside libraryRoot: URL) throws -> URL {
    do {
      let relativePath = try LibraryPathSafety.relativePath(of: url, inside: libraryRoot)
      return try LibraryPathSafety.url(for: relativePath, inside: libraryRoot)
    } catch {
      throw PDFImportError.invalidTransactionPath
    }
  }

  func removeIfPresent(_ url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }
}
