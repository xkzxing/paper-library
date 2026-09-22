import Foundation

extension LibraryFileActor {
  func recoverRelocationTransactions(
    knownRelativePaths: Set<String>,
    in libraryRoot: URL
  ) throws -> [String] {
    let directory = try safeURL(for: ".paperlib/operations", inside: libraryRoot)
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let journals = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }

    var warnings: [String] = []
    for journal in journals {
      do {
        let safeJournal = try safeURL(for: journal, inside: libraryRoot)
        let data = try Data(contentsOf: safeJournal)
        if let articleRecord = try? JSONDecoder().decode(
          ArticleRelocationTransactionRecord.self,
          from: data
        ), articleRecord.kind == "articleDirectory" {
          let databaseCommitted = articleRecord.fileDestinations.allSatisfy {
            knownRelativePaths.contains($0.destinationRelativePath)
          }
          let batch = ArticleRelocationBatch(
            id: articleRecord.id,
            moves: Array(articleRecord.moves.prefix(articleRecord.completedMoveCount)),
            fileDestinations: articleRecord.fileDestinations.map {
              .init(
                fileVersionID: $0.fileVersionID,
                destinationRelativePath: $0.destinationRelativePath
              )
            },
            createdDirectoryRelativePaths: articleRecord.createdDirectoryRelativePaths,
            emptySourceDirectoryRelativePaths: articleRecord.emptySourceDirectoryRelativePaths
          )
          if databaseCommitted {
            try commitArticleRelocations(batch, in: libraryRoot)
          } else {
            try rollbackArticleRelocations(batch, in: libraryRoot)
          }
          continue
        }
        let record = try JSONDecoder().decode(
          RelocationTransactionRecord.self,
          from: data
        )
        let databaseCommitted = record.moves.allSatisfy {
          knownRelativePaths.contains($0.destinationRelativePath)
        }
        if !databaseCommitted {
          let batch = RelocationBatch(
            id: record.id,
            relocations: record.moves.map {
              FileRelocation(
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
          try rollbackRelocations(batch, in: libraryRoot)
        } else {
          try removeIfPresent(safeJournal)
        }
      } catch {
        if let relativePath = try? LibraryPathSafety.relativePath(of: journal, inside: libraryRoot),
          let safeJournal = try? LibraryPathSafety.url(for: relativePath, inside: libraryRoot)
        {
          let invalidPath =
            ".paperlib/operations/\(UUID().uuidString)-\(journal.lastPathComponent).invalid"
          if let invalidURL = try? LibraryPathSafety.url(for: invalidPath, inside: libraryRoot) {
            try? fileManager.moveItem(at: safeJournal, to: invalidURL)
          }
        }
        warnings.append("已隔离损坏的文件移动记录 \(journal.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    return warnings
  }
}
