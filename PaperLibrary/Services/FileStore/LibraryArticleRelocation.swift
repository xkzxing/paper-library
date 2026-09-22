import Foundation

extension LibraryFileActor {
  func relocateArticles(
    _ requests: [ArticleRelocationRequest],
    in libraryRoot: URL
  ) throws -> ArticleRelocationBatch {
    let transactionID = UUID()
    var moves: [PathRelocation] = []
    var fileDestinations: [ArticleFileDestination] = []
    var createdDirectories: [String] = []
    var emptySourceDirectories: [String] = []
    var reservedDirectoryPaths: Set<String> = []

    for request in requests where !request.files.isEmpty {
      let sourceURLs = try request.files.map {
        let url = try safeURL(for: $0.sourceRelativePath, inside: libraryRoot)
        guard url.pathExtension.lowercased() == "pdf",
          fileManager.fileExists(atPath: url.path)
        else { throw CocoaError(.fileNoSuchFile) }
        return url
      }
      let parents = Set(sourceURLs.map { $0.deletingLastPathComponent().standardizedFileURL })
      let sourceArticleDirectories = try parents.filter { parent in
        let relative = try relativePath(of: parent, inside: libraryRoot)
        return relative.split(separator: "/").count >= 3
      }
      let destinationParent = try safeURL(
        for:
          libraryRoot
          .appending(path: request.categoryFolder, directoryHint: .isDirectory)
          .appending(path: request.yearFolder, directoryHint: .isDirectory),
        inside: libraryRoot
      )
      try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
      let preferredDirectoryName = ArchiveRules.sanitizedComponent(
        request.preferredFolderName,
        fallback: "Untitled Paper",
        maximumLength: 180,
        maximumUTF8Bytes: 220
      )
      let matchingDestinationDirectory = sourceArticleDirectories.first { directory in
        directory.deletingLastPathComponent().standardizedFileURL
          == destinationParent.standardizedFileURL
          && directory.lastPathComponent == preferredDirectoryName
      }
      // 已有文章文件夹外加一个刚导入的暂存 PDF 时，继续使用原文章文件夹。
      // 只有多个已有文章文件夹需要合并且都不是目标文件夹时，才新建目标。
      let existingArticleDirectory: URL? =
        matchingDestinationDirectory
        ?? (sourceArticleDirectories.count == 1 ? sourceArticleDirectories.first : nil)
      let destinationDirectory = uniqueArticleDirectory(
        in: destinationParent,
        preferredName: request.preferredFolderName,
        currentSourceURL: existingArticleDirectory,
        reservedPaths: reservedDirectoryPaths
      )
      reservedDirectoryPaths.insert(destinationDirectory.standardizedFileURL.path)
      let destinationDirectoryPath = try relativePath(of: destinationDirectory, inside: libraryRoot)

      if let existingArticleDirectory {
        let sourceDirectoryPath = try relativePath(
          of: existingArticleDirectory, inside: libraryRoot)
        if sourceDirectoryPath != destinationDirectoryPath {
          moves.append(
            .init(
              sourceRelativePath: sourceDirectoryPath,
              destinationRelativePath: destinationDirectoryPath
            ))
        }
        if parents.count > 1 {
          emptySourceDirectories.append(
            contentsOf:
              try sourceArticleDirectories
              .filter { $0.standardizedFileURL != existingArticleDirectory.standardizedFileURL }
              .map { try relativePath(of: $0, inside: libraryRoot) })
        }
      } else {
        createdDirectories.append(destinationDirectoryPath)
        if parents.count > 1 {
          emptySourceDirectories.append(
            contentsOf: try sourceArticleDirectories.map {
              try relativePath(of: $0, inside: libraryRoot)
            })
        }
      }

      var occupiedNames: Set<String> = []
      if let existingArticleDirectory,
        let entries = try? fileManager.contentsOfDirectory(
          at: existingArticleDirectory,
          includingPropertiesForKeys: nil
        )
      {
        occupiedNames = Set(entries.map(\.lastPathComponent))
      }
      var sourceCompanions: [URL: [URL]] = [:]
      for sourceURL in sourceURLs {
        let companions = LiteratureCompanionPaths.allURLs(for: sourceURL).filter {
          fileManager.fileExists(atPath: $0.path)
        }
        sourceCompanions[sourceURL] = companions
        occupiedNames.remove(sourceURL.lastPathComponent)
        for companion in companions { occupiedNames.remove(companion.lastPathComponent) }
      }

      let knownSourcePaths = Set(
        (sourceURLs + sourceCompanions.values.flatMap { $0 })
          .map { $0.standardizedFileURL.path }
      )

      var plannedItems: [(current: URL, destination: URL)] = []
      for (index, fileRequest) in request.files.enumerated() {
        let sourceURL = sourceURLs[index]
        let destinationName = uniqueArticlePDFName(
          preferredFilename: fileRequest.preferredFilename,
          occupiedNames: &occupiedNames
        )
        let destinationURL = destinationDirectory.appending(path: destinationName)
        let sourceMovesWithArticleDirectory =
          existingArticleDirectory.map {
            sourceURL.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL
          } ?? false
        let currentURL =
          sourceMovesWithArticleDirectory
          ? destinationDirectory.appending(path: sourceURL.lastPathComponent)
          : sourceURL
        plannedItems.append((currentURL, destinationURL))
        fileDestinations.append(
          .init(
            fileVersionID: fileRequest.fileVersionID,
            destinationRelativePath: try relativePath(of: destinationURL, inside: libraryRoot)
          ))

        for companion in sourceCompanions[sourceURL] ?? [] {
          let kind: LiteratureNoteKind =
            companion.lastPathComponent.contains("-精读笔记")
            ? .study : .regular
          let companionDestination =
            companion.pathExtension == "assets"
            ? LiteratureCompanionPaths.assetsURL(for: destinationURL, kind: kind)
            : LiteratureCompanionPaths.noteURL(for: destinationURL, kind: kind)
          let companionCurrent =
            sourceMovesWithArticleDirectory
            ? destinationDirectory.appending(path: companion.lastPathComponent)
            : companion
          plannedItems.append((companionCurrent, companionDestination))
        }
      }

      if existingArticleDirectory != nil {
        let renames = plannedItems.filter {
          $0.current.standardizedFileURL != $0.destination.standardizedFileURL
        }
        var staged: [(URL, URL)] = []
        for item in renames {
          let temporary = destinationDirectory.appending(
            path: ".paperlib-move-\(UUID().uuidString)")
          moves.append(
            .init(
              sourceRelativePath: try relativePath(of: item.current, inside: libraryRoot),
              destinationRelativePath: try relativePath(of: temporary, inside: libraryRoot)
            ))
          staged.append((temporary, item.destination))
        }
        for (temporary, destination) in staged {
          moves.append(
            .init(
              sourceRelativePath: try relativePath(of: temporary, inside: libraryRoot),
              destinationRelativePath: try relativePath(of: destination, inside: libraryRoot)
            ))
        }
      } else {
        for item in plannedItems
        where item.current.standardizedFileURL != item.destination.standardizedFileURL {
          moves.append(
            .init(
              sourceRelativePath: try relativePath(of: item.current, inside: libraryRoot),
              destinationRelativePath: try relativePath(of: item.destination, inside: libraryRoot)
            ))
        }
      }

      if parents.count > 1 {
        let directoriesToMerge = sourceArticleDirectories.filter { directory in
          directory.standardizedFileURL != existingArticleDirectory?.standardizedFileURL
        }
        for sourceDirectory in directoriesToMerge {
          let relatedItems = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
          )
          for item in relatedItems where !knownSourcePaths.contains(item.standardizedFileURL.path) {
            let destinationName = uniqueRelatedItemName(
              preferredName: item.lastPathComponent,
              occupiedNames: &occupiedNames
            )
            moves.append(
              .init(
                sourceRelativePath: try relativePath(of: item, inside: libraryRoot),
                destinationRelativePath: try relativePath(
                  of: destinationDirectory.appending(path: destinationName),
                  inside: libraryRoot
                )
              ))
          }
        }
      }
    }

    var record = ArticleRelocationTransactionRecord(
      kind: "articleDirectory",
      id: transactionID,
      createdAt: .now,
      moves: moves,
      fileDestinations: fileDestinations.map {
        .init(fileVersionID: $0.fileVersionID, destinationRelativePath: $0.destinationRelativePath)
      },
      createdDirectoryRelativePaths: createdDirectories,
      emptySourceDirectoryRelativePaths: emptySourceDirectories,
      completedMoveCount: 0
    )
    try writeArticleRelocationRecord(record, in: libraryRoot)

    do {
      for directoryPath in createdDirectories {
        try fileManager.createDirectory(
          at: try safeURL(for: directoryPath, inside: libraryRoot),
          withIntermediateDirectories: true
        )
      }
      for (index, move) in moves.enumerated()
      where move.sourceRelativePath != move.destinationRelativePath {
        record.completedMoveCount = index + 1
        try writeArticleRelocationRecord(record, in: libraryRoot)
        let source = try safeURL(for: move.sourceRelativePath, inside: libraryRoot)
        let destination = try safeURL(for: move.destinationRelativePath, inside: libraryRoot)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
      }
      return ArticleRelocationBatch(
        id: transactionID,
        moves: moves,
        fileDestinations: fileDestinations,
        createdDirectoryRelativePaths: createdDirectories,
        emptySourceDirectoryRelativePaths: emptySourceDirectories
      )
    } catch {
      try? rollbackArticleRelocations(
        ArticleRelocationBatch(
          id: transactionID,
          moves: Array(moves.prefix(record.completedMoveCount)),
          fileDestinations: fileDestinations,
          createdDirectoryRelativePaths: createdDirectories,
          emptySourceDirectoryRelativePaths: emptySourceDirectories
        ),
        in: libraryRoot
      )
      throw error
    }
  }

  func commitArticleRelocations(_ batch: ArticleRelocationBatch, in libraryRoot: URL) throws {
    for directoryPath in batch.emptySourceDirectoryRelativePaths {
      let directory = try safeURL(for: directoryPath, inside: libraryRoot)
      if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
        try fileManager.removeItem(at: directory)
      }
    }
    try removeIfPresent(try relocationJournalURL(for: batch.id, in: libraryRoot))
  }

  func rollbackArticleRelocations(_ batch: ArticleRelocationBatch, in libraryRoot: URL) throws {
    for move in batch.moves.reversed() where move.sourceRelativePath != move.destinationRelativePath
    {
      let current = try safeURL(for: move.destinationRelativePath, inside: libraryRoot)
      let original = try safeURL(for: move.sourceRelativePath, inside: libraryRoot)
      guard fileManager.fileExists(atPath: current.path) else { continue }
      guard !fileManager.fileExists(atPath: original.path) else {
        throw CocoaError(.fileWriteFileExists)
      }
      try fileManager.createDirectory(
        at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: current, to: original)
    }
    for directoryPath in batch.createdDirectoryRelativePaths.reversed() {
      let directory = try safeURL(for: directoryPath, inside: libraryRoot)
      if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
        try fileManager.removeItem(at: directory)
      }
    }
    try removeIfPresent(try relocationJournalURL(for: batch.id, in: libraryRoot))
  }
}
