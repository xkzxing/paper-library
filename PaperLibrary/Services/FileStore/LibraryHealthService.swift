import CryptoKit
import Foundation
import SwiftData

struct ReconciliationInput: Sendable {
    let id: UUID
    let relativePath: String
    let sha256: String
}

struct ReconciliationMatch: Sendable {
    let id: UUID
    let newRelativePath: String?
}

struct LibraryHealthReport: Sendable, Equatable {
    let checkedAt: Date
    let checkedFileCount: Int
    let relocatedFileCount: Int
    let missingFileCount: Int
    let repairedMetadataCount: Int
    let transactionWarnings: [String]
}

actor FileReconciliationScanner {
    private let fileManager = FileManager.default

    func scan(_ inputs: [ReconciliationInput], in rootURL: URL) throws -> [ReconciliationMatch] {
        let missing = inputs.filter {
            guard let url = try? LibraryPathSafety.url(
                for: $0.relativePath,
                inside: rootURL,
                requirePDF: true
            ) else { return true }
            return !fileManager.fileExists(atPath: url.path)
        }
        guard !missing.isEmpty else { return [] }

        let missingIDs = Set(missing.map(\.id))
        let occupiedPaths = Set(inputs.compactMap { input -> String? in
            guard !missingIDs.contains(input.id),
                  let url = try? LibraryPathSafety.url(
                    for: input.relativePath,
                    inside: rootURL,
                    requirePDF: true
                  )
            else { return nil }
            return url.standardizedFileURL.path
        })

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return missing.map { ReconciliationMatch(id: $0.id, newRelativePath: nil) } }

        var hashes: [String: [URL]] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pdf" {
            guard !occupiedPaths.contains(url.standardizedFileURL.path),
                  let relativePath = try? LibraryPathSafety.relativePath(of: url, inside: rootURL),
                  let safeURL = try? LibraryPathSafety.url(
                    for: relativePath,
                    inside: rootURL,
                    requirePDF: true,
                    requireExistingRegularFile: true
                  ),
                  let hash = try? sha256(at: safeURL)
            else { continue }
            hashes[hash, default: []].append(safeURL)
        }

        var consumedPaths: Set<String> = []
        return missing.map { input in
            guard !input.sha256.isEmpty,
                  let available = hashes[input.sha256]?.filter({ !consumedPaths.contains($0.path) }),
                  available.count == 1,
                  let url = available.first,
                  let relativePath = try? LibraryPathSafety.relativePath(of: url, inside: rootURL)
            else { return ReconciliationMatch(id: input.id, newRelativePath: nil) }
            consumedPaths.insert(url.path)
            return ReconciliationMatch(id: input.id, newRelativePath: relativePath)
        }
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class FileReconciliationCoordinator: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var lastReport: LibraryHealthReport?
    @Published var errorText: String?
    private let scanner = FileReconciliationScanner()
    private let fileActor = LibraryFileActor()

    @discardableResult
    func reconcile(rootURL: URL, modelContext: ModelContext) async -> LibraryHealthReport? {
        guard !isChecking else { return nil }
        isChecking = true
        errorText = nil
        defer { isChecking = false }
        do {
            let versions = try modelContext.fetch(FetchDescriptor<FileVersion>())
            let journalWarnings = try await fileActor.recoverRelocationTransactions(
                knownRelativePaths: Set(versions.map(\.relativePath)),
                in: rootURL
            )
            let inputs = versions.map {
                ReconciliationInput(id: $0.id, relativePath: $0.relativePath, sha256: $0.sha256)
            }
            let matches = try await scanner.scan(inputs, in: rootURL)
            var unresolved = 0
            var relocated = 0
            var repairedMetadata = 0
            var hasChanges = !matches.isEmpty

            for match in matches {
                guard let version = versions.first(where: { $0.id == match.id }) else { continue }
                if let path = match.newRelativePath {
                    version.relativePath = path
                    relocated += 1
                } else {
                    unresolved += 1
                    version.work?.needsReview = true
                    version.work?.metadataConflictNote = "找不到资料库中的 PDF 文件：\(version.relativePath)"
                }
            }

            let missingPrefix = "找不到资料库中的 PDF 文件："
            var visitedWorkIDs: Set<UUID> = []
            for work in versions.compactMap(\.work)
                where visitedWorkIDs.insert(work.id).inserted {
                let stillMissing = work.fileVersions.first { version in
                    guard let url = try? LibraryPathSafety.url(
                        for: version.relativePath,
                        inside: rootURL,
                        requirePDF: true
                    ) else { return true }
                    return !FileManager.default.fileExists(atPath: url.path)
                }
                if let stillMissing {
                    let message = missingPrefix + stillMissing.relativePath
                    if !work.needsReview || work.metadataConflictNote != message {
                        hasChanges = true
                    }
                    work.needsReview = true
                    work.metadataConflictNote = message
                } else if work.metadataConflictNote?.hasPrefix(missingPrefix) == true,
                          work.duplicateCandidateWorkID == nil {
                    work.needsReview = false
                    work.metadataConflictNote = nil
                    hasChanges = true
                }
            }

            for version in versions {
                guard let work = version.work,
                      LocalMetadataRepairRules.needsRepair(work: work, version: version),
                      let metadata = try? await fileActor.extractMetadata(
                        at: version.relativePath,
                        in: rootURL
                      )
                else { continue }
                if LocalMetadataRepairRules.apply(metadata, to: work, version: version) {
                    hasChanges = true
                    repairedMetadata += 1
                }
            }
            if hasChanges { try modelContext.save() }
            if !journalWarnings.isEmpty {
                errorText = journalWarnings.joined(separator: "\n")
            }
            let report = LibraryHealthReport(
                checkedAt: .now,
                checkedFileCount: versions.count,
                relocatedFileCount: relocated,
                missingFileCount: unresolved,
                repairedMetadataCount: repairedMetadata,
                transactionWarnings: journalWarnings
            )
            lastReport = report
            return report
        } catch {
            modelContext.rollback()
            errorText = "检查资料库文件失败：\(error.localizedDescription)"
            return nil
        }
    }
}
