import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @EnvironmentObject private var reconciliationCoordinator: FileReconciliationCoordinator
    @EnvironmentObject private var searchCoordinator: SearchIndexCoordinator
    @Query(sort: \Work.dateAdded, order: .reverse) private var works: [Work]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \PersonalMark.sortOrder) private var personalMarks: [PersonalMark]
    @Query(sort: \ReadingProject.name) private var projects: [ReadingProject]
    @StateObject private var importer = ImportCoordinator()
    @StateObject private var manifestCoordinator = ManifestCoordinator()
    @StateObject private var batchArchiver = BatchArchiveCoordinator()
    @StateObject private var batchMetadataCoordinator = BatchMetadataCoordinator()
    @StateObject private var batchAIAnalysisCoordinator = BatchAIAnalysisCoordinator()
    @StateObject private var batchBibTeXCoordinator = BatchBibTeXCoordinator()
    @StateObject private var studyNoteCoordinator = StudyNoteCoordinator()
    @StateObject private var listController = LibraryListController()
    @StateObject private var mutationStore = LibraryMutationStore()
    @State private var selectedWorkIDs: Set<UUID> = []
    @State private var inspectedWorkID: UUID?
    @State private var sidebarSelection: SidebarSelection? = .all
    @AppStorage("librarySidebarSelection") private var persistedSidebarSelection = "all"
    @State private var hasRestoredSidebarSelection = false
    @State private var searchText = ""
    @State private var effectiveSearchText = ""
    @AppStorage("librarySearchMode") private var searchMode: LibrarySearchMode = .keyword
    @AppStorage(LocalSearchConfiguration.smartSearchDepthKey)
    private var smartSearchDepth: SmartSearchDepth = .balanced
    @AppStorage(LocalSearchConfiguration.smartSearchResultLimitKey)
    private var smartSearchResultLimit = 10
    @State private var searchOptions = LibrarySearchOptions()
    @State private var smartSearchScopeRevision: UInt64 = 0
    @State private var isDropTargeted = false
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var workIDsForNewProject: Set<UUID> = []
    @State private var projectPendingDeletion: ReadingProject?
    @State private var projectPendingRename: ReadingProject?
    @State private var renamedProjectName = ""
    @AppStorage("librarySortField") private var sortField: LibrarySortField = .dateAdded
    @AppStorage("librarySortDirection") private var sortDirection: LibrarySortDirection = .descending
    @State private var localError: String?
    @State private var databaseRecoveryNotice = UserDefaults.standard.string(
        forKey: "databaseRecoveryNotice"
    )
    @State private var categoryPendingDeletion: Category?
    @State private var replacementCategoryID: UUID?
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var selectedPersonalMarkIDs: Set<UUID> = []
    @State private var showingTagFilter = false
    @State private var tagFilterSearchText = ""
    @State private var showingBatchTagEditor = false
    @State private var batchTagSearchText = ""
    @State private var batchNewTagName = ""
    @State private var batchTagIDs: Set<UUID> = []
    @State private var batchTagOperation: BatchTagOperation = .add
    @State private var showingBatchPersonalMarkEditor = false
    @State private var batchPersonalMarkIDs: Set<UUID> = []
    @State private var batchPersonalMarkOperation: BatchTagOperation = .add
    @State private var showingBatchReprocessConfirmation = false
    @State private var showingBatchReviewConfirmation = false
    @State private var batchActionStatus: String?
    @State private var isFetchingBibTeX = false
    @State private var pendingBibTeXReview: PendingBibTeXReview?
    @State private var showingBatchBibTeXMode = false
    @State private var pendingBatchBibTeXPreparation: BatchBibTeXPreparation?
    @State private var batchBibTeXSummary: BatchBibTeXExportSummary?
    @AppStorage("crossrefContactEmail") private var crossrefEmail = ""
    @AppStorage(AuthorYearReferencePreferences.authorLimitKey)
    private var authorYearReferenceAuthorLimit = AuthorYearReferencePreferences.defaultAuthorLimit
    @State private var workIDPendingStudyNoteCreation: UUID?
    @State private var pendingWorkDeletion: [Work] = []
    @State private var showingWorkDeletion = false
    @State private var searchIndexVersion: UInt64 = 0

    private var filteredWorks: [Work] {
        let snapshotsAreCurrent = listController.snapshots.count == works.count &&
            works.allSatisfy { listController.snapshots[$0.id] != nil }
        let snapshots = snapshotsAreCurrent
            ? listController.orderedSnapshots
            : works.map(LibrarySearchRules.snapshot)
        let buildIDs = {
            let matched = snapshots.filter { snapshot in
                guard matchesSidebar(snapshot), matchesTagFilter(snapshot) else { return false }
                guard LibrarySearchRules.matches(snapshot, query: "", options: searchOptions) else {
                    return false
                }
                let query = effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                if searchMode == .smart {
                    return activeSearchMatches[snapshot.workID] != nil
                }
                let metadataMatches = LibrarySearchRules.matches(
                    snapshot,
                    query: query,
                    options: searchOptions
                )
                return metadataMatches || activeSearchMatches[snapshot.workID] != nil
            }
            let sortedSnapshots: [LibraryWorkSnapshot]
            if !effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sortedSnapshots = matched.sorted { left, right in
                    let leftScore = combinedSearchScore(for: left)
                    let rightScore = combinedSearchScore(for: right)
                    if leftScore != rightScore { return leftScore > rightScore }
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
            } else if sidebarSelection == .recent {
                sortedSnapshots = LibrarySortRules.sorted(
                    matched,
                    by: .dateAdded,
                    direction: .descending,
                    priorityValues: [:]
                )
            } else {
                sortedSnapshots = LibrarySortRules.sorted(
                    matched,
                    by: activeSortField,
                    direction: activeSortDirection,
                    priorityValues: selectedProject?.priorityValues ?? [:]
                )
            }
            return sortedSnapshots.map(\.workID)
        }
        let sortedIDs: [UUID]
        if snapshotsAreCurrent {
            sortedIDs = listController.workIDs(
                for: LibraryListRequestKey(
                    snapshotVersion: listController.version,
                    sidebarSelection: sidebarSelection,
                    query: effectiveSearchText,
                    searchMode: searchMode,
                    searchOptions: searchOptions,
                    selectedTagIDs: selectedTagIDs,
                    selectedPersonalMarkIDs: selectedPersonalMarkIDs,
                    sortField: activeSortField,
                    sortDirection: activeSortDirection,
                    projectID: selectedProject?.id,
                    projectPriorityData: selectedProject?.priorityData,
                    searchResultVersion: searchCoordinator.resultVersion
                ),
                build: buildIDs
            )
        } else {
            sortedIDs = buildIDs()
        }
        let workByID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        return sortedIDs.compactMap { workByID[$0] }
    }

    private var activeSearchMatches: [UUID: SearchWorkMatch] {
        searchMode == .smart
            ? searchCoordinator.smartMatches
            : searchCoordinator.keywordMatches
    }

    private var searchSnapshots: [SearchDocumentSnapshot] {
        works.compactMap { work in
            guard let version = work.preferredFileVersion else { return nil }
            return SearchDocumentSnapshot(
                workID: work.id,
                title: work.title,
                authors: work.authorsText,
                abstractText: work.abstractText,
                publicationYear: work.publicationYear,
                doi: work.doi,
                duplicateCandidateWorkID: work.duplicateCandidateWorkID,
                fileVersionID: version.id,
                relativePath: version.relativePath,
                sha256: version.sha256
            )
        }
    }

    private func combinedSearchScore(for snapshot: LibraryWorkSnapshot) -> Double {
        let metadata = Double(LibrarySearchRules.relevanceScore(
            for: snapshot,
            query: effectiveSearchText,
            options: searchOptions
        )) / 100
        let passage = activeSearchMatches[snapshot.workID]?.score ?? 0
        if searchMode == .smart {
            return passage
        }
        return (metadata > 0 ? 2 + metadata : 0) + (passage > 0 ? 1 : 0)
    }

    private func displayedSearchMatch(for work: Work) -> SearchWorkMatch? {
        guard !effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let passageMatch = activeSearchMatches[work.id] {
            return passageMatch
        }
        if searchMode == .smart { return nil }
        let snapshot = listController.snapshot(for: work.id) ?? LibrarySearchRules.snapshot(for: work)
        guard let reason = LibrarySearchRules.primaryMatchReason(
            for: snapshot,
            query: effectiveSearchText,
            options: searchOptions
        ) else { return nil }
        return SearchWorkMatch(
            workID: work.id,
            score: combinedSearchScore(for: snapshot),
            kind: .metadata,
            reason: reason,
            passages: []
        )
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            effectiveSearchText = ""
            searchCoordinator.cancelSmartSearch()
            searchCoordinator.searchKeywords("", matchMode: searchOptions.matchMode)
            return
        }
        effectiveSearchText = query
        if searchMode == .smart {
            searchCoordinator.runSmartSearch(
                query,
                scope: smartSearchScope,
                preferences: SmartSearchPreferences(
                    depth: smartSearchDepth,
                    resultLimit: smartSearchResultLimit
                )
            )
        } else {
            searchCoordinator.searchKeywords(query, matchMode: searchOptions.matchMode)
        }
    }

    private var smartSearchReadinessText: String? {
        let profile = searchCoordinator.selectedProfile
        if !searchCoordinator.isModelVerified(profile) || !searchCoordinator.isRerankerVerified {
            return "需先在设置中验证云端语义服务"
        }
        if !searchCoordinator.modelsTested {
            return "云端语义服务未通过实际测试"
        }
        if (searchCoordinator.profileStatistics[profile]?.embeddedChunks ?? 0) == 0 {
            return "需先在设置中建立语义索引"
        }
        return nil
    }

    private var searchPrompt: String {
        if searchMode == .smart {
            return "输入问题，按回车搜索"
        }
        return searchOptions.scope == .all
            ? "搜索文献"
            : "搜索\(searchOptions.scope.title)"
    }

    private var smartSearchScope: SmartSearchScope {
        let snapshotsAreCurrent = listController.snapshots.count == works.count &&
            works.allSatisfy { listController.snapshots[$0.id] != nil }
        let snapshots = snapshotsAreCurrent
            ? listController.orderedSnapshots
            : works.map(LibrarySearchRules.snapshot)
        let allowed = snapshots.filter {
            matchesSidebar($0) &&
                matchesTagFilter($0) &&
                LibrarySearchRules.matches($0, query: "", options: searchOptions)
        }
        return SmartSearchScope(
            allowedWorkIDs: Set(allowed.map(\.workID)),
            revision: smartSearchScopeRevision
        )
    }

    private func smartSearchScopeDidChange() {
        smartSearchScopeRevision &+= 1
        if searchMode == .smart {
            searchCoordinator.invalidateSmartSearchForScopeChange()
        }
    }

    private var selectedTags: [Tag] {
        tags.filter { selectedTagIDs.contains($0.id) }
    }

    private var visibleTagFilterTags: [Tag] {
        let query = tagFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var tagRevision: String {
        tags.map(\.id.uuidString).joined(separator: "|")
    }

    private var sidebarCatalogRevision: String {
        (categories.map(\.id.uuidString) + projects.map(\.id.uuidString))
            .sorted()
            .joined(separator: "|")
    }

    private var selectedWork: Work? {
        guard let inspectedWorkID else { return nil }
        return works.first { $0.id == inspectedWorkID }
    }

    private var selectedWorks: [Work] {
        // 选择集合已经在列表变化时同步，不需要为工具栏操作再次筛选和排序整库。
        works.filter { selectedWorkIDs.contains($0.id) }
    }

    private var visibleBatchTags: [Tag] {
        let available = batchTagOperation == .add ? tags : tags.filter { tag in
            selectedWorks.contains { work in work.tags.contains(where: { $0.id == tag.id }) }
        }
        let query = batchTagSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return available }
        return available.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isBatchWorking: Bool {
        batchArchiver.isWorking || batchMetadataCoordinator.isWorking ||
            batchAIAnalysisCoordinator.isWorking || batchBibTeXCoordinator.isWorking
    }

    private var operationStatusText: String? {
        if let value = searchCoordinator.maintenanceProgress?.message { return value }
        if let value = searchCoordinator.status.message { return value }
        if importer.isImporting, let value = importer.statusText { return value }
        if studyNoteCoordinator.isGenerating, let value = studyNoteCoordinator.statusText {
            return "精读笔记：\(value)"
        }
        if batchAIAnalysisCoordinator.isWorking,
           let value = batchAIAnalysisCoordinator.statusText { return value }
        if batchMetadataCoordinator.isWorking,
           let value = batchMetadataCoordinator.statusText { return value }
        if batchBibTeXCoordinator.isWorking,
           let value = batchBibTeXCoordinator.statusText { return value }
        if let value = batchActionStatus { return value }
        if let value = batchAIAnalysisCoordinator.statusText { return value }
        if let value = batchMetadataCoordinator.statusText { return value }
        return importer.statusText
    }

    private var selectedEditableCategory: Category? {
        guard case let .category(id) = sidebarSelection,
              let category = categories.first(where: { $0.id == id }),
              !category.isSystemCategory
        else { return nil }
        return category
    }

    private var selectedProject: ReadingProject? {
        guard case let .project(id) = sidebarSelection else { return nil }
        return projects.first { $0.id == id }
    }

    private var activeSortField: LibrarySortField {
        guard let rawValue = selectedProject?.sortFieldRawValue,
              let field = LibrarySortField(rawValue: rawValue)
        else { return sortField }
        return field
    }

    private var activeSortDirection: LibrarySortDirection {
        guard let rawValue = selectedProject?.sortDirectionRawValue,
              let direction = LibrarySortDirection(rawValue: rawValue)
        else { return sortDirection }
        return direction
    }

    private var sortFieldBinding: Binding<LibrarySortField> {
        Binding(
            get: { activeSortField },
            set: { newValue in
                if let selectedProject {
                    selectedProject.sortFieldRawValue = newValue.rawValue
                    saveRootChanges("保存项目排序")
                } else {
                    sortField = newValue
                }
            }
        )
    }

    private var sortDirectionBinding: Binding<LibrarySortDirection> {
        Binding(
            get: { activeSortDirection },
            set: { newValue in
                if let selectedProject {
                    selectedProject.sortDirectionRawValue = newValue.rawValue
                    saveRootChanges("保存项目排序")
                } else {
                    sortDirection = newValue
                }
            }
        )
    }

    private var presentedErrorText: String? {
        if let value = searchCoordinator.errorText { return value }
        if let value = importer.errorText { return value }
        if let value = importer.noticeText { return value }
        if let value = libraryAccess.accessError { return value }
        if let value = manifestCoordinator.errorText { return value }
        if let value = batchArchiver.errorText { return value }
        if let value = batchMetadataCoordinator.errorText { return value }
        if let value = batchAIAnalysisCoordinator.errorText { return value }
        if let value = studyNoteCoordinator.errorText { return value }
        if let value = batchBibTeXCoordinator.errorText { return value }
        if let value = reconciliationCoordinator.errorText { return value }
        if let value = localError { return value }
        return databaseRecoveryNotice
    }

    var body: some View {
        presentationContent
    }

    private var navigationContent: some View {
        NavigationSplitView {
            sidebar
        } content: {
            libraryList
        } detail: {
            inspector
        }
        .navigationTitle("文献库")
        .task(id: "\(searchMode.rawValue)|\(searchText)") {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                effectiveSearchText = ""
                searchCoordinator.cancelSmartSearch()
                searchCoordinator.searchKeywords("", matchMode: searchOptions.matchMode)
                return
            }
            if searchMode == .smart {
                searchCoordinator.cancelSmartSearch()
                effectiveSearchText = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            if searchCoordinator.isSmartMode || searchCoordinator.isSearching {
                searchCoordinator.cancelSmartSearch()
            }
            effectiveSearchText = query
            searchCoordinator.searchKeywords(query, matchMode: searchOptions.matchMode)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                LibrarySearchField(
                    searchText: $searchText,
                    mode: $searchMode,
                    options: $searchOptions,
                    prompt: searchPrompt,
                    isSearching: searchCoordinator.isSearching,
                    readinessText: searchMode == .smart ? smartSearchReadinessText : nil,
                    onSubmit: submitSearch
                )
            }
            ToolbarItemGroup {
                Button {
                    showingTagFilter.toggle()
                } label: {
                    Label(
                        selectedTagIDs.isEmpty && selectedPersonalMarkIDs.isEmpty
                            ? "筛选标签" : "标签 \(selectedTagIDs.count + selectedPersonalMarkIDs.count)",
                        systemImage: selectedTagIDs.isEmpty && selectedPersonalMarkIDs.isEmpty
                            ? "tag" : "tag.fill"
                    )
                }
                .help(
                    selectedTagIDs.isEmpty && selectedPersonalMarkIDs.isEmpty
                        ? "按标签或个人标记筛选文献"
                        : "已选择 \(selectedTagIDs.count + selectedPersonalMarkIDs.count) 个筛选条件"
                )
                .accessibilityLabel("按标签筛选文献")
                .popover(isPresented: $showingTagFilter, arrowEdge: .top) {
                    tagFilterPopover
                }

                if sidebarSelection == .recent {
                    Label("最近导入按加入时间排序", systemImage: "arrow.down")
                        .help("最近导入始终按加入时间从新到旧排列")
                } else {
                    Menu {
                        Picker("排序依据", selection: sortFieldBinding) {
                            ForEach(LibrarySortField.allCases) { field in
                                Text(field.title).tag(field)
                            }
                        }
                        Picker("排序方向", selection: sortDirectionBinding) {
                            ForEach(LibrarySortDirection.allCases) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                    } label: {
                        Label("按\(activeSortField.title)排序", systemImage: activeSortDirection == .ascending ? "arrow.up" : "arrow.down")
                    }
                    .help(selectedProject == nil
                          ? "全部列表按\(activeSortField.title)\(activeSortDirection.title)排列"
                          : "当前项目在每个优先级内按\(activeSortField.title)\(activeSortDirection.title)排列")
                }
                if !selectedWorkIDs.isEmpty {
                    if let selectedProject {
                        Menu("优先级", systemImage: "exclamationmark.circle") {
                            ForEach(ProjectWorkPriority.menuOrder) { priority in
                                Button {
                                    setPriority(priority, for: selectedWorks, in: selectedProject)
                                } label: {
                                    Label(
                                        priority.title,
                                        systemImage: selectedWorks.allSatisfy {
                                            selectedProject.priority(for: $0.id) == priority
                                        } ? "checkmark" : "circle"
                                    )
                                }
                            }
                        }
                        .help("设置所选文献在当前项目中的优先级")
                    }
                    Menu("管理项目", systemImage: "rectangle.stack") {
                        if projects.isEmpty {
                            Button("新建项目…") {
                                presentNewProject(adding: selectedWorkIDs)
                            }
                        } else {
                            ForEach(projects) { project in
                                let containsAll = selectedWorks.allSatisfy {
                                    $0.projects.contains(where: { $0.id == project.id })
                                }
                                Button {
                                    setSelectedWorks(in: project, included: !containsAll)
                                } label: {
                                    Label(project.name, systemImage: containsAll ? "checkmark" : "rectangle.stack")
                                }
                            }
                        }
                    }
                    .help("将所选文献加入项目，或从项目移除")
                }
                if selectedWorkIDs.count > 1 {
                    Menu("批量操作", systemImage: "checklist") {
                        Button("管理标签…", systemImage: "tag") {
                            batchTagSearchText = ""
                            batchNewTagName = ""
                            batchTagIDs.removeAll()
                            batchTagOperation = .add
                            showingBatchTagEditor = true
                        }
                        Button("管理个人标记…", systemImage: "bookmark") {
                            batchPersonalMarkIDs.removeAll()
                            batchPersonalMarkOperation = .add
                            showingBatchPersonalMarkEditor = true
                        }
                        Button("删除所选文章…", systemImage: "trash", role: .destructive) {
                            presentWorkDeletion(selectedWorks)
                        }
                        Menu("修改主分类") {
                            ForEach(categories) { category in
                                Button(category.name) { batchReassign(to: category) }
                            }
                        }
                        Button("重新核对 Crossref", systemImage: "arrow.triangle.2.circlepath") {
                            refreshSelectedMetadata()
                        }
                        Divider()
                        Button("快速提取", systemImage: "sparkles") {
                            startBatchAI(resetBeforeAnalysis: false)
                        }
                        Button("重新处理…", systemImage: "arrow.counterclockwise") {
                            showingBatchReprocessConfirmation = true
                        }
                        Divider()
                        Button("标记为已检查…", systemImage: "checkmark.seal") {
                            showingBatchReviewConfirmation = true
                        }
                        Divider()
                        Button("导出 BibTeX…", systemImage: "square.and.arrow.up") {
                            showingBatchBibTeXMode = true
                        }
                    }
                    .disabled(isBatchWorking)
                    .help("批量修改或处理所选文献")
                }
            }
        }
    }

    private var interactionContent: some View {
        navigationContent
        .onDrop(
            of: [UTType.url.identifier],
            delegate: LibraryFileImportDropDelegate(
                isTargeted: $isDropTargeted,
                receiveDrop: receiveExternalFileDrop
            )
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.tint.opacity(0.12))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let statusText = operationStatusText {
                HStack(spacing: 8) {
                    if importer.isImporting || isBatchWorking || isFetchingBibTeX ||
                        searchCoordinator.isSearching || searchCoordinator.status.isWorking ||
                        searchCoordinator.maintenanceState.isActive ||
                        studyNoteCoordinator.isGenerating {
                        ProgressView().controlSize(.small)
                    }
                    Text(statusText).font(.caption)
                    Spacer()
                    if batchAIAnalysisCoordinator.isWorking {
                        Button("取消") { batchAIAnalysisCoordinator.cancel() }
                            .font(.caption)
                    } else if batchMetadataCoordinator.isWorking {
                        Button("取消") { batchMetadataCoordinator.cancel() }
                            .font(.caption)
                    } else if batchBibTeXCoordinator.isWorking {
                        Button("取消") { batchBibTeXCoordinator.cancel() }
                            .font(.caption)
                    } else if studyNoteCoordinator.isGenerating {
                        Button("显示处理窗口") { studyNoteCoordinator.isPresenting = true }
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private var lifecycleContent: some View {
        interactionContent
        .onAppear {
            restoreSidebarSelection()
            listController.rebuild(from: works)
        }
        .task(id: libraryAccess.rootURL.map { "\(libraryAccess.libraryID?.uuidString ?? "")|\($0.standardizedFileURL.path)" }) {
            guard let rootURL = libraryAccess.rootURL, let libraryID = libraryAccess.libraryID else { return }
            seedDefaultCategories()
            let canContinue = await manifestCoordinator.restoreIfNeeded(
                libraryID: libraryID,
                rootURL: rootURL,
                modelContext: modelContext
            )
            guard canContinue else { return }
            importer.recoverPendingImports(in: rootURL, modelContext: modelContext)
            await reconciliationCoordinator.reconcile(rootURL: rootURL, modelContext: modelContext)
            do {
                try await ArchiveMaintenance.normalizeStructuredFilenames(
                    works: works,
                    rootURL: rootURL,
                    modelContext: modelContext
                )
            } catch {
                localError = "整理文章文件夹失败：\(error.localizedDescription)"
            }
            exportManifest()
        }
        .task(id: "\(libraryAccess.libraryID?.uuidString ?? "")|\(searchIndexVersion)") {
            guard let rootURL = libraryAccess.rootURL,
                  let libraryID = libraryAccess.libraryID else { return }
            searchCoordinator.configure(
                libraryID: libraryID,
                rootURL: rootURL,
                snapshots: searchSnapshots
            )
            if searchMode == .keyword {
                searchCoordinator.searchKeywords(
                    effectiveSearchText,
                    matchMode: searchOptions.matchMode
                )
            }
        }
        .background {
            ManifestAutosaveObserver(
                coordinator: manifestCoordinator,
                libraryID: libraryAccess.libraryID,
                rootURL: libraryAccess.rootURL
            )
        }
        .onChange(of: tagRevision) { _, _ in
            selectedTagIDs.formIntersection(Set(tags.map(\.id)))
        }
        .onChange(of: sidebarSelection) { _, selection in
            if hasRestoredSidebarSelection, let selection {
                persistedSidebarSelection = selection.persistenceValue
            }
            smartSearchScopeDidChange()
            synchronizeSelectionWithFilter()
        }
        .onChange(of: sidebarCatalogRevision) { _, _ in
            validateSidebarSelection()
        }
        .onChange(of: effectiveSearchText) { _, _ in synchronizeSelectionWithFilter() }
        .onChange(of: searchOptions) { _, options in
            if searchMode == .keyword {
                searchCoordinator.searchKeywords(effectiveSearchText, matchMode: options.matchMode)
            } else {
                smartSearchScopeDidChange()
            }
            synchronizeSelectionWithFilter()
        }
        .onChange(of: selectedTagIDs) { _, _ in
            smartSearchScopeDidChange()
            synchronizeSelectionWithFilter()
        }
        .onChange(of: selectedPersonalMarkIDs) { _, _ in
            smartSearchScopeDidChange()
            synchronizeSelectionWithFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            guard notification.object as AnyObject? === modelContext else { return }
            listController.rebuild(from: works)
            searchIndexVersion &+= 1
            smartSearchScopeDidChange()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { exportManifest() }
        }
    }

    private var presentationContent: some View {
        lifecycleContent
        .confirmationDialog(
            "删除文章",
            isPresented: $showingWorkDeletion,
            titleVisibility: .visible
        ) {
            Button("仅从应用移除", role: .destructive) {
                deletePendingWorks(moveFoldersToTrash: false)
            }
            if hasSafeArticleFoldersForPendingDeletion {
                Button("移到废纸篓并移除", role: .destructive) {
                    deletePendingWorks(moveFoldersToTrash: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
        .alert("新建分类", isPresented: $showingNewCategory) {
            TextField("分类名称", text: $newCategoryName)
            Button("取消", role: .cancel) {}
            Button("创建") { addCategory() }
        } message: {
            Text("分类名称同时用于资料库中的物理文件夹。")
        }
        .alert("新建项目", isPresented: $showingNewProject) {
            TextField("项目名称", text: $newProjectName)
            Button("取消", role: .cancel) {}
            Button("创建") { addProject() }
        } message: {
            Text("项目只记录文献归属，不会移动或复制文献文件。")
        }
        .alert("修改项目名称", isPresented: Binding(
            get: { projectPendingRename != nil },
            set: { if !$0 { cancelProjectRename() } }
        )) {
            TextField("项目名称", text: $renamedProjectName)
            Button("取消", role: .cancel) { cancelProjectRename() }
            Button("保存") { renamePendingProject() }
        } message: {
            Text("修改名称不会影响项目中的文献或其优先级。")
        }
        .alert("删除项目", isPresented: Binding(
            get: { projectPendingDeletion != nil },
            set: { if !$0 { projectPendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { projectPendingDeletion = nil }
            Button("删除", role: .destructive) { deletePendingProject() }
        } message: {
            Text("删除“\(projectPendingDeletion?.name ?? "")”只会移除项目，不会删除或移动其中的文献。")
        }
        .alert("提示", isPresented: Binding(
            get: { presentedErrorText != nil },
            set: { showing in
                if !showing { dismissPresentedError() }
            }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(presentedErrorText ?? "")
        }
        .confirmationDialog(
            resumableStudyNotePendingCreation == nil ? "创建精读笔记" : "继续精读笔记",
            isPresented: Binding(
                get: { workIDPendingStudyNoteCreation != nil },
                set: { if !$0 { workIDPendingStudyNoteCreation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let work = workPendingStudyNoteCreation,
               let record = resumableStudyNotePendingCreation {
                Button("继续未完成的精读") {
                    resumeStudyNote(for: work, record: record)
                    workIDPendingStudyNoteCreation = nil
                }
            }
            Button("创建空白精读笔记") {
                if let work = workPendingStudyNoteCreation {
                    createBlankStudyNote(for: work)
                }
                workIDPendingStudyNoteCreation = nil
            }
            Button("使用人工智能生成") {
                if let work = workPendingStudyNoteCreation {
                    startStudyNote(for: work)
                }
                workIDPendingStudyNoteCreation = nil
            }
            Button("取消", role: .cancel) {
                workIDPendingStudyNoteCreation = nil
            }
        } message: {
            Text(
                resumableStudyNotePendingCreation == nil
                    ? "这篇文献还没有精读笔记。请选择创建方式。"
                    : "发现保存在论文文件夹中的未完成检查点，可以从下一部分继续。"
            )
        }
        .sheet(isPresented: $studyNoteCoordinator.isPresenting) {
            StudyNoteProgressView(coordinator: studyNoteCoordinator)
        }
        .sheet(item: $categoryPendingDeletion) { category in
            VStack(alignment: .leading, spacing: 18) {
                Text("删除分类 \(category.name)").font(.title2)
                Text("先选择其中所有文献的新分类。文件会安全移动后再删除分类。")
                    .foregroundStyle(.secondary)
                Picker("目标分类", selection: $replacementCategoryID) {
                    ForEach(categories.filter { $0.id != category.id }) { replacement in
                        Text(replacement.name).tag(Optional(replacement.id))
                    }
                }
                HStack {
                    Spacer()
                    Button("取消") { categoryPendingDeletion = nil }
                    Button("重新分配并删除", role: .destructive) {
                        confirmCategoryDeletion(category)
                    }
                    .disabled(replacementCategoryID == nil)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
        .sheet(isPresented: $showingBatchTagEditor) {
            batchTagEditor
        }
        .sheet(isPresented: $showingBatchPersonalMarkEditor) {
            batchPersonalMarkEditor
        }
        .sheet(item: $pendingBibTeXReview) { review in
            bibTeXReviewSheet(review)
        }
        .confirmationDialog(
            "批量导出 BibTeX",
            isPresented: $showingBatchBibTeXMode,
            titleVisibility: .visible
        ) {
            Button("使用资料库记录") { startBatchBibTeX(.local) }
            Button("在线核验") { startBatchBibTeX(.online) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将合并导出所选的 \(selectedWorkIDs.count) 篇文献。不合格的条目会被跳过并在完成摘要中列出。")
        }
        .sheet(isPresented: Binding(
            get: { pendingBatchBibTeXPreparation != nil },
            set: { if !$0 { pendingBatchBibTeXPreparation = nil } }
        )) {
            if let preparation = pendingBatchBibTeXPreparation {
                BatchBibTeXReviewSheet(
                    preparation: preparation,
                    onCancel: { pendingBatchBibTeXPreparation = nil },
                    onExport: { entries in
                        pendingBatchBibTeXPreparation = nil
                        Task { @MainActor in
                            await Task.yield()
                            saveBatchBibTeX(entries, preparation: preparation)
                        }
                    }
                )
            }
        }
        .sheet(item: $batchBibTeXSummary) { summary in
            BatchBibTeXSummarySheet(
                summary: summary,
                onClose: { batchBibTeXSummary = nil }
            )
        }
        .sheet(item: Binding(
            get: { importer.pendingReview },
            set: { value in
                if value == nil, importer.pendingReview != nil {
                    importer.resolvePendingReview(.cancel)
                }
            }
        )) { review in
            ImportDuplicateReviewSheet(
                review: review,
                onAddVersion: { versionType in
                    importer.resolvePendingReview(.addAsVersion(
                        workID: review.candidateWorkID,
                        versionType: versionType
                    ))
                },
                onImportSeparately: {
                    importer.resolvePendingReview(.importSeparately)
                },
                onCancel: {
                    importer.resolvePendingReview(.cancel)
                }
            )
        }
        .modifier(BatchConfirmationDialogs(
            selectedCount: selectedWorkIDs.count,
            showingReprocess: $showingBatchReprocessConfirmation,
            showingReview: $showingBatchReviewConfirmation,
            onReprocess: { startBatchAI(resetBeforeAnalysis: true) },
            onReview: markSelectedReviewed
        ))
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label("全部文献", systemImage: "books.vertical")
                    .badge(works.count)
                    .tag(SidebarSelection.all)
                Label("有问题", systemImage: "exclamationmark.triangle")
                    .badge(works.filter(hasIssue).count)
                    .tag(SidebarSelection.needsReview)
                Label("疑似重复", systemImage: "doc.on.doc")
                    .badge(works.filter { $0.duplicateCandidateWorkID != nil }.count)
                    .tag(SidebarSelection.possibleDuplicates)
                Label("处理队列", systemImage: "sparkles.rectangle.stack")
                    .badge(works.filter { AIAnalysisStateRules.isLatestStatus($0, oneOf: ["queued", "running"]) }.count)
                    .tag(SidebarSelection.aiQueue)
            }

            Section {
                ForEach(projects) { project in
                    Label(project.name, systemImage: "rectangle.stack")
                        .badge(project.works.count)
                        .tag(SidebarSelection.project(project.id))
                        .onDrop(of: [WorkRowDragProvider.typeIdentifier], isTargeted: nil) { providers in
                            acceptWorkDrop(providers, into: project)
                        }
                        .contextMenu {
                            Button("修改项目名称…") {
                                presentProjectRename(project)
                            }
                            Button("删除项目", role: .destructive) {
                                projectPendingDeletion = project
                            }
                        }
                }
            } header: {
                HStack {
                    Text("项目")
                    Spacer()
                    Button {
                        presentNewProject()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("新增项目")

                    Button {
                        projectPendingDeletion = selectedProject
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProject == nil)
                    .help("删除当前项目")

                    Button {
                        presentProjectRename(selectedProject)
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProject == nil)
                    .help("修改当前项目名称")
                }
            }

            Section {
                ForEach(categories) { category in
                    Label(category.name, systemImage: category.isSystemCategory ? "tray" : "folder")
                        .badge(category.works.count)
                        .tag(SidebarSelection.category(category.id))
                        .onDrop(of: [WorkRowDragProvider.typeIdentifier], isTargeted: nil) { providers in
                            acceptWorkDrop(providers, into: category)
                        }
                        .contextMenu {
                            if !category.isSystemCategory {
                                Button("删除分类", role: .destructive) {
                                    requestCategoryDeletion(category)
                                }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("分类")
                    Spacer()
                    Button {
                        newCategoryName = ""
                        showingNewCategory = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("新增主分类")

                    Button {
                        if let category = selectedEditableCategory {
                            requestCategoryDeletion(category)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedEditableCategory == nil)
                    .help("删除当前主分类")
                }
            }

            Section("智能列表") {
                Label("最近导入", systemImage: "clock")
                    .tag(SidebarSelection.recent)
                Label("多个版本", systemImage: "doc.on.doc")
                    .tag(SidebarSelection.multipleVersions)
                Label("缺少 DOI", systemImage: "link.badge.plus")
                    .tag(SidebarSelection.missingDOI)
                Label("尚未分析", systemImage: "sparkles")
                    .tag(SidebarSelection.unanalyzed)
            }

            Section("资料库") {
                if let rootURL = libraryAccess.rootURL {
                    Label(rootURL.lastPathComponent, systemImage: "externaldrive")
                        .help(rootURL.path)
                } else {
                    Button("选择资料库文件夹") {
                        libraryAccess.chooseLibraryFolder()
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230)
    }

    @ViewBuilder
    private var libraryList: some View {
        if libraryAccess.rootURL == nil {
            ContentUnavailableView {
                Label("尚未选择资料库", systemImage: "folder.badge.questionmark")
            } description: {
                Text("先选择一个文件夹，之后即可从 Finder 拖入 PDF。")
            } actions: {
                Button("选择文件夹") { libraryAccess.chooseLibraryFolder() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let displayedWorks = filteredWorks
            let projectPriorityValues = selectedProject?.priorityValues ?? [:]
            VStack(spacing: 0) {
                if !selectedTags.isEmpty {
                    activeTagFilterBar
                    Divider()
                }

                if searchMode == .smart,
                   searchCoordinator.isSmartMode,
                   !searchCoordinator.isSearching,
                   !effectiveSearchText.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(
                            "找到 \(searchCoordinator.smartMatches.count) 篇，显示上限 \(searchCoordinator.smartSearchResultLimit) 篇"
                        )
                        .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.07))
                    Divider()
                }

                if searchMode == .smart,
                   let notice = searchCoordinator.smartSearchNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text(notice)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.08))
                    Divider()
                }

                if displayedWorks.isEmpty {
                    ContentUnavailableView {
                        Label(works.isEmpty ? "拖入 PDF 开始" : "没有匹配的文献", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(works.isEmpty ? "源文件不会被修改或删除。" : "尝试更改分类、标签或搜索词。")
                    }
                } else {
                    List(displayedWorks) { work in
                        Button {
                            selectWork(work.id)
                        } label: {
                            WorkRow(
                                work: work,
                                isSelected: selectedWorkIDs.contains(work.id),
                                projectPriority: selectedProject.map { _ in
                                    ProjectWorkPriority(
                                        rawValue: projectPriorityValues[work.id.uuidString] ?? 0
                                    ) ?? .none
                                },
                                searchMatch: displayedSearchMatch(for: work)
                            )
                        }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("work-row-\(work.id.uuidString)")
                    .contextMenu {
                        Button("打开 PDF") { open(work) }
                        Button("在 Finder 中显示") { revealInFinder(work) }
                        Button {
                            copyAuthorYearReference(for: work)
                        } label: {
                            Label("复制作者与年份", systemImage: "doc.on.doc")
                        }
                        .disabled(authorYearReference(for: work) == nil)
                        Divider()
                        Menu("项目") {
                            if projects.isEmpty {
                                Button("新建项目…") {
                                    presentNewProject(adding: [work.id])
                                }
                            } else {
                                ForEach(projects) { project in
                                    let included = work.projects.contains { $0.id == project.id }
                                    Button {
                                        setWork(work, in: project, included: !included)
                                    } label: {
                                        Label(project.name, systemImage: included ? "checkmark" : "rectangle.stack")
                                    }
                                }
                            }
                        }
                        if let selectedProject {
                            Menu("优先级") {
                                ForEach(ProjectWorkPriority.menuOrder) { priority in
                                    Button {
                                        setPriority(priority, for: [work], in: selectedProject)
                                    } label: {
                                        Label(
                                            priority.title,
                                            systemImage: ProjectWorkPriority(
                                                rawValue: projectPriorityValues[work.id.uuidString] ?? 0
                                            ) == priority
                                                ? "checkmark"
                                                : "circle"
                                        )
                                    }
                                }
                            }
                        }
                        Button {
                            createOrOpenNote(for: work)
                        } label: {
                            Label("笔记", systemImage: "square.and.pencil")
                        }
                        Button {
                            openOrOfferStudyNote(for: work)
                        } label: {
                            Label("精读笔记", systemImage: "text.book.closed")
                        }
                        Button {
                            exportBibTeX(work)
                        } label: {
                            Label("导出 BibTeX…", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button("删除文章…", systemImage: "trash", role: .destructive) {
                            presentWorkDeletion([work])
                        }
                    }
                    .onDrag {
                        WorkRowDragProvider.make(
                            workID: work.id,
                            pdfURL: fileURL(for: work)
                        )
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var activeTagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("标签筛选", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(selectedTags) { tag in
                    Button {
                        selectedTagIDs.remove(tag.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tag.name).lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("移除标签筛选“\(tag.name)”")
                }

                Button("清空") {
                    selectedTagIDs.removeAll()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var tagFilterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按标签筛选")
                    .font(.headline)
                Spacer()
                if !selectedTagIDs.isEmpty || !selectedPersonalMarkIDs.isEmpty {
                    Button("清空") {
                        selectedTagIDs.removeAll()
                        selectedPersonalMarkIDs.removeAll()
                    }
                    .buttonStyle(.borderless)
                }
            }

            TextField("搜索标签", text: $tagFilterSearchText)
                .textFieldStyle(.roundedBorder)

            if !personalMarks.isEmpty {
                Text("个人标记").font(.subheadline.weight(.medium))
                ForEach(personalMarks) { mark in
                    Button {
                        if selectedPersonalMarkIDs.contains(mark.id) {
                            selectedPersonalMarkIDs.remove(mark.id)
                        } else {
                            selectedPersonalMarkIDs.insert(mark.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedPersonalMarkIDs.contains(mark.id)
                                ? "checkmark.circle.fill" : "circle")
                            Text(mark.name).foregroundStyle(Color(hex: mark.colorHex))
                            Spacer()
                            Text("\(mark.works.count)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }

            if tags.isEmpty {
                ContentUnavailableView("尚无标签", systemImage: "tag")
            } else if visibleTagFilterTags.isEmpty {
                ContentUnavailableView("没有匹配的标签", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleTagFilterTags) { tag in
                            Button {
                                toggleTagFilter(tag.id)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedTagIDs.contains(tag.id) ? Color.accentColor : Color.secondary)
                                    Text(tag.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(tag.works.count)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()
            Text(selectedTagIDs.isEmpty && selectedPersonalMarkIDs.isEmpty
                ? "未限制标签" : "显示包含任一已选标签或个人标记的文献")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360, height: 420)
    }

    private var batchTagEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量管理标签")
                    .font(.title2.weight(.semibold))
                Text(batchTagOperation == .add
                     ? "将标签添加到已选的 \(selectedWorkIDs.count) 篇文献，原有标签会保留。"
                     : "从已选的 \(selectedWorkIDs.count) 篇文献中移除标签，未使用的标签会自动清理。")
                    .foregroundStyle(.secondary)
            }

            Picker("操作", selection: $batchTagOperation) {
                ForEach(BatchTagOperation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: batchTagOperation) { _, _ in
                batchTagIDs.removeAll()
                batchNewTagName = ""
            }

            TextField("搜索已有标签", text: $batchTagSearchText)
                .textFieldStyle(.roundedBorder)

            GroupBox("已有标签") {
                if visibleBatchTags.isEmpty && batchTagSearchText.isEmpty {
                    ContentUnavailableView(
                        batchTagOperation == .add ? "尚无标签" : "所选文献尚无标签",
                        systemImage: "tag"
                    )
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else if visibleBatchTags.isEmpty {
                    ContentUnavailableView("没有匹配的标签", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(visibleBatchTags) { tag in
                                Button {
                                    toggleBatchTag(tag.id)
                                } label: {
                                    HStack {
                                        Image(systemName: batchTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(batchTagIDs.contains(tag.id) ? Color.accentColor : Color.secondary)
                                        Text(tag.name).lineLimit(1)
                                        Spacer()
                                        Text("\(tag.works.count)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 170, maxHeight: 260)
                }
            }

            if batchTagOperation == .add {
                TextField("同时新建一个标签（可选）", text: $batchNewTagName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    showingBatchTagEditor = false
                }
                Button(batchTagOperation == .add
                       ? "添加到 \(selectedWorkIDs.count) 篇文献"
                       : "从 \(selectedWorkIDs.count) 篇文献移除") {
                    applyBatchTags()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    batchTagIDs.isEmpty &&
                        (batchTagOperation == .remove ||
                         batchNewTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var inspector: some View {
        if let selectedWork, let rootURL = libraryAccess.rootURL {
            WorkInspector(
                work: selectedWork,
                categories: categories,
                availableTags: tags,
                availablePersonalMarks: personalMarks,
                rootURL: rootURL,
                studyNoteCoordinator: studyNoteCoordinator,
                onDelete: { presentWorkDeletion([$0]) }
            )
            .id(selectedWork.id)
        } else if selectedWorkIDs.count > 1 {
            ContentUnavailableView(
                "已选择 \(selectedWorkIDs.count) 篇文献",
                systemImage: "checklist"
            )
        } else {
            ContentUnavailableView("未选择文献", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var batchPersonalMarkEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量管理个人标记").font(.title3)
            Picker("操作", selection: $batchPersonalMarkOperation) {
                Text("添加").tag(BatchTagOperation.add)
                Text("移除").tag(BatchTagOperation.remove)
            }
            .pickerStyle(.segmented)
            let choices = batchPersonalMarkOperation == .add
                ? personalMarks
                : personalMarks.filter { mark in
                    selectedWorks.contains { work in
                        work.personalMarks.contains(where: { $0.id == mark.id })
                    }
                }
            if choices.isEmpty {
                Text("没有可用的个人标记，请先在设置中创建。").foregroundStyle(.secondary)
            } else {
                List(choices) { mark in
                    Button {
                        if batchPersonalMarkIDs.contains(mark.id) {
                            batchPersonalMarkIDs.remove(mark.id)
                        } else {
                            batchPersonalMarkIDs.insert(mark.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: batchPersonalMarkIDs.contains(mark.id)
                                ? "checkmark.circle.fill" : "circle")
                            Text(mark.name)
                            Spacer()
                            Circle()
                                .fill(Color(hex: mark.effectiveBackgroundColorHex))
                                .overlay(Circle().stroke(Color(hex: mark.colorHex), lineWidth: 1))
                                .frame(width: 12, height: 12)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showingBatchPersonalMarkEditor = false }
                Button(batchPersonalMarkOperation == .add ? "添加" : "移除") {
                    applyBatchPersonalMarks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(batchPersonalMarkIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func matchesSidebar(_ snapshot: LibraryWorkSnapshot) -> Bool {
        switch sidebarSelection ?? .all {
        case .all:
            return true
        case .needsReview:
            return snapshot.needsReview || snapshot.latestAnalysisStatus == "failed"
        case .possibleDuplicates:
            return snapshot.duplicateCandidateWorkID != nil
        case .aiQueue:
            return snapshot.latestAnalysisStatus.map { ["queued", "running"].contains($0) } ?? false
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            return snapshot.dateAdded >= cutoff
        case .multipleVersions:
            return snapshot.fileVersionCount > 1
        case .missingDOI:
            return snapshot.isMissingDOI
        case .unanalyzed:
            let status = snapshot.latestAnalysisStatus
            return status == nil || status == "cancelled"
        case let .category(id):
            return snapshot.primaryCategoryID == id
        case let .project(id):
            return snapshot.projectIDs.contains(id)
        }
    }

    private func matchesTagFilter(_ snapshot: LibraryWorkSnapshot) -> Bool {
        let noSelection = selectedTagIDs.isEmpty && selectedPersonalMarkIDs.isEmpty
        return noSelection ||
            !snapshot.tagIDs.isDisjoint(with: selectedTagIDs) ||
            !snapshot.personalMarkIDs.isDisjoint(with: selectedPersonalMarkIDs)
    }

    private func hasIssue(_ work: Work) -> Bool {
        let snapshot = listController.snapshot(for: work.id) ?? LibrarySearchRules.snapshot(for: work)
        return snapshot.needsReview || snapshot.latestAnalysisStatus == "failed"
    }

    private func toggleTagFilter(_ id: UUID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    private func toggleBatchTag(_ id: UUID) {
        if batchTagIDs.contains(id) {
            batchTagIDs.remove(id)
        } else {
            batchTagIDs.insert(id)
        }
    }

    private func selectWork(_ id: UUID) {
        let selection = WorkSelectionRules.selection(
            afterClicking: id,
            current: selectedWorkIDs,
            commandModified: NSEvent.modifierFlags.contains(.command)
        )
        selectedWorkIDs = selection

        guard selection.count == 1, let selectedID = selection.first else {
            inspectedWorkID = nil
            return
        }

        inspectedWorkID = selectedID
    }

    private func seedDefaultCategories() {
        guard categories.isEmpty else { return }
        let names = [
            "Uncategorized", "Labor", "Macro", "Public", "Development",
            "Econometrics", "Finance", "Trade", "IO", "Political Economy"
        ]
        for (index, name) in names.enumerated() {
            modelContext.insert(Category(
                name: name,
                sortOrder: index,
                isSystemCategory: name == "Uncategorized"
            ))
        }
        saveRootChanges("建立默认分类")
    }

    private func exportManifest(immediate: Bool = true) {
        guard let rootURL = libraryAccess.rootURL, let libraryID = libraryAccess.libraryID else { return }
        if immediate {
            Task {
                await manifestCoordinator.export(
                    libraryID: libraryID,
                    rootURL: rootURL,
                    works: works,
                    categories: categories,
                    tags: tags,
                    projects: projects,
                    personalMarks: personalMarks
                )
            }
        } else {
            manifestCoordinator.scheduleExport(
                libraryID: libraryID,
                rootURL: rootURL,
                works: works,
                categories: categories,
                tags: tags,
                projects: projects,
                personalMarks: personalMarks
            )
        }
    }

    private func synchronizeSelectionWithFilter() {
        let visibleIDs = Set(filteredWorks.map(\.id))
        selectedWorkIDs.formIntersection(visibleIDs)
        if let inspectedWorkID, !visibleIDs.contains(inspectedWorkID) {
            self.inspectedWorkID = nil
        }
    }

    private func restoreSidebarSelection() {
        guard !hasRestoredSidebarSelection else { return }
        hasRestoredSidebarSelection = true
        guard let restored = SidebarSelection.fromPersistenceValue(persistedSidebarSelection) else {
            sidebarSelection = .all
            persistedSidebarSelection = SidebarSelection.all.persistenceValue
            return
        }
        sidebarSelection = restored
        validateSidebarSelection()
    }

    private func validateSidebarSelection() {
        guard let selection = sidebarSelection else {
            sidebarSelection = .all
            return
        }
        switch selection {
        case let .category(id):
            if !categories.contains(where: { $0.id == id }) {
                sidebarSelection = .all
            }
        case let .project(id):
            if !projects.contains(where: { $0.id == id }) {
                sidebarSelection = .all
            }
        default:
            break
        }
    }

    private func synchronizeInspectorWithFilter() {
        guard let inspectedWorkID,
              !filteredWorks.contains(where: { $0.id == inspectedWorkID })
        else { return }
        self.inspectedWorkID = nil
    }

    private func dismissPresentedError() {
        if searchCoordinator.errorText != nil { searchCoordinator.dismissError(); return }
        if importer.errorText != nil { importer.errorText = nil; return }
        if importer.noticeText != nil { importer.noticeText = nil; return }
        if libraryAccess.accessError != nil { libraryAccess.dismissError(); return }
        if manifestCoordinator.errorText != nil { manifestCoordinator.errorText = nil; return }
        if batchArchiver.errorText != nil { batchArchiver.errorText = nil; return }
        if batchMetadataCoordinator.errorText != nil { batchMetadataCoordinator.errorText = nil; return }
        if batchAIAnalysisCoordinator.errorText != nil { batchAIAnalysisCoordinator.errorText = nil; return }
        if batchBibTeXCoordinator.errorText != nil { batchBibTeXCoordinator.errorText = nil; return }
        if reconciliationCoordinator.errorText != nil { reconciliationCoordinator.errorText = nil; return }
        if localError != nil { localError = nil; return }
        if databaseRecoveryNotice != nil {
            databaseRecoveryNotice = nil
            UserDefaults.standard.removeObject(forKey: "databaseRecoveryNotice")
        }
    }

    private func saveRootChanges(_ action: String) {
        do {
            try mutationStore.save(changes: .catalog, using: modelContext)
        } catch {
            localError = "\(action)失败：\(error.localizedDescription)"
        }
    }

    private func addCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !categories.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            localError = "已经存在同名分类。"
            return
        }
        modelContext.insert(Category(name: name, sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1))
        saveRootChanges("新增分类")
    }

    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !projects.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            localError = "已经存在同名项目。"
            return
        }
        let initialWorks = works.filter { workIDsForNewProject.contains($0.id) }
        let project = ReadingProject(name: name, works: initialWorks)
        modelContext.insert(project)
        saveRootChanges("新增项目")
        workIDsForNewProject.removeAll()
        sidebarSelection = .project(project.id)
    }

    private func presentNewProject(adding workIDs: Set<UUID> = []) {
        newProjectName = ""
        workIDsForNewProject = workIDs
        showingNewProject = true
    }

    private func presentProjectRename(_ project: ReadingProject?) {
        guard let project else { return }
        projectPendingRename = project
        renamedProjectName = project.name
    }

    private func cancelProjectRename() {
        projectPendingRename = nil
        renamedProjectName = ""
    }

    private func renamePendingProject() {
        guard let project = projectPendingRename else { return }
        let name = renamedProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            localError = "项目名称不能为空。"
            return
        }
        guard !projects.contains(where: {
            $0.id != project.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            localError = "已经存在同名项目。"
            return
        }
        guard project.name != name else {
            cancelProjectRename()
            return
        }

        project.name = name
        do {
            try modelContext.save()
            cancelProjectRename()
        } catch {
            modelContext.rollback()
            localError = "修改项目名称失败：\(error.localizedDescription)"
        }
    }

    private func deletePendingProject() {
        guard let project = projectPendingDeletion else { return }
        if sidebarSelection == .project(project.id) {
            sidebarSelection = .all
        }
        modelContext.delete(project)
        projectPendingDeletion = nil
        saveRootChanges("删除项目")
    }

    private func setWork(_ work: Work, in project: ReadingProject, included: Bool) {
        if included {
            if !work.projects.contains(where: { $0.id == project.id }) {
                work.projects.append(project)
            }
        } else {
            work.projects.removeAll { $0.id == project.id }
            project.setPriority(.none, for: work.id)
        }
        saveRootChanges(included ? "加入项目" : "移出项目")
        synchronizeSelectionWithFilter()
    }

    private func acceptWorkDrop(_ providers: [NSItemProvider], into project: ReadingProject) -> Bool {
        loadDraggedWork(from: providers) { work in
            setWork(work, in: project, included: true)
            batchActionStatus = "已将“\(work.title)”加入项目“\(project.name)”。"
        }
    }

    private func acceptWorkDrop(_ providers: [NSItemProvider], into category: Category) -> Bool {
        loadDraggedWork(from: providers) { work in
            guard let rootURL = libraryAccess.rootURL else {
                localError = "请先选择资料库文件夹。"
                return
            }
            guard work.primaryCategory?.id != category.id else { return }
            guard !batchArchiver.isWorking else {
                batchArchiver.errorText = "另一项文件移动尚未完成，请稍后重试。"
                return
            }
            batchActionStatus = "正在将“\(work.title)”移到分类“\(category.name)”。"
            // BatchArchiveCoordinator 经由 LibraryFileActor 迁移 PDF 和同名笔记文件。
            batchArchiver.reassign(
                works: [work],
                to: category,
                rootURL: rootURL,
                modelContext: modelContext
            ) { succeeded in
                batchActionStatus = succeeded
                    ? "已将“\(work.title)”移到分类“\(category.name)”。"
                    : nil
            }
        }
    }

    private func loadDraggedWork(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (Work) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(WorkRowDragProvider.typeIdentifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: WorkRowDragProvider.typeIdentifier) { data, error in
            guard error == nil,
                  let data,
                  let payload = try? JSONDecoder().decode(WorkRowDragPayload.self, from: data)
            else { return }
            Task { @MainActor in
                guard let work = works.first(where: { $0.id == payload.workID }) else { return }
                completion(work)
            }
        }
        return true
    }

    private func receiveExternalFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let externalProviders = LibraryFileDropRules.externalURLProviders(from: providers)
        guard !externalProviders.isEmpty else { return false }
        guard let rootURL = libraryAccess.rootURL else {
            importer.errorText = "请先选择资料库文件夹。"
            return false
        }

        let project = selectedProject
        Task { @MainActor in
            var urls: [URL] = []
            for provider in externalProviders {
                if let url = await provider.loadDroppedURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else {
                importer.errorText = "无法读取拖入的文件。"
                return
            }
            importer.importPDFs(
                urls,
                into: rootURL,
                addingTo: project,
                modelContext: modelContext
            )
        }
        return true
    }

    private func setSelectedWorks(in project: ReadingProject, included: Bool) {
        for work in selectedWorks {
            if included {
                if !work.projects.contains(where: { $0.id == project.id }) {
                    work.projects.append(project)
                }
            } else {
                work.projects.removeAll { $0.id == project.id }
                project.setPriority(.none, for: work.id)
            }
        }
        saveRootChanges(included ? "批量加入项目" : "批量移出项目")
        synchronizeSelectionWithFilter()
    }

    private func setPriority(
        _ priority: ProjectWorkPriority,
        for targetWorks: [Work],
        in project: ReadingProject
    ) {
        for work in targetWorks {
            if !work.projects.contains(where: { $0.id == project.id }) {
                work.projects.append(project)
            }
            project.setPriority(priority, for: work.id)
        }
        saveRootChanges("设置项目优先级")
    }

    private func requestCategoryDeletion(_ category: Category) {
        if category.works.isEmpty {
            if sidebarSelection == .category(category.id) {
                sidebarSelection = .all
            }
            modelContext.delete(category)
            saveRootChanges("删除分类")
            return
        }
        replacementCategoryID = categories.first(where: { $0.name == "Uncategorized" })?.id
        categoryPendingDeletion = category
    }

    private func confirmCategoryDeletion(_ category: Category) {
        guard let rootURL = libraryAccess.rootURL,
              let target = categories.first(where: { $0.id == replacementCategoryID })
        else { return }
        if sidebarSelection == .category(category.id) {
            sidebarSelection = .category(target.id)
        }
        batchArchiver.reassign(
            works: works.filter { $0.primaryCategory?.id == category.id },
            to: target,
            deleting: category,
            rootURL: rootURL,
            modelContext: modelContext
        )
        categoryPendingDeletion = nil
    }

    private func batchReassign(to category: Category) {
        guard let rootURL = libraryAccess.rootURL else { return }
        let selected = works.filter { selectedWorkIDs.contains($0.id) }
        batchArchiver.reassign(
            works: selected,
            to: category,
            rootURL: rootURL,
            modelContext: modelContext
        )
    }

    private func applyBatchTags() {
        do {
            let chosenTags = tags.filter { batchTagIDs.contains($0.id) }
            if batchTagOperation == .add {
                var tagsToAdd = chosenTags
                let newName = batchNewTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    let newTag = tags.first {
                        $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame
                    } ?? Tag(name: newName)
                    if newTag.modelContext == nil {
                        modelContext.insert(newTag)
                    }
                    if !tagsToAdd.contains(where: { $0.id == newTag.id }) {
                        tagsToAdd.append(newTag)
                    }
                }
                BatchTagRules.add(tagsToAdd, to: selectedWorks)
            } else {
                BatchTagRules.remove(chosenTags, from: selectedWorks)
                _ = try TagMaintenance.deleteOrphans(modelContext: modelContext)
            }
            try modelContext.save()
            batchActionStatus = batchTagOperation == .add
                ? "已为 \(selectedWorkIDs.count) 篇文献添加标签。"
                : "已从 \(selectedWorkIDs.count) 篇文献移除标签。"
        } catch {
            modelContext.rollback()
            localError = "批量修改标签失败：\(error.localizedDescription)"
            return
        }
        showingBatchTagEditor = false
        batchTagIDs.removeAll()
        batchNewTagName = ""
        batchTagSearchText = ""
    }

    private func applyBatchPersonalMarks() {
        let chosen = personalMarks.filter { batchPersonalMarkIDs.contains($0.id) }
        for work in selectedWorks {
            if batchPersonalMarkOperation == .add {
                for mark in chosen where !work.personalMarks.contains(where: { $0.id == mark.id }) {
                    work.personalMarks.append(mark)
                }
            } else {
                let ids = Set(chosen.map(\.id))
                work.personalMarks.removeAll { ids.contains($0.id) }
            }
        }
        do {
            try modelContext.save()
            batchActionStatus = batchPersonalMarkOperation == .add
                ? "已为 \(selectedWorks.count) 篇文献添加个人标记。"
                : "已从 \(selectedWorks.count) 篇文献移除个人标记。"
            showingBatchPersonalMarkEditor = false
            batchPersonalMarkIDs.removeAll()
        } catch {
            modelContext.rollback()
            localError = "批量修改个人标记失败：\(error.localizedDescription)"
        }
    }

    private func refreshSelectedMetadata() {
        batchActionStatus = nil
        batchMetadataCoordinator.refresh(works: selectedWorks, modelContext: modelContext)
    }

    private func startBatchAI(resetBeforeAnalysis: Bool) {
        guard let rootURL = libraryAccess.rootURL else {
            localError = "请先选择资料库文件夹。"
            return
        }
        batchActionStatus = nil
        batchAIAnalysisCoordinator.analyze(
            works: selectedWorks,
            categories: categories,
            rootURL: rootURL,
            resetBeforeAnalysis: resetBeforeAnalysis,
            modelContext: modelContext
        )
    }

    private func markSelectedReviewed() {
        let result = BatchReviewRules.markReviewed(selectedWorks)
        do {
            try modelContext.save()
            batchActionStatus = "已标记 \(result.marked) 篇，跳过 \(result.skipped) 篇仍需处理的文献。"
        } catch {
            modelContext.rollback()
            localError = "批量标记失败：\(error.localizedDescription)"
        }
    }

    private var deletionMessage: String {
        let folders = pendingWorkDeletion.compactMap(articleFolderDisplayName(for:)).joined(separator: "、")
        if hasSafeArticleFoldersForPendingDeletion, !folders.isEmpty {
            return "将删除 \(pendingWorkDeletion.count) 篇文章的应用记录。移到废纸篓会同时移走文章文件夹中的 PDF、笔记和其他文件：\(folders)。"
        }
        return "将删除 \(pendingWorkDeletion.count) 篇文章的应用记录。文件夹无法安全确认，文件会保留在资料库中。"
    }

    private var hasSafeArticleFoldersForPendingDeletion: Bool {
        !pendingWorkDeletion.isEmpty && pendingWorkDeletion.allSatisfy {
            !safeArticleFolders(for: $0).isEmpty
        }
    }

    private func presentWorkDeletion(_ targets: [Work]) {
        guard !isBatchWorking, !importer.isImporting, !reconciliationCoordinator.isChecking else {
            localError = "正在处理资料库，请稍后再删除文章。"
            return
        }
        pendingWorkDeletion = targets
        showingWorkDeletion = true
    }

    private func articleFolders(for work: Work) -> [URL] {
        guard let rootURL = libraryAccess.rootURL, !work.fileVersions.isEmpty else { return [] }
        var folders: [String: URL] = [:]
        for version in work.fileVersions {
            guard let fileURL = try? LibraryPathSafety.url(
                for: version.relativePath,
                inside: rootURL,
                requirePDF: true
            ) else { return [] }
            let folder = fileURL.deletingLastPathComponent().standardizedFileURL
            guard let relative = try? LibraryPathSafety.relativePath(of: folder, inside: rootURL),
                  relative.split(separator: "/").count >= 3,
                  !relative.hasPrefix(".paperlib/")
            else { return [] }
            folders[folder.path] = folder
        }
        return Array(folders.values)
    }

    private func articleFolderDisplayName(for work: Work) -> String? {
        let names = safeArticleFolders(for: work).map(\.lastPathComponent)
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func safeArticleFolders(for work: Work) -> [URL] {
        let folders = articleFolders(for: work)
        guard !folders.isEmpty, let rootURL = libraryAccess.rootURL else { return [] }
        let paths = Set(folders.map(\.path))
        for other in works where other.id != work.id {
            for version in other.fileVersions {
                guard let url = try? LibraryPathSafety.url(
                    for: version.relativePath,
                    inside: rootURL,
                    requirePDF: true
                ) else { continue }
                if paths.contains(url.deletingLastPathComponent().standardizedFileURL.path) {
                    return []
                }
            }
        }
        return folders
    }

    private func deletePendingWorks(moveFoldersToTrash: Bool) {
        let targets = pendingWorkDeletion
        pendingWorkDeletion = []
        var deleted = 0
        var deletedWorkIDs: Set<UUID> = []
        var failures: [String] = []
        for work in targets {
            var trashedFolders: [(trashURL: URL, originalURL: URL)] = []
            do {
                if moveFoldersToTrash {
                    for folder in safeArticleFolders(for: work)
                    where FileManager.default.fileExists(atPath: folder.path) {
                        var trashURL: NSURL?
                        try FileManager.default.trashItem(at: folder, resultingItemURL: &trashURL)
                        if let trashURL = trashURL as URL? {
                            trashedFolders.append((trashURL, folder))
                        }
                    }
                }
                for candidate in works where candidate.duplicateCandidateWorkID == work.id {
                    candidate.duplicateCandidateWorkID = nil
                }
                modelContext.delete(work)
                try modelContext.save()
                DeletedWorkRegistry.record(work.id)
                deletedWorkIDs.insert(work.id)
                deleted += 1
            } catch {
                modelContext.rollback()
                for moved in trashedFolders.reversed()
                where FileManager.default.fileExists(atPath: moved.trashURL.path) {
                    try? FileManager.default.moveItem(at: moved.trashURL, to: moved.originalURL)
                }
                failures.append("“\(work.title)”：\(error.localizedDescription)")
            }
        }
        selectedWorkIDs.subtract(targets.map(\.id))
        if let inspectedWorkID,
           targets.contains(where: { $0.id == inspectedWorkID }) {
            self.inspectedWorkID = nil
        }
        if deleted > 0 {
            batchActionStatus = "已删除 \(deleted) 篇文章。"
            exportManifest()
            Task {
                await searchCoordinator.removeDocuments(workIDs: deletedWorkIDs)
            }
        }
        if !failures.isEmpty {
            localError = failures.joined(separator: "\n")
        }
    }

    private func fileURL(for work: Work) -> URL? {
        guard
            let rootURL = libraryAccess.rootURL,
            let relativePath = work.preferredFileVersion?.relativePath
        else { return nil }
        return try? LibraryPathSafety.url(
            for: relativePath,
            inside: rootURL,
            requirePDF: true,
            requireExistingRegularFile: true
        )
    }

    private func open(_ work: Work) {
        guard let url = fileURL(for: work) else { return }
        ExternalPDFOpener.open(url) { error in
            if let error {
                localError = error
            } else {
                work.lastOpenedAt = .now
                saveRootChanges("记录打开时间")
            }
        }
    }

    private func revealInFinder(_ work: Work) {
        guard let url = fileURL(for: work) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func authorYearReference(for work: Work) -> String? {
        ArchiveRules.authorYearReference(
            authorsText: work.authorsText,
            publicationYear: work.publicationYear,
            authorLimit: authorYearReferenceAuthorLimit
        )
    }

    private func copyAuthorYearReference(for work: Work) {
        guard let reference = authorYearReference(for: work) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reference, forType: .string)
    }

    private func createOrOpenNote(for work: Work) {
        guard let rootURL = libraryAccess.rootURL,
              let path = work.preferredFileVersion?.relativePath
        else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                let result = try await LibraryFileActor().createLiteratureNote(
                    forPDFAt: path,
                    title: work.title,
                    in: rootURL
                )
                if NSWorkspace.shared.open(result.url) {
                    work.lastOpenedAt = .now
                    saveRootChanges("记录笔记打开时间")
                } else {
                    localError = "笔记已准备好，但系统找不到可打开 Markdown 文件的应用。"
                }
            } catch {
                localError = "创建笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private var workPendingStudyNoteCreation: Work? {
        guard let id = workIDPendingStudyNoteCreation else { return nil }
        return works.first { $0.id == id }
    }

    private var resumableStudyNotePendingCreation: StudyNoteGeneration? {
        guard let work = workPendingStudyNoteCreation,
              fileURL(for: work) != nil
        else { return nil }
        return work.studyNoteGenerations
            .filter(StudyNoteResumeRules.canResume)
            .max(by: { $0.createdAt < $1.createdAt })
    }

    private func openOrOfferStudyNote(for work: Work) {
        guard let rootURL = libraryAccess.rootURL,
              let path = work.preferredFileVersion?.relativePath
        else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                if let url = try await LibraryFileActor().existingLiteratureNote(
                    forPDFAt: path,
                    kind: .study,
                    in: rootURL
                ) {
                    if NSWorkspace.shared.open(url) {
                        work.lastOpenedAt = .now
                        saveRootChanges("记录精读笔记打开时间")
                    } else {
                        localError = "精读笔记存在，但系统找不到可打开 Markdown 文件的应用。"
                    }
                } else if studyNoteCoordinator.isGenerating {
                    studyNoteCoordinator.isPresenting = true
                } else {
                    workIDPendingStudyNoteCreation = work.id
                }
            } catch {
                localError = "打开精读笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private func createBlankStudyNote(for work: Work) {
        guard let rootURL = libraryAccess.rootURL,
              let path = work.preferredFileVersion?.relativePath
        else {
            localError = "这条文献没有可用的 PDF。"
            return
        }
        Task {
            do {
                let result = try await LibraryFileActor().createLiteratureNote(
                    forPDFAt: path,
                    title: work.title,
                    kind: .study,
                    in: rootURL
                )
                if NSWorkspace.shared.open(result.url) {
                    work.lastOpenedAt = .now
                    saveRootChanges("记录精读笔记打开时间")
                } else {
                    localError = "精读笔记已准备好，但系统找不到可打开 Markdown 文件的应用。"
                }
            } catch {
                localError = "创建精读笔记失败：\(error.localizedDescription)"
            }
        }
    }

    private func startStudyNote(for work: Work) {
        guard let url = fileURL(for: work) else {
            localError = "这条文献没有可用的主要 PDF。"
            return
        }
        studyNoteCoordinator.generate(work: work, pdfURL: url, modelContext: modelContext)
    }

    private func resumeStudyNote(for work: Work, record: StudyNoteGeneration) {
        guard let url = fileURL(for: work) else {
            localError = "这条文献没有可用的主要 PDF。"
            return
        }
        studyNoteCoordinator.resume(
            work: work,
            record: record,
            pdfURL: url,
            modelContext: modelContext
        )
    }

    private func exportBibTeX(_ work: Work) {
        guard !isFetchingBibTeX else {
            localError = "正在获取另一篇文献的在线书目信息，请稍候。"
            return
        }
        let snapshot = BibliographicSnapshot(
            title: work.title,
            authorsText: work.authorsText,
            publicationYear: work.publicationYear,
            doi: work.doi,
            journal: work.journal
        )
        let suggestedDirectory = fileURL(for: work)?.deletingLastPathComponent()
        let localEntry = try? BibTeXExporter.makeEntry(for: work)
        isFetchingBibTeX = true
        batchActionStatus = "正在获取在线 BibTeX：\(work.title)"
        Task {
            defer { isFetchingBibTeX = false }
            do {
                let contactEmail = UserDefaults.standard.string(forKey: "crossrefContactEmail")
                let online = try await BibTeXRemoteClient().fetch(
                    for: snapshot,
                    contactEmail: contactEmail
                )
                let differences = BibTeXComparisonRules.differences(
                    local: snapshot,
                    online: online.metadata
                )
                if differences.isEmpty {
                    saveBibTeX(online.entry, suggestedDirectory: suggestedDirectory)
                } else {
                    batchActionStatus = nil
                    pendingBibTeXReview = PendingBibTeXReview(
                        workTitle: work.title,
                        sourceName: online.sourceName,
                        differences: differences,
                        onlineEntry: online.entry,
                        localEntry: localEntry,
                        suggestedDirectory: suggestedDirectory
                    )
                }
            } catch {
                batchActionStatus = nil
                localError = "获取在线 BibTeX 失败：\(error.localizedDescription)"
            }
        }
    }

    private func saveBibTeX(_ entry: BibTeXEntry, suggestedDirectory: URL?) {
        let panel = NSSavePanel()
        panel.title = "导出 BibTeX"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.nameFieldStringValue = "\(entry.citationKey).bib"
        panel.directoryURL = suggestedDirectory
        guard panel.runModal() == .OK, let destination = panel.url else {
            batchActionStatus = nil
            return
        }
        do {
            try Data(entry.content.utf8).write(to: destination, options: .atomic)
            batchActionStatus = "已导出 \(destination.lastPathComponent)。"
        } catch {
            localError = "保存 BibTeX 失败：\(error.localizedDescription)"
        }
    }

    private func startBatchBibTeX(_ mode: BatchBibTeXExportMode) {
        let inputs = selectedWorks.map { work -> BatchBibTeXInput in
            let snapshot = BibliographicSnapshot(
                title: work.title,
                authorsText: work.authorsText,
                publicationYear: work.publicationYear,
                doi: work.doi,
                journal: work.journal
            )
            do {
                return BatchBibTeXInput(
                    id: work.id,
                    workTitle: work.title,
                    metadata: snapshot,
                    localEntry: try BibTeXExporter.makeEntry(for: work),
                    localFailureReason: nil
                )
            } catch {
                return BatchBibTeXInput(
                    id: work.id,
                    workTitle: work.title,
                    metadata: snapshot,
                    localEntry: nil,
                    localFailureReason: error.localizedDescription
                )
            }
        }
        guard !inputs.isEmpty else { return }

        switch mode {
        case .local:
            handleBatchBibTeXPreparation(BatchBibTeXExporter.prepareLocal(inputs))
        case .online:
            batchBibTeXCoordinator.startOnlinePreparation(
                inputs: inputs,
                contactEmail: crossrefEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : crossrefEmail
            ) { preparation in
                handleBatchBibTeXPreparation(preparation)
            }
        }
    }

    private func handleBatchBibTeXPreparation(_ preparation: BatchBibTeXPreparation) {
        guard !preparation.candidates.isEmpty else {
            batchBibTeXSummary = BatchBibTeXExportSummary(
                exportedCount: 0,
                fallbackCount: 0,
                skipped: preparation.skipped,
                filename: ""
            )
            return
        }
        if preparation.conflictCount > 0 {
            pendingBatchBibTeXPreparation = preparation
            return
        }
        let chosen = preparation.candidates.compactMap { candidate -> BatchBibTeXChosenEntry? in
            guard let entry = candidate.defaultEntry else { return nil }
            return BatchBibTeXChosenEntry(
                workID: candidate.id,
                workTitle: candidate.workTitle,
                entry: entry
            )
        }
        saveBatchBibTeX(chosen, preparation: preparation)
    }

    private func saveBatchBibTeX(
        _ entries: [BatchBibTeXChosenEntry],
        preparation: BatchBibTeXPreparation
    ) {
        guard !entries.isEmpty else {
            batchBibTeXSummary = BatchBibTeXExportSummary(
                exportedCount: 0,
                fallbackCount: preparation.fallbackCount,
                skipped: preparation.skipped,
                filename: ""
            )
            return
        }
        do {
            let content = try BatchBibTeXExporter.makeDocument(from: entries)
            guard !content.isEmpty else { return }
            let panel = NSSavePanel()
            panel.title = "批量导出 BibTeX"
            panel.prompt = "导出"
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
            panel.nameFieldStringValue = "references.bib"
            panel.directoryURL = libraryAccess.rootURL
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try Data(content.utf8).write(to: destination, options: .atomic)
            batchActionStatus = "已导出 \(entries.count) 篇文献到 \(destination.lastPathComponent)。"
            batchBibTeXSummary = BatchBibTeXExportSummary(
                exportedCount: entries.count,
                fallbackCount: preparation.fallbackCount,
                skipped: preparation.skipped,
                filename: destination.lastPathComponent
            )
        } catch {
            localError = "批量保存 BibTeX 失败：\(error.localizedDescription)"
        }
    }

    private func bibTeXReviewSheet(_ review: PendingBibTeXReview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("核验 BibTeX 信息").font(.title2)
            Text(review.workTitle).font(.headline).lineLimit(2)
            Text("在线来源：\(review.sourceName)。以下字段与资料库记录不一致，请选择导出依据。")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("字段").fontWeight(.semibold)
                    Text("资料库").fontWeight(.semibold)
                    Text("在线记录").fontWeight(.semibold)
                }
                Divider().gridCellColumns(3)
                ForEach(review.differences) { difference in
                    GridRow(alignment: .top) {
                        Text(difference.field).foregroundStyle(.secondary)
                        Text(difference.localValue).textSelection(.enabled)
                        Text(difference.onlineValue).textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button("取消") { pendingBibTeXReview = nil }
                Spacer()
                Button("使用资料库记录") {
                    guard let entry = review.localEntry else { return }
                    pendingBibTeXReview = nil
                    saveBibTeX(entry, suggestedDirectory: review.suggestedDirectory)
                }
                .disabled(review.localEntry == nil)
                .help(review.localEntry == nil ? "资料库记录尚未通过本地导出校验" : "")
                Button("使用在线记录") {
                    pendingBibTeXReview = nil
                    saveBibTeX(review.onlineEntry, suggestedDirectory: review.suggestedDirectory)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 320)
    }
}
