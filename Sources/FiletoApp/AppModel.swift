import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FiletoCore

@MainActor final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable { case files = "文件类型", applications = "应用" }
    enum Sheet: String, Identifiable { case chooser, details, preview, results, history, warnings; var id: String { rawValue } }
    @Published var mode: Mode = .files
    @Published var search = ""
    @Published var appSearch = ""
    @Published var associations: [Association] = [] { didSet { rebuildApplicationIndex() } }
    @Published var applications: [Application] = [] { didSet { rebuildApplicationIndex() } }
    @Published var selectedTypes = Set<String>() {
        didSet {
            if selectedTypes != oldValue {
                queryRevision += 1
                cancelChoice()
            }
        }
    }
    @Published var selectedApplication: String?
    @Published var applicationFilter = ""
    @Published var onlyUnresolved = false
    @Published var showCandidates = false
    @Published var ascending = true
    @Published var sortByApplication = false
    @Published var scanning = false { didSet { automaticRefresh.stateChanged() } }
    @Published var applying = false { didSet { automaticRefresh.stateChanged() } }
    @Published private(set) var refreshingAutomatically = false
    @Published var stopRequested = false
    @Published var scanMessage = ""
    @Published var warnings: [String] = []
    @Published var error: String?
    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let text: String
    }
    @Published var message: Message?
    func showMessage(title: String, systemImage: String, text: String) {
        message = Message(title: title, systemImage: systemImage, text: text)
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: "\(title)。\(text)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    @Published var records: [ChangeRecord] = []
    @Published var sheet: Sheet? {
        didSet {
            queryRevision += 1
            if sheet != .chooser { cancelChoice() }
            automaticRefresh.stateChanged()
        }
    }
    @Published private(set) var detailTypeID: String?
    @Published var choice: String = "" {
        didSet {
            if hasCompleteChoiceSnapshot { choiceError = nil }
            if choosingApplication && choice != oldValue {
                plan = []; skipped = []; queryRevision += 1
                if loadingChoices && hasCompleteChoiceSnapshot { loadingChoices = false; choiceQueryProgress = nil }
            }
        }
    }
    @Published var extraChoice: Application? { didSet { rebuildChoices() } }
    @Published var plan: [ChangeItem] = []
    @Published var skipped: [String] = []
    @Published var isRestore = false
    @Published var latestResults: [ChangeResult] = []
    @Published private(set) var choosingApplication = false
    @Published private(set) var loadingChoices = false
    @Published private(set) var changeRows: [Association] = [] { didSet { rebuildChoiceIndex() } }
    struct ChoiceQueryProgress: Equatable {
        var completed: Int
        var total: Int
        var preparingPreview = false
    }
    @Published private(set) var choiceQueryProgress: ChoiceQueryProgress?
    @Published private(set) var choiceError: String?
    @Published private(set) var queryErrors: [String: String] = [:]
    @Published private(set) var executionStage: AssociationManager.ExecutionStage?
    @Published private(set) var executingItem: ChangeItem?
    @Published private(set) var resultSkipped: [String] = []
    @Published private(set) var resultsAreRestore = false
    @Published var inspection: FileInspection?
    @Published private(set) var inspectionWarning: String?
    @Published var lastRefreshed: Date?
    private let workspace: any WorkspaceAccess
    private let discover: @Sendable () -> CatalogSnapshot
    private let inspect: @MainActor (URL) throws -> FileInspection
    private let observesSystemLifecycle: Bool
    private lazy var manager = AssociationManager(workspace: workspace)
    private let history: HistoryStore
    private var manualTypes: [FileType] = []
    private var loaded = false
    private var applicationIndex: [Application] = []
    private var defaultCounts: [String: Int] = [:]
    private var choiceApplications: [Application] = []
    private var candidateApplications: [String: Application] = [:]
    private var choiceCoverage: [String: Int] = [:]
    private var choiceCurrentCounts: [String: Int] = [:]
    private var supportedCurrentCounts: [String: Int] = [:]
    private var choiceNameCounts: [String: Int] = [:]
    private var changeTypeIDs = Set<String>()
    private var dismissal: CheckedContinuation<Void, Never>?
    private var sheetIsVisible = false
    private var panelIsVisible = false
    private var queryRevision = 0
    private var catalogWarnings: [String] = []
    private var associationWarnings: [String: String] = [:]
    lazy var automaticRefresh = AutomaticRefresh(delay: automaticRefreshDelay, interval: automaticRefreshInterval,
        canRefresh: { [weak self] in
            guard let self else { return false }
            return self.loaded && !self.scanning && !self.applying && !self.choosingApplication && self.sheet == nil
                && !self.sheetIsVisible && !self.panelIsVisible
        }, refresh: { [weak self] scope in
            guard let self else { return false }
            return await self.querySnapshot(scope, automatic: true)
        })
    private let automaticRefreshDelay: UInt64
    private let automaticRefreshInterval: TimeInterval

    func didPresentSheet() { sheetIsVisible = true; automaticRefresh.stateChanged() }
    func didDismissSheet() {
        sheetIsVisible = false; dismissal?.resume(); dismissal = nil
        automaticRefresh.stateChanged()
    }

    var showingHistory: Bool { get { sheet == .history } set { setSheet(.history, visible: newValue) } }
    var showingWarnings: Bool { get { sheet == .warnings } set { setSheet(.warnings, visible: newValue) } }
    var showingPreview: Bool { get { sheet == .preview } set { setSheet(.preview, visible: newValue) } }
    var showingResults: Bool { get { sheet == .results } set { setSheet(.results, visible: newValue) } }
    private func setSheet(_ value: Sheet, visible: Bool) {
        if visible { sheet = value }
        else if sheet == value { sheet = nil }
    }

    init(history: HistoryStore = HistoryStore(), workspace: (any WorkspaceAccess)? = nil,
         discover: @escaping @Sendable () -> CatalogSnapshot = { TypeCatalog.discover() },
         inspect: (@MainActor (URL) throws -> FileInspection)? = nil,
         observesSystemLifecycle: Bool = true, automaticRefreshDelay: UInt64 = 1_000_000_000,
         automaticRefreshInterval: TimeInterval = 30) {
        self.history = history; self.workspace = workspace ?? SystemWorkspace(); self.discover = discover
        self.inspect = inspect ?? { try SystemWorkspace().inspect($0) }
        self.observesSystemLifecycle = observesSystemLifecycle
        self.automaticRefreshDelay = automaticRefreshDelay; self.automaticRefreshInterval = automaticRefreshInterval
    }
    func switchMode(_ mode: Mode) { self.mode = mode; selectedTypes = []; applicationFilter = "" }
    func selectApplication(_ id: String?) { selectedApplication = id; selectedTypes = [] }
    func ambiguousTypes(for type: FileType) -> [FileType] {
        associations.map(\.type).filter { $0.id != type.id && !Set($0.extensions).isDisjoint(with: type.extensions) }
    }

    var visibleRows: [Association] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return associations.filter { row in
            if onlyUnresolved && row.application != nil && !row.type.isDynamic { return false }
            if !applicationFilter.isEmpty && row.application?.id != applicationFilter { return false }
            if mode == .applications {
                guard let selectedApplication else { return false }
                if showCandidates {
                    guard row.candidates.contains(where: { $0.id == selectedApplication }) else { return false }
                } else if row.application?.id != selectedApplication { return false }
            }
            return query.isEmpty || [row.type.extensionLabel, row.type.name, row.application?.name ?? "", row.type.id]
                .contains { $0.lowercased().contains(query) }
        }.sorted {
            let lhs = sortByApplication ? ($0.application?.name ?? "") + $0.type.extensionLabel : $0.type.extensionLabel
            let rhs = sortByApplication ? ($1.application?.name ?? "") + $1.type.extensionLabel : $1.type.extensionLabel
            let comparison = lhs.localizedStandardCompare(rhs)
            if comparison == .orderedSame { return ascending ? $0.id < $1.id : $0.id > $1.id }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    var chosenRows: [Association] { visibleRows.filter { selectedTypes.contains($0.id) } }
    var focusedRow: Association? { chosenRows.count == 1 ? chosenRows.first : nil }
    var detailRow: Association? { associations.first { $0.id == detailTypeID } }
    func showDetails(for id: String) {
        guard !applying && !scanning && !choosingApplication && sheet == nil,
              associations.contains(where: { $0.id == id }) else { return }
        detailTypeID = id
        sheet = .details
    }
    var indexedApplications: [Application] {
        applicationIndex
    }
    private func rebuildApplicationIndex() {
        var indexed = Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var counts: [String: Int] = [:]
        for row in associations {
            if let app = row.application { indexed[app.id] = app; counts[app.id, default: 0] += 1 }
            for app in row.candidates { indexed[app.id] = app }
        }
        applicationIndex = indexed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaultCounts = counts
    }
    private func rebuildChoiceIndex() {
        candidateApplications = [:]; choiceCoverage = [:]; choiceCurrentCounts = [:]; supportedCurrentCounts = [:]
        changeTypeIDs = Set(changeRows.map(\.id))
        for row in changeRows {
            if let current = row.application { choiceCurrentCounts[current.id, default: 0] += 1 }
            var seen = Set<String>()
            for app in row.candidates where seen.insert(app.id).inserted {
                if candidateApplications[app.id] == nil { candidateApplications[app.id] = app }
                choiceCoverage[app.id, default: 0] += 1
                if row.application?.id == app.id { supportedCurrentCounts[app.id, default: 0] += 1 }
            }
        }
        rebuildChoices()
    }
    private func rebuildChoices() {
        var indexed = candidateApplications
        if let extraChoice { indexed[extraChoice.id] = extraChoice }
        choiceApplications = indexed.values.sorted {
            let lc = coverage($0), rc = coverage($1)
            return lc == rc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lc > rc
        }
        choiceNameCounts = [:]
        for app in choiceApplications { choiceNameCounts[app.name, default: 0] += 1 }
    }
    var choices: [Application] { choiceApplications }
    var systemChoiceCount: Int { candidateApplications.count }
    var hasCompleteChoiceSnapshot: Bool { changeTypeIDs == selectedTypes }
    func hasDuplicateChoiceName(_ application: Application) -> Bool { choiceNameCounts[application.name, default: 0] > 1 }
    func coverage(_ application: Application) -> Int {
        choiceCoverage[application.id, default: 0]
    }
    func currentCount(_ application: Application) -> Int {
        choiceCurrentCounts[application.id, default: 0]
    }
    struct ChoiceSummary: Equatable {
        var changes = 0
        var unchanged = 0
        var unsupported = 0
    }
    var choiceSummary: ChoiceSummary? {
        guard choosingApplication, !loadingChoices, hasCompleteChoiceSnapshot,
              let target = choices.first(where: { $0.id == choice }) else { return nil }
        let supported = coverage(target)
        let unchanged = supportedCurrentCounts[target.id, default: 0]
        return ChoiceSummary(changes: supported - unchanged, unchanged: unchanged, unsupported: changeRows.count - supported)
    }
    var choiceTarget: Application? { choices.first { $0.id == choice } }
    var choiceHasAmbiguousTypes: Bool {
        var owners: [String: Set<String>] = [:]
        for row in associations {
            for ext in row.type.extensions { owners[ext, default: []].insert(row.id) }
        }
        return changeRows.contains { row in row.type.extensions.contains { owners[$0, default: []].count > 1 } }
    }
    var canContinue: Bool {
        guard choosingApplication, !loadingChoices, !applying, !scanning,
              let summary = choiceSummary else { return false }
        return summary.changes > 0
    }
    var selectedResults: [ChangeResult] {
        latestResults.filter { selectedTypes.contains($0.item.id) }
    }
    func count(for application: Application) -> Int {
        defaultCounts[application.id, default: 0]
    }
    func start() async {
        guard !loaded else { return }; loaded = true
        do { records = try history.load() } catch { self.error = "无法读取操作记录：\(error.localizedDescription)" }
        await refresh()
        if observesSystemLifecycle { automaticRefresh.start() }
    }
    func refresh() async {
        guard !scanning && !applying else { return }
        cancelChoice()
        scanning = true; scanMessage = "正在发现应用和文件类型…"
        await automaticRefresh.suspend()
        _ = await querySnapshot(.catalog, automatic: false)
        scanning = false; scanMessage = ""
    }
    private func querySnapshot(_ scope: AutomaticRefresh.Scope, automatic: Bool) async -> Bool {
        if automatic { refreshingAutomatically = true }
        defer { if automatic { refreshingAutomatically = false } }
        let revision = queryRevision
        func mayCommit() -> Bool {
            !automatic || (!Task.isCancelled && automaticRefresh.canRun && queryRevision == revision)
        }
        var types = associations.map(\.type)
        var discoveredApplications = applications
        var discoveryWarnings = catalogWarnings
        if scope == .catalog {
            let discover = self.discover
            let snapshot = await Task.detached(priority: .userInitiated) { discover() }.value
            guard mayCommit() else { return false }
            discoveredApplications = snapshot.applications; discoveryWarnings = snapshot.warnings
            // An unreadable application directory is not evidence that its types vanished.
            types = TypeCatalog.merge(snapshot.types + manualTypes + (snapshot.warnings.isEmpty ? [] : types))
        }
        let previous = Dictionary(associations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Association] = []
        var queryWarnings: [String: String] = [:]
        var failures: [String: String] = [:]
        for (index, type) in types.enumerated() {
            guard mayCommit() else { return false }
            do { rows.append(try manager.query(type)) }
            catch {
                if let old = previous[type.id] { rows.append(old) }
                failures[type.id] = "本次查询失败，显示上次查询结果。请刷新重试。"
                queryWarnings[type.id] = "\(type.extensionLabel)：本次查询失败，已有结果保留。\(error.localizedDescription)"
            }
            if index % 20 == 0 {
                if !automatic { scanMessage = "正在查询默认应用 · \(index + 1) / \(types.count)" }
                await Task.yield()
            }
        }
        guard mayCommit() else { return false }
        var refreshedInspection = inspection
        var fileWarning: String?
        if let inspection {
            let scoped = inspection.url.startAccessingSecurityScopedResource()
            defer { if scoped { inspection.url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try inspect(inspection.url)
                let row = try manager.query(result.type)
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
                else { rows.append(row) }
                refreshedInspection = result
            } catch { fileWarning = "无法更新这个文件的打开方式，显示上次查询结果：\(error.localizedDescription)" }
        }
        guard mayCommit() else { return false }
        if discoveredApplications != applications { applications = discoveredApplications }
        if rows != associations { associations = rows }
        catalogWarnings = discoveryWarnings
        associationWarnings = queryWarnings
        rebuildWarnings()
        queryErrors = failures
        if let refreshedInspection {
            if refreshedInspection.type.id != inspection?.type.id, let oldID = inspection?.type.id,
               selectedTypes.remove(oldID) != nil { selectedTypes.insert(refreshedInspection.type.id) }
            manualTypes = TypeCatalog.merge(manualTypes + [refreshedInspection.type])
        }
        inspection = refreshedInspection; inspectionWarning = fileWarning
        selectedTypes.formIntersection(Set(rows.map(\.id)))
        let availableIDs = Set(indexedApplications.map(\.id))
        if let selectedApplication, !availableIDs.contains(selectedApplication) { self.selectedApplication = nil }
        if !applicationFilter.isEmpty && !availableIDs.contains(applicationFilter) { applicationFilter = "" }
        lastRefreshed = Date()
        return true
    }
    func lookupExtension(_ input: String) {
        guard !applying && !scanning else { return }
        cancelChoice()
        queryRevision += 1
        do {
            let types = try TypeCatalog.lookup(input)
            manualTypes = TypeCatalog.merge(manualTypes + types)
            for type in types { upsert(try manager.query(type)) }
            mode = .files; applicationFilter = ""; onlyUnresolved = false
            search = try TypeCatalog.normalizedExtension(input)
            selectedTypes = Set(types.map(\.id))
            inspection = nil; inspectionWarning = nil
        } catch { self.error = error.localizedDescription }
    }
    func inspectFile(_ url: URL) {
        guard !applying && !scanning else { return }
        cancelChoice()
        queryRevision += 1
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try inspect(url)
            manualTypes = TypeCatalog.merge(manualTypes + [result.type])
            upsert(try manager.query(result.type))
            mode = .files; search = ""; applicationFilter = ""; onlyUnresolved = false
            selectedTypes = [result.type.id]; inspection = result; inspectionWarning = nil
            showDetails(for: result.type.id)
        } catch { self.error = error.localizedDescription }
    }
    func openFile() {
        guard !applying && !scanning else { return }
        cancelChoice()
        panelIsVisible = true; queryRevision += 1; automaticRefresh.stateChanged()
        defer { panelIsVisible = false; automaticRefresh.stateChanged() }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "查询打开方式"
        if panel.runModal() == .OK, let url = panel.url { inspectFile(url) }
    }
    func browseApplication() {
        guard choosingApplication && !loadingChoices && !applying && !scanning else { return }
        panelIsVisible = true; queryRevision += 1; automaticRefresh.stateChanged()
        defer { panelIsVisible = false; automaticRefresh.stateChanged() }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "选择应用"
        if panel.runModal() == .OK, let url = panel.url {
            guard let app = Application.read(at: url) else { choiceError = FiletoError.unavailableApplication.localizedDescription; return }
            extraChoice = app; choice = app.id
            choiceError = coverage(app) == 0 ? "系统未将此应用列为所选类型的候选应用，请选择其他应用。" : nil
        }
    }
    func beginChange(presentsChooser: Bool = true) async {
        guard !applying && !scanning && sheet == nil && !choosingApplication else { return }
        let selected = chosenRows
        guard !selected.isEmpty else { return }
        selectedTypes = Set(selected.map(\.id))
        if presentsChooser { sheet = .chooser }
        queryRevision += 1
        let revision = queryRevision
        defer { if Task.isCancelled && queryRevision == revision { cancelChoice() } }
        choice = ""; extraChoice = nil; skipped = []; plan = []; isRestore = false; choiceError = nil
        changeRows = []; loadingChoices = true
        choiceQueryProgress = ChoiceQueryProgress(completed: 0, total: selected.count)
        choosingApplication = true; automaticRefresh.stateChanged()
        await automaticRefresh.suspend()
        func isCurrent() -> Bool { choosingApplication && queryRevision == revision && !Task.isCancelled }
        var freshRows: [Association] = []
        var failures: [String: String] = [:]
        for (index, row) in selected.enumerated() {
            guard isCurrent() else { return }
            do { freshRows.append(try manager.query(row.type)) }
            catch { failures[row.id] = "无法查询这个类型的当前关联，请刷新后重试。" }
            if (index + 1) % 20 == 0 || index + 1 == selected.count {
                guard isCurrent() else { return }
                choiceQueryProgress = ChoiceQueryProgress(completed: index + 1, total: selected.count)
                await Task.yield()
            }
        }
        guard isCurrent() else { return }
        upsert(freshRows)
        queryErrors.merge(failures) { _, new in new }
        changeRows = freshRows; loadingChoices = false; choiceQueryProgress = nil
        if changeRows.count != selected.count {
            choiceError = "部分类型查询失败。本次不会继续修改，请取消后刷新重试。"
        }
    }
    // A row menu always targets exactly one UTI, even when the table has a batch selection.
    func changeDefault(for id: String, to target: Application? = nil, from displayedRow: Association? = nil) async {
        guard !Task.isCancelled && !applying && !scanning && !choosingApplication && sheet == nil,
              let currentRow = visibleRows.first(where: { $0.id == id }),
              displayedRow == nil || displayedRow?.id == id else { return }
        let row = displayedRow ?? currentRow
        selectedTypes = [id]
        if let target {
            do {
                // Keep the displayed default as the before snapshot. apply checks the
                // current default and candidate range before any system write.
                let item = try manager.preview(association: row, target: target)
                plan = [item]; skipped = []; isRestore = false
                await executePlan([item], restoring: false, compactResult: true)
            } catch {
                self.error = "无法准备修改：\(error.localizedDescription) 请刷新后重新选择应用。"
            }
            return
        }
        await beginChange(presentsChooser: false)
        guard choosingApplication, selectedTypes == [id] else { return }
        browseApplication()
        if extraChoice == nil && choiceError == nil { cancelChoice(); return }
        if choosingApplication { sheet = .chooser }
    }
    func cancelChoice() {
        guard choosingApplication else { return }
        choosingApplication = false; loadingChoices = false; choice = ""; extraChoice = nil; choiceError = nil
        if !applying { plan = []; skipped = [] }
        choiceQueryProgress = nil
        if sheet == .chooser { sheet = nil }
        queryRevision += 1; automaticRefresh.stateChanged()
    }
    func prepareChange() async {
        guard canContinue, let target = choices.first(where: { $0.id == choice }) else { return }
        let revision = queryRevision
        let rows = changeRows
        loadingChoices = true
        choiceQueryProgress = ChoiceQueryProgress(completed: 0, total: rows.count, preparingPreview: true)
        defer {
            if choosingApplication && queryRevision == revision { loadingChoices = false; choiceQueryProgress = nil }
        }
        func isCurrent() -> Bool { choosingApplication && queryRevision == revision && !Task.isCancelled }
        do {
            var items: [ChangeItem] = []
            var unsupported: [String] = []
            for (index, row) in rows.enumerated() {
                guard isCurrent() else { return }
                // The chooser is the preview. Preserve the values the user saw;
                // apply re-queries and rejects later changes before any write.
                if row.candidates.contains(where: { $0.id == target.id }) {
                    items.append(try manager.preview(association: row, target: target))
                } else { unsupported.append("\(row.type.name)（\(row.type.extensionLabel)）") }
                if (index + 1) % 20 == 0 || index + 1 == rows.count {
                    guard isCurrent() else { return }
                    choiceQueryProgress = ChoiceQueryProgress(completed: index + 1, total: rows.count, preparingPreview: true)
                    await Task.yield()
                }
            }
            guard isCurrent() else { return }
            guard !items.isEmpty else { throw FiletoError.unsupportedApplication("选中的文件类型") }
            plan = items; skipped = unsupported
        } catch {
            guard isCurrent() else { return }
            choiceError = "无法准备修改：\(error.localizedDescription) 请取消后刷新，或重新选择应用。"
        }
    }
    func submitChange() async {
        guard sheet == .chooser else { return }
        await prepareChange()
        await execute()
    }
    func prepareRestore(_ record: ChangeRecord) {
        guard !applying && !scanning else { return }
        do {
            plan = try manager.restorePreview(record); isRestore = true
            let ids = Set(plan.map(\.id))
            skipped = record.results.filter { !ids.contains($0.item.id) }.map { "\($0.item.type.name)（\($0.item.type.extensionLabel)）" }
            showingHistory = false; showingPreview = true
        } catch { self.error = error.localizedDescription }
    }
    func retry(_ results: [ChangeResult], restoring: Bool = false) {
        guard !applying && !scanning else { return }
        do {
            let retryable = results.filter { $0.outcome == .failed }
            plan = try retryable.flatMap { try manager.preview(types: [$0.item.type], target: $0.item.target) }
            guard !plan.isEmpty else { return }
            skipped = []; isRestore = restoring; showingResults = false; showingPreview = true
        } catch { self.error = error.localizedDescription }
    }
    func execute() async {
        let preparedChoice = choiceTarget.map { target in
            sheet == .chooser && canContinue && plan.count == coverage(target)
                && plan.allSatisfy { $0.target.id == choice && changeTypeIDs.contains($0.id) }
        } ?? false
        guard !Task.isCancelled && !applying && !plan.isEmpty && (sheet == .preview || preparedChoice) else { return }
        await executePlan(plan, restoring: isRestore, compactResult: preparedChoice && selectedTypes.count == 1)
    }
    private func executePlan(_ executingPlan: [ChangeItem], restoring: Bool, compactResult: Bool) async {
        applying = true; stopRequested = false; message = nil
        latestResults = []; resultSkipped = skipped; resultsAreRestore = restoring
        await automaticRefresh.suspend()
        if sheetIsVisible {
            // NSWorkspace may present its own confirmation. Give it a stable
            // main window after the chooser or preview's native sheet has closed.
            await withCheckedContinuation { continuation in
                dismissal = continuation; sheet = nil
            }
        } else {
            sheet = nil
            await Task.yield()
        }
        var queriedRows: [String: Association] = [:]
        var failedQueries: [String: FileType] = [:]
        let results = await manager.apply(executingPlan, shouldStop: { self.stopRequested }, onStage: { item, stage in
            self.executingItem = item; self.executionStage = stage
        }, onQuery: { type, query in
            switch query {
            case .success(let row): queriedRows[type.id] = row; failedQueries[type.id] = nil
            case .failure: failedQueries[type.id] = type
            }
        }, onResult: { result in
            self.latestResults.append(result)
        })
        executingItem = nil; executionStage = nil
        // Commit only the types queried by this operation, once. No catalog scan
        // or second readback stands between the verified result and its feedback.
        upsert(executingPlan.compactMap { queriedRows[$0.id] })
        for (id, type) in failedQueries {
            let message = "本次查询失败，显示上次查询结果。请刷新重试。"
            queryErrors[id] = message
            associationWarnings[id] = "\(type.extensionLabel)：\(message)"
        }
        rebuildWarnings()
        updateInspection(afterQuerying: Set(queriedRows.keys).union(failedQueries.keys), failedQueries: Set(failedQueries.keys))
        let record = ChangeRecord(isRestore: restoring, results: results)
        records.insert(record, at: 0); records = Array(records.prefix(30))
        var historySaved = true
        do { try history.save(records) } catch {
            historySaved = false
            self.error = "修改结果仍可查看，但操作记录保存失败：\(error.localizedDescription)"
        }
        applying = false
        if compactResult && historySaved, results.count == 1, let result = results.first,
           result.outcome == .changed || result.outcome == .alreadyDefault {
            showMessage(title: result.outcome == .changed ? "已修改并验证" : "已是目标应用，无需修改",
                        systemImage: "checkmark.circle",
                        text: "\(result.item.type.extensionLabel.isEmpty ? result.item.type.name : result.item.type.extensionLabel) → \(result.item.target.name)。可在操作记录中查看详情。")
        } else {
            showingResults = true
        }
    }
    private func rebuildWarnings() {
        warnings = catalogWarnings + associationWarnings.keys.sorted().compactMap { associationWarnings[$0] }
    }
    private func updateInspection(afterQuerying ids: Set<String>, failedQueries: Set<String>) {
        guard let previous = inspection, ids.contains(previous.type.id) else { return }
        guard !failedQueries.contains(previous.type.id) else {
            inspectionWarning = "无法更新这个文件的打开方式，显示上次查询结果。请刷新核对。"
            return
        }
        let scoped = previous.url.startAccessingSecurityScopedResource()
        defer { if scoped { previous.url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try inspect(previous.url)
            if result.type.id != previous.type.id {
                upsert(try manager.query(result.type))
                manualTypes = TypeCatalog.merge(manualTypes + [result.type])
                if selectedTypes.remove(previous.type.id) != nil { selectedTypes.insert(result.type.id) }
            }
            inspection = result; inspectionWarning = nil
        } catch {
            inspectionWarning = "无法更新这个文件的打开方式，显示上次查询结果：\(error.localizedDescription)"
        }
    }
    private func upsert(_ row: Association) {
        queryErrors[row.id] = nil
        associationWarnings[row.id] = nil
        rebuildWarnings()
        if let index = associations.firstIndex(where: { $0.id == row.id }) { associations[index] = row }
        else { associations.append(row) }
    }
    private func upsert(_ rows: [Association]) {
        var merged = associations
        var indices = Dictionary(merged.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var failures = queryErrors
        for row in rows {
            failures[row.id] = nil
            associationWarnings[row.id] = nil
            if let index = indices[row.id] { merged[index] = row }
            else { indices[row.id] = merged.count; merged.append(row) }
        }
        if merged != associations { associations = merged }
        if failures != queryErrors { queryErrors = failures }
        rebuildWarnings()
    }
    func mainWindowClosed() {
        cancelChoice()
        if applying { stopRequested = true }
        // Closing a window can also dismiss its native preview sheet.
        didDismissSheet()
        sheet = nil
    }
}
