import AppKit
import Foundation

@MainActor
final class LibraryAccess: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var libraryID: UUID?
    @Published private(set) var accessError: String?

    private let defaults: UserDefaults
    private let bookmarkKey = "libraryRootBookmark"
    private let libraryIDKey = "libraryIdentifier"
    private var isAccessingCurrentURL = false

    init(defaults: UserDefaults = .standard, initialRootURL: URL? = nil) {
        self.defaults = defaults
        if let initialRootURL {
            do {
                try setRootURL(initialRootURL, persistBookmark: false)
            } catch {
                accessError = error.localizedDescription
            }
        } else {
            restoreBookmark()
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择文献资料库文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            try setRootURL(selectedURL, persistBookmark: true)
        } catch {
            accessError = error.localizedDescription
        }
    }

    func dismissError() {
        accessError = nil
    }

    private func restoreBookmark() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            try setRootURL(url, persistBookmark: isStale)
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            accessError = "无法恢复资料库访问权限，请重新选择文件夹。"
        }
    }

    private func setRootURL(_ url: URL, persistBookmark: Bool) throws {
        let previousURL = rootURL
        let previousWasAccessing = isAccessingCurrentURL
        let standardizedURL = url.standardizedFileURL
        let newURLIsAccessing = standardizedURL.startAccessingSecurityScopedResource()

        do {
            let expectedID = defaults.string(forKey: libraryIDKey).flatMap(UUID.init(uuidString:))
            let descriptor = try LibraryLayout.openOrCreate(at: standardizedURL, expectedID: expectedID)

            if persistBookmark {
                let data = try standardizedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                defaults.set(data, forKey: bookmarkKey)
            }

            if previousWasAccessing {
                previousURL?.stopAccessingSecurityScopedResource()
            }
            defaults.set(descriptor.id.uuidString, forKey: libraryIDKey)
            isAccessingCurrentURL = newURLIsAccessing
            rootURL = standardizedURL
            libraryID = descriptor.id
            accessError = nil
        } catch {
            if newURLIsAccessing {
                standardizedURL.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }
}

struct LibraryDescriptor: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let createdAt: Date

    init(id: UUID = UUID(), schemaVersion: Int = currentSchemaVersion, createdAt: Date = .now) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

enum LibraryAccessError: LocalizedError {
    case identifierMismatch(expected: UUID, found: UUID)
    case missingIdentifier
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .identifierMismatch(expected, found):
            return "所选文件夹属于另一套资料库。当前资料库标识为 \(expected.uuidString)，所选资料库标识为 \(found.uuidString)。"
        case .missingIdentifier:
            return "所选文件夹没有资料库标识，不能把现有数据库直接关联到这个文件夹。"
        case let .unsupportedSchema(version):
            return "资料库结构版本 \(version) 暂不受支持。"
        }
    }
}

enum LibraryPathError: LocalizedError {
    case invalidRelativePath(String)
    case symbolicLink(String)
    case outsideLibrary(String)
    case notPDF(String)
    case notRegularFile(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            return "资料库文件路径无效：\(path)"
        case let .symbolicLink(path):
            return "资料库路径不能经过符号链接：\(path)"
        case let .outsideLibrary(path):
            return "文件不在当前资料库内：\(path)"
        case let .notPDF(path):
            return "文件不是 PDF：\(path)"
        case let .notRegularFile(path):
            return "资料库文件不存在或不是普通文件：\(path)"
        }
    }
}

enum LibraryPathSafety {
    static func url(
        for relativePath: String,
        inside libraryRoot: URL,
        requirePDF: Bool = false,
        requireExistingRegularFile: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard libraryRoot.isFileURL,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~")
        else { throw LibraryPathError.invalidRelativePath(relativePath) }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw LibraryPathError.invalidRelativePath(relativePath) }

        let lexicalRoot = libraryRoot.standardizedFileURL
        var candidate = lexicalRoot
        for component in components {
            candidate.append(path: String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                throw LibraryPathError.symbolicLink(relativePath)
            }
        }
        candidate = candidate.standardizedFileURL
        guard candidate.path.hasPrefix(lexicalRoot.path + "/") else {
            throw LibraryPathError.outsideLibrary(relativePath)
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw LibraryPathError.outsideLibrary(relativePath)
        }
        if requirePDF, candidate.pathExtension.lowercased() != "pdf" {
            throw LibraryPathError.notPDF(relativePath)
        }
        if requireExistingRegularFile {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw LibraryPathError.notRegularFile(relativePath)
            }
        }
        return candidate
    }

    static func relativePath(of url: URL, inside libraryRoot: URL) throws -> String {
        let root = libraryRoot.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw LibraryPathError.outsideLibrary(url.path)
        }
        let relativePath = String(candidate.path.dropFirst(root.path.count + 1))
        _ = try self.url(for: relativePath, inside: libraryRoot)
        return relativePath
    }
}

enum LibraryLayout {
    private static let descriptorPath = ".paperlib/library.json"

    static func ensureExists(at rootURL: URL, fileManager: FileManager = .default) throws {
        _ = try openOrCreate(at: rootURL, expectedID: nil, fileManager: fileManager)
    }

    static func openOrCreate(
        at rootURL: URL,
        expectedID: UUID?,
        fileManager: FileManager = .default
    ) throws -> LibraryDescriptor {
        guard rootURL.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let descriptorURL = try LibraryPathSafety.url(
            for: descriptorPath,
            inside: rootURL,
            fileManager: fileManager
        )
        let descriptor: LibraryDescriptor

        if fileManager.fileExists(atPath: descriptorURL.path) {
            let data = try Data(contentsOf: descriptorURL)
            descriptor = try JSONDecoder().decode(LibraryDescriptor.self, from: data)
        } else {
            if expectedID != nil {
                throw LibraryAccessError.missingIdentifier
            }
            let paperlibURL = try LibraryPathSafety.url(
                for: ".paperlib",
                inside: rootURL,
                fileManager: fileManager
            )
            try fileManager.createDirectory(at: paperlibURL, withIntermediateDirectories: true)
            descriptor = LibraryDescriptor()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(descriptor).write(to: descriptorURL, options: .atomic)
        }

        guard descriptor.schemaVersion <= LibraryDescriptor.currentSchemaVersion else {
            throw LibraryAccessError.unsupportedSchema(descriptor.schemaVersion)
        }
        if let expectedID, descriptor.id != expectedID {
            throw LibraryAccessError.identifierMismatch(expected: expectedID, found: descriptor.id)
        }

        for path in [".paperlib/imports", ".paperlib/backups", ".paperlib/operations", "Uncategorized"] {
            let directory = try LibraryPathSafety.url(
                for: path,
                inside: rootURL,
                fileManager: fileManager
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return descriptor
    }
}
