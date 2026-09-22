import Foundation

extension LibraryFileActor {
  func importPDF(from sourceURL: URL, to libraryRoot: URL) throws -> ImportedPDF {
    guard sourceURL.pathExtension.lowercased() == "pdf" else {
      throw PDFImportError.notPDF
    }
    guard fileManager.fileExists(atPath: libraryRoot.path) else {
      throw PDFImportError.libraryRootUnavailable
    }

    let sourceHasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if sourceHasScopedAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    // 文件安全导入不等待 AI 或网络元数据。在书目信息经过
    // AI 提取和可靠来源核对前，统一进入未知年份目录。
    let yearFolder = "Unknown Year"
    let destinationYearDirectory =
      libraryRoot
      .appending(path: "Uncategorized", directoryHint: .isDirectory)
      .appending(path: yearFolder, directoryHint: .isDirectory)
    let importsDirectory = libraryRoot.appending(
      path: ".paperlib/imports", directoryHint: .isDirectory)

    let safeDestinationYearDirectory = try safeURL(
      for: destinationYearDirectory, inside: libraryRoot)
    let safeImportsDirectory = try safeURL(for: importsDirectory, inside: libraryRoot)
    try fileManager.createDirectory(
      at: safeDestinationYearDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: safeImportsDirectory, withIntermediateDirectories: true)

    let sourceBase = sourceURL.deletingPathExtension().lastPathComponent
    let destinationDirectory = uniqueArticleDirectory(
      in: safeDestinationYearDirectory,
      preferredName: sourceBase,
      currentSourceURL: nil,
      reservedPaths: []
    )
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    let transactionID = UUID()
    let temporaryRelativePath = ".paperlib/imports/\(transactionID.uuidString).pdf"
    let temporaryURL = try safeURL(for: temporaryRelativePath, inside: libraryRoot)
    let destinationURL = uniqueDestination(
      in: destinationDirectory,
      preferredFilename: sourceURL.lastPathComponent
    )
    let destinationRelativePath = try relativePath(of: destinationURL, inside: libraryRoot)
    let journalURL = try transactionJournalURL(for: transactionID, in: libraryRoot)
    var record = ImportTransactionRecord(
      id: transactionID,
      sourceFilename: sourceURL.lastPathComponent,
      temporaryRelativePath: temporaryRelativePath,
      destinationRelativePath: destinationRelativePath,
      state: .copying,
      createdAt: .now,
      updatedAt: .now
    )
    var destinationCreatedByImport = false

    do {
      try write(record, to: journalURL)
      try fileManager.copyItem(at: sourceURL, to: temporaryURL)
      let metadata = try PDFMetadataExtractor.extract(from: temporaryURL)
      let fileSize = try fileSize(at: temporaryURL)
      let sha256 = try sha256(at: temporaryURL)

      record.state = .staged
      record.updatedAt = .now
      try write(record, to: journalURL)

      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      destinationCreatedByImport = true
      record.state = .moved
      record.updatedAt = .now
      try write(record, to: journalURL)

      return importedPDF(
        transactionID: transactionID,
        relativePath: destinationRelativePath,
        originalFilename: sourceURL.lastPathComponent,
        metadata: metadata,
        fileSize: fileSize,
        sha256: sha256
      )
    } catch {
      try? removeIfPresent(temporaryURL)
      if destinationCreatedByImport { try? removeIfPresent(destinationURL) }
      if (try? fileManager.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty) == true {
        try? fileManager.removeItem(at: destinationDirectory)
      }
      try? removeIfPresent(journalURL)
      throw error
    }
  }

  func commitImport(transactionID: UUID, in libraryRoot: URL) throws {
    try removeIfPresent(
      safeURL(
        for: ".paperlib/imports/\(transactionID.uuidString).pdf",
        inside: libraryRoot
      ))
    try removeIfPresent(try transactionJournalURL(for: transactionID, in: libraryRoot))
  }

  func rollbackImport(_ importedPDF: ImportedPDF, in libraryRoot: URL) throws {
    let destinationURL = try safeURL(for: importedPDF.relativePath, inside: libraryRoot)
    try removeIfPresent(destinationURL)
    let articleDirectory = destinationURL.deletingLastPathComponent()
    let articleDirectoryPath = try relativePath(of: articleDirectory, inside: libraryRoot)
    if articleDirectoryPath.split(separator: "/").count >= 3,
      (try? fileManager.contentsOfDirectory(atPath: articleDirectory.path).isEmpty) == true
    {
      try fileManager.removeItem(at: articleDirectory)
    }
    try removeIfPresent(
      safeURL(
        for: ".paperlib/imports/\(importedPDF.transactionID.uuidString).pdf",
        inside: libraryRoot
      ))
    try removeIfPresent(
      try transactionJournalURL(
        for: importedPDF.transactionID,
        in: libraryRoot
      ))
  }

  func scanRecoverableImports(in libraryRoot: URL) throws -> ImportRecoveryScan {
    let importsDirectory = try safeURL(
      for: ".paperlib/imports",
      inside: libraryRoot
    )
    guard fileManager.fileExists(atPath: importsDirectory.path) else {
      return ImportRecoveryScan(recoverableItems: [], warnings: [])
    }

    let journalURLs = try fileManager.contentsOfDirectory(
      at: importsDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "json" }

    var recoverableItems: [ImportedPDF] = []
    var warnings: [String] = []

    for journalURL in journalURLs {
      do {
        let safeJournalURL = try safeURL(for: journalURL, inside: libraryRoot)
        let data = try Data(contentsOf: safeJournalURL)
        let record = try JSONDecoder().decode(ImportTransactionRecord.self, from: data)
        let temporaryURL = try safeURL(for: record.temporaryRelativePath, inside: libraryRoot)
        let destinationURL = try safeURL(for: record.destinationRelativePath, inside: libraryRoot)

        if fileManager.fileExists(atPath: destinationURL.path) {
          let metadata = try PDFMetadataExtractor.extract(from: destinationURL)
          recoverableItems.append(
            importedPDF(
              transactionID: record.id,
              relativePath: record.destinationRelativePath,
              originalFilename: record.sourceFilename,
              metadata: metadata,
              fileSize: try fileSize(at: destinationURL),
              sha256: try sha256(at: destinationURL)
            ))
        } else {
          try removeIfPresent(temporaryURL)
          try removeIfPresent(safeJournalURL)
        }
      } catch {
        warnings.append("\(journalURL.lastPathComponent)：\(error.localizedDescription)")
      }
    }

    return ImportRecoveryScan(recoverableItems: recoverableItems, warnings: warnings)
  }
}
