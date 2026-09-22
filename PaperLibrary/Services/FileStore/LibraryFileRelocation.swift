import Foundation

extension LibraryFileActor {
  func relocateFiles(
    _ requests: [FileRelocationRequest],
    in libraryRoot: URL
  ) throws -> RelocationBatch {
    let transactionID = UUID()
    var completed: [FileRelocation] = []

    do {
      var planned: [FileRelocation] = []
      var reservedDestinationPaths: Set<String> = []
      var reservedArticleDirectoryPaths: Set<String> = []
      for request in requests {
        let sourceURL = try safeURL(for: request.sourceRelativePath, inside: libraryRoot)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
          throw CocoaError(.fileNoSuchFile)
        }
        let possibleNoteURL = try safeURL(
          for: sourceURL.deletingPathExtension().appendingPathExtension("md"),
          inside: libraryRoot
        )
        let sourceNoteURL =
          fileManager.fileExists(atPath: possibleNoteURL.path)
          ? possibleNoteURL
          : nil
        let possibleNoteAssetsURL = try safeURL(
          for: sourceURL.deletingPathExtension().appendingPathExtension("assets"),
          inside: libraryRoot
        )
        var noteAssetsIsDirectory = ObjCBool(false)
        let sourceNoteAssetsURL =
          fileManager.fileExists(
            atPath: possibleNoteAssetsURL.path,
            isDirectory: &noteAssetsIsDirectory
          ) && noteAssetsIsDirectory.boolValue
          ? possibleNoteAssetsURL
          : nil
        let possibleStudyNoteURL = try safeURL(
          for: LiteratureCompanionPaths.noteURL(for: sourceURL, kind: .study),
          inside: libraryRoot
        )
        let sourceStudyNoteURL =
          fileManager.fileExists(atPath: possibleStudyNoteURL.path)
          ? possibleStudyNoteURL
          : nil
        let possibleStudyNoteAssetsURL = try safeURL(
          for: LiteratureCompanionPaths.assetsURL(for: sourceURL, kind: .study),
          inside: libraryRoot
        )
        var studyNoteAssetsIsDirectory = ObjCBool(false)
        let sourceStudyNoteAssetsURL =
          fileManager.fileExists(
            atPath: possibleStudyNoteAssetsURL.path,
            isDirectory: &studyNoteAssetsIsDirectory
          ) && studyNoteAssetsIsDirectory.boolValue
          ? possibleStudyNoteAssetsURL
          : nil

        let destinationYearDirectory =
          libraryRoot
          .appending(path: request.categoryFolder, directoryHint: .isDirectory)
          .appending(path: request.yearFolder, directoryHint: .isDirectory)
        let safeDestinationYearDirectory = try safeURL(
          for: destinationYearDirectory,
          inside: libraryRoot
        )
        try fileManager.createDirectory(
          at: safeDestinationYearDirectory,
          withIntermediateDirectories: true
        )
        let safeDestinationDirectory: URL
        if let articleFolderName = request.articleFolderName {
          safeDestinationDirectory = uniqueArticleDirectory(
            in: safeDestinationYearDirectory,
            preferredName: articleFolderName,
            currentSourceURL: nil,
            reservedPaths: reservedArticleDirectoryPaths
          )
          reservedArticleDirectoryPaths.insert(safeDestinationDirectory.standardizedFileURL.path)
          try fileManager.createDirectory(
            at: safeDestinationDirectory,
            withIntermediateDirectories: true
          )
        } else {
          safeDestinationDirectory = safeDestinationYearDirectory
        }

        let preferredURL = safeDestinationDirectory.appending(path: request.preferredFilename)
        let destinationURL: URL
        if preferredURL.standardizedFileURL == sourceURL.standardizedFileURL {
          destinationURL = sourceURL
        } else {
          destinationURL = uniqueDestination(
            in: safeDestinationDirectory,
            preferredFilename: request.preferredFilename,
            reservedPaths: reservedDestinationPaths,
            currentSourceURL: sourceURL,
            currentCompanionURLs: [
              sourceNoteURL,
              sourceNoteAssetsURL,
              sourceStudyNoteURL,
              sourceStudyNoteAssetsURL,
            ].compactMap { $0 }
          )
        }
        reservedDestinationPaths.insert(destinationURL.standardizedFileURL.path)
        for companionURL in LiteratureCompanionPaths.allURLs(for: destinationURL) {
          reservedDestinationPaths.insert(companionURL.standardizedFileURL.path)
        }
        let destinationNoteURL = sourceNoteURL.map { _ in
          destinationURL.deletingPathExtension().appendingPathExtension("md")
        }
        let destinationNoteAssetsURL = sourceNoteAssetsURL.map { _ in
          LiteratureCompanionPaths.assetsURL(for: destinationURL, kind: .regular)
        }
        let destinationStudyNoteURL = sourceStudyNoteURL.map { _ in
          LiteratureCompanionPaths.noteURL(for: destinationURL, kind: .study)
        }
        let destinationStudyNoteAssetsURL = sourceStudyNoteAssetsURL.map { _ in
          LiteratureCompanionPaths.assetsURL(for: destinationURL, kind: .study)
        }
        planned.append(
          FileRelocation(
            fileVersionID: request.fileVersionID,
            sourceRelativePath: request.sourceRelativePath,
            destinationRelativePath: try relativePath(of: destinationURL, inside: libraryRoot),
            noteSourceRelativePath: try sourceNoteURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            noteDestinationRelativePath: try destinationNoteURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            noteAssetsSourceRelativePath: try sourceNoteAssetsURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            noteAssetsDestinationRelativePath: try destinationNoteAssetsURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            studyNoteSourceRelativePath: try sourceStudyNoteURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            studyNoteDestinationRelativePath: try destinationStudyNoteURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            studyNoteAssetsSourceRelativePath: try sourceStudyNoteAssetsURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            },
            studyNoteAssetsDestinationRelativePath: try destinationStudyNoteAssetsURL.map {
              try relativePath(of: $0, inside: libraryRoot)
            }
          ))
      }

      let record = RelocationTransactionRecord(
        id: transactionID,
        createdAt: .now,
        moves: planned.map {
          .init(
            fileVersionID: $0.fileVersionID,
            sourceRelativePath: $0.sourceRelativePath,
            destinationRelativePath: $0.destinationRelativePath,
            noteSourceRelativePath: $0.noteSourceRelativePath,
            noteDestinationRelativePath: $0.noteDestinationRelativePath,
            noteAssetsSourceRelativePath: $0.noteAssetsSourceRelativePath,
            noteAssetsDestinationRelativePath: $0.noteAssetsDestinationRelativePath,
            studyNoteSourceRelativePath: $0.studyNoteSourceRelativePath,
            studyNoteDestinationRelativePath: $0.studyNoteDestinationRelativePath,
            studyNoteAssetsSourceRelativePath: $0.studyNoteAssetsSourceRelativePath,
            studyNoteAssetsDestinationRelativePath: $0.studyNoteAssetsDestinationRelativePath
          )
        }
      )
      try writeRelocationRecord(record, in: libraryRoot)

      for relocation in planned {
        // 先记录计划中的移动。这样即使只移动了 PDF、笔记移动失败，
        // 外层回滚仍能看见这项移动；若回滚也失败，事务日志会保留到下次恢复。
        completed.append(relocation)
        var movedPDF = false
        var movedNote = false
        var movedNoteAssets = false
        var movedStudyNote = false
        do {
          if relocation.sourceRelativePath != relocation.destinationRelativePath {
            try fileManager.moveItem(
              at: try safeURL(for: relocation.sourceRelativePath, inside: libraryRoot),
              to: try safeURL(for: relocation.destinationRelativePath, inside: libraryRoot)
            )
            movedPDF = true
          }
          if let noteSource = relocation.noteSourceRelativePath,
            let noteDestination = relocation.noteDestinationRelativePath,
            noteSource != noteDestination
          {
            try fileManager.moveItem(
              at: try safeURL(for: noteSource, inside: libraryRoot),
              to: try safeURL(for: noteDestination, inside: libraryRoot)
            )
            movedNote = true
          }
          if let noteAssetsSource = relocation.noteAssetsSourceRelativePath,
            let noteAssetsDestination = relocation.noteAssetsDestinationRelativePath,
            noteAssetsSource != noteAssetsDestination
          {
            try fileManager.moveItem(
              at: try safeURL(for: noteAssetsSource, inside: libraryRoot),
              to: try safeURL(for: noteAssetsDestination, inside: libraryRoot)
            )
            movedNoteAssets = true
          }
          if let source = relocation.studyNoteSourceRelativePath,
            let destination = relocation.studyNoteDestinationRelativePath,
            source != destination
          {
            try fileManager.moveItem(
              at: try safeURL(for: source, inside: libraryRoot),
              to: try safeURL(for: destination, inside: libraryRoot)
            )
            movedStudyNote = true
          }
          if let source = relocation.studyNoteAssetsSourceRelativePath,
            let destination = relocation.studyNoteAssetsDestinationRelativePath,
            source != destination
          {
            try fileManager.moveItem(
              at: try safeURL(for: source, inside: libraryRoot),
              to: try safeURL(for: destination, inside: libraryRoot)
            )
          }
        } catch {
          if movedStudyNote,
            let destination = relocation.studyNoteDestinationRelativePath,
            let source = relocation.studyNoteSourceRelativePath
          {
            try? fileManager.moveItem(
              at: try safeURL(for: destination, inside: libraryRoot),
              to: try safeURL(for: source, inside: libraryRoot)
            )
          }
          if movedNoteAssets,
            let noteAssetsDestination = relocation.noteAssetsDestinationRelativePath,
            let noteAssetsSource = relocation.noteAssetsSourceRelativePath
          {
            try? fileManager.moveItem(
              at: try safeURL(for: noteAssetsDestination, inside: libraryRoot),
              to: try safeURL(for: noteAssetsSource, inside: libraryRoot)
            )
          }
          if movedNote,
            let noteDestination = relocation.noteDestinationRelativePath,
            let noteSource = relocation.noteSourceRelativePath
          {
            try? fileManager.moveItem(
              at: try safeURL(for: noteDestination, inside: libraryRoot),
              to: try safeURL(for: noteSource, inside: libraryRoot)
            )
          }
          if movedPDF {
            try? fileManager.moveItem(
              at: try safeURL(for: relocation.destinationRelativePath, inside: libraryRoot),
              to: try safeURL(for: relocation.sourceRelativePath, inside: libraryRoot)
            )
          }
          throw error
        }
      }
      return RelocationBatch(id: transactionID, relocations: completed)
    } catch {
      try? rollbackRelocations(
        RelocationBatch(id: transactionID, relocations: completed),
        in: libraryRoot
      )
      throw error
    }
  }

  func commitRelocations(_ batch: RelocationBatch, in libraryRoot: URL) throws {
    try removeIfPresent(try relocationJournalURL(for: batch.id, in: libraryRoot))
  }

  func rollbackRelocations(_ batch: RelocationBatch, in libraryRoot: URL) throws {
    for relocation in batch.relocations.reversed()
    where relocation.sourceRelativePath != relocation.destinationRelativePath {
      if let sourcePath = relocation.studyNoteAssetsSourceRelativePath,
        let destinationPath = relocation.studyNoteAssetsDestinationRelativePath,
        sourcePath != destinationPath
      {
        let currentURL = try safeURL(for: destinationPath, inside: libraryRoot)
        let originalURL = try safeURL(for: sourcePath, inside: libraryRoot)
        if fileManager.fileExists(atPath: currentURL.path) {
          guard !fileManager.fileExists(atPath: originalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
          }
          try fileManager.createDirectory(
            at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fileManager.moveItem(at: currentURL, to: originalURL)
        }
      }
      if let sourcePath = relocation.studyNoteSourceRelativePath,
        let destinationPath = relocation.studyNoteDestinationRelativePath,
        sourcePath != destinationPath
      {
        let currentURL = try safeURL(for: destinationPath, inside: libraryRoot)
        let originalURL = try safeURL(for: sourcePath, inside: libraryRoot)
        if fileManager.fileExists(atPath: currentURL.path) {
          guard !fileManager.fileExists(atPath: originalURL.path) else {
            throw CocoaError(.fileWriteFileExists)
          }
          try fileManager.createDirectory(
            at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fileManager.moveItem(at: currentURL, to: originalURL)
        }
      }
      if let noteAssetsSourcePath = relocation.noteAssetsSourceRelativePath,
        let noteAssetsDestinationPath = relocation.noteAssetsDestinationRelativePath,
        noteAssetsSourcePath != noteAssetsDestinationPath
      {
        let currentNoteAssetsURL = try safeURL(for: noteAssetsDestinationPath, inside: libraryRoot)
        let originalNoteAssetsURL = try safeURL(for: noteAssetsSourcePath, inside: libraryRoot)
        if fileManager.fileExists(atPath: currentNoteAssetsURL.path) {
          guard !fileManager.fileExists(atPath: originalNoteAssetsURL.path) else {
            throw CocoaError(.fileWriteFileExists)
          }
          try fileManager.createDirectory(
            at: originalNoteAssetsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.moveItem(at: currentNoteAssetsURL, to: originalNoteAssetsURL)
        }
      }
      if let noteSourcePath = relocation.noteSourceRelativePath,
        let noteDestinationPath = relocation.noteDestinationRelativePath,
        noteSourcePath != noteDestinationPath
      {
        let currentNoteURL = try safeURL(for: noteDestinationPath, inside: libraryRoot)
        let originalNoteURL = try safeURL(for: noteSourcePath, inside: libraryRoot)
        if fileManager.fileExists(atPath: currentNoteURL.path) {
          guard !fileManager.fileExists(atPath: originalNoteURL.path) else {
            throw CocoaError(.fileWriteFileExists)
          }
          try fileManager.createDirectory(
            at: originalNoteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.moveItem(at: currentNoteURL, to: originalNoteURL)
        }
      }
      let currentURL = try safeURL(for: relocation.destinationRelativePath, inside: libraryRoot)
      let originalURL = try safeURL(for: relocation.sourceRelativePath, inside: libraryRoot)
      guard fileManager.fileExists(atPath: currentURL.path) else { continue }
      guard !fileManager.fileExists(atPath: originalURL.path) else {
        throw CocoaError(.fileWriteFileExists)
      }
      try fileManager.createDirectory(
        at: originalURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: currentURL, to: originalURL)
    }
    let possibleArticleDirectories = Set(
      try batch.relocations.compactMap { relocation -> URL? in
        let destination = try safeURL(for: relocation.destinationRelativePath, inside: libraryRoot)
        let directory = destination.deletingLastPathComponent()
        let relative = try relativePath(of: directory, inside: libraryRoot)
        return relative.split(separator: "/").count >= 3 ? directory : nil
      })
    for directory in possibleArticleDirectories {
      if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
        try fileManager.removeItem(at: directory)
      }
    }
    try removeIfPresent(try relocationJournalURL(for: batch.id, in: libraryRoot))
  }
}
