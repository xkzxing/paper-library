import SwiftData
import SwiftUI

@main
@MainActor
struct PaperLibraryApp: App {
    @StateObject private var libraryAccess: LibraryAccess
    @StateObject private var reconciliationCoordinator = FileReconciliationCoordinator()
    @StateObject private var searchCoordinator = SearchIndexCoordinator()
    private let modelContainer: ModelContainer

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let isRunningTests = AppRuntimeEnvironment.isRunningTests
        let schema = Schema([
            Work.self,
            FileVersion.self,
            Category.self,
            Tag.self,
            PersonalMark.self,
            ReadingProject.self,
            AIAnalysis.self,
            StudyNoteGeneration.self
        ])

        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: isRunningTests)
            let container: ModelContainer
            do {
                container = try ModelContainer(for: schema, configurations: configuration)
            } catch let initialError where !isRunningTests {
                guard DatabaseStoreRecovery.shouldQuarantine(after: initialError) else {
                    throw initialError
                }
                let backupDirectory = try DatabaseStoreRecovery.quarantineStore(at: configuration.url)
                container = try ModelContainer(for: schema, configurations: configuration)
                UserDefaults.standard.set(
                    "原数据库无法打开（\(initialError.localizedDescription)），已安全移到 \(backupDirectory.path)。程序已创建新数据库，并会尝试从资料库清单恢复。",
                    forKey: "databaseRecoveryNotice"
                )
            }
            modelContainer = container

            if !isRunningTests {
                let defaults = UserDefaults.standard
                let migrationKey = "didBackfillAIAnalysisTagsV1"
                if !defaults.bool(forKey: migrationKey) {
                    do {
                        // 只迁移一次；之后用户手动移除的 AI 标签不会在重启时重新出现。
                        let existingTagCount = try container.mainContext.fetchCount(FetchDescriptor<Tag>())
                        if existingTagCount == 0 {
                            _ = try AIAnalysisTagBackfill.run(modelContext: container.mainContext)
                        }
                        defaults.set(true, forKey: migrationKey)
                    } catch {
                        defaults.set(
                            "历史标签整理未完成，下次启动将重试：\(error.localizedDescription)",
                            forKey: "databaseRecoveryNotice"
                        )
                    }
                }
                _ = try? AIAnalysisRecoveryMaintenance.markInterruptedTasks(
                    modelContext: container.mainContext
                )
                _ = try? StudyNoteRecoveryMaintenance.recoverInterruptedTasks(
                    modelContext: container.mainContext
                )
            }

            if isUITesting {
                let category = Category(name: "Uncategorized", sortOrder: 0, isSystemCategory: true)
                let work = Work(
                    title: "界面测试论文",
                    authorsText: "测试作者",
                    publicationYear: 2024,
                    metadataConfirmed: false,
                    primaryCategory: category
                )
                container.mainContext.insert(category)
                container.mainContext.insert(work)
                try container.mainContext.save()

            }

            if isRunningTests {
                let suiteName = isUITesting
                    ? "dev.paperlibrary.PaperLibrary.UITests"
                    : "dev.paperlibrary.PaperLibrary.UnitTests.\(ProcessInfo.processInfo.processIdentifier)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defaults.removePersistentDomain(forName: suiteName)
                let rootURL = FileManager.default.temporaryDirectory
                    .appending(
                        path: "PaperLibraryTests-\(ProcessInfo.processInfo.processIdentifier)",
                        directoryHint: .isDirectory
                    )
                _libraryAccess = StateObject(wrappedValue: LibraryAccess(
                    defaults: defaults,
                    initialRootURL: rootURL
                ))
            } else {
                _libraryAccess = StateObject(wrappedValue: LibraryAccess())
            }
        } catch {
            fatalError("无法创建数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(libraryAccess)
                .environmentObject(reconciliationCoordinator)
                .environmentObject(searchCoordinator)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1_080, height: 720)

        Settings {
            SettingsView()
                .environmentObject(libraryAccess)
                .environmentObject(reconciliationCoordinator)
                .environmentObject(searchCoordinator)
                .modelContainer(modelContainer)
        }
    }
}

enum AppRuntimeEnvironment {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing") ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

enum DatabaseStoreRecovery {
    static func shouldQuarantine(after error: Error) -> Bool {
        var current: NSError? = error as NSError
        let recoverableCocoaCodes: Set<Int> = [
            259,      // 文件内容损坏
            134100,   // 持久化存储版本不兼容
            134110,   // 迁移失败
            134120,
            134130,
            134140,
            134150,
            134180    // SQLite 持久化存储错误
        ]
        while let candidate = current {
            if candidate.domain == NSCocoaErrorDomain,
               recoverableCocoaCodes.contains(candidate.code) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func quarantineStore(at storeURL: URL, fileManager: FileManager = .default) throws -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let directory = storeURL.deletingLastPathComponent()
            .appending(
                path: "PaperLibrary/DatabaseRecovery/\(stamp)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var sources: [URL] = []
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            sources.append(source)
            let destination = directory.appending(path: source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
            let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard sourceSize == destinationSize else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        do {
            for source in sources {
                try fileManager.removeItem(at: source)
            }
        } catch {
            for source in sources where !fileManager.fileExists(atPath: source.path) {
                let backup = directory.appending(path: source.lastPathComponent)
                try? fileManager.copyItem(at: backup, to: source)
            }
            throw error
        }
        return directory
    }
}
