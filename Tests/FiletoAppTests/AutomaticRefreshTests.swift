import XCTest
import Combine
@testable import FiletoCore
@testable import FiletoApp

@MainActor private final class FakeWorkspace: WorkspaceAccess {
    var rows: [String: Association] = [:]
    var failures = Set<String>()
    var writes: [String] = []
    var onQuery: ((FileType) -> Void)?
    func association(for type: FileType) throws -> Association {
        onQuery?(type)
        guard !failures.contains(type.id), let row = rows[type.id] else {
            throw FiletoError.unknownType(type.id)
        }
        return row
    }
    func setDefault(_ application: Application, for type: FileType) async throws {
        writes.append(type.id); rows[type.id]?.application = application
    }
}

// Discovery runs on the same detached task used in production.
private final class CatalogSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CatalogSnapshot
    private var count = 0
    init(_ value: CatalogSnapshot) { self.value = value }
    func discover() -> CatalogSnapshot {
        lock.lock(); defer { lock.unlock() }; count += 1; return value
    }
    func replace(_ value: CatalogSnapshot) { lock.lock(); defer { lock.unlock() }; self.value = value }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor final class AutomaticRefreshTests: XCTestCase {
    private let first = Application(url: URL(fileURLWithPath: "/First.app"), bundleID: "test.first", name: "First")
    private let second = Application(url: URL(fileURLWithPath: "/Second.app"), bundleID: "test.second", name: "Second")
    private let third = Application(url: URL(fileURLWithPath: "/Third.app"), bundleID: "test.third", name: "Third")
    private let type = FileType(id: "test.document", name: "Document", extensions: ["testdoc"])
    private func catalog(_ types: [FileType], apps: [Application]) -> CatalogSnapshot {
        var value = TypeCatalog.discover(roots: [])
        value.types = types; value.applications = apps; value.warnings = []
        return value
    }
    @MainActor private struct Fixture {
        let model: AppModel
        let workspace: FakeWorkspace
        let source: CatalogSource
        let directory: URL
        func cleanup() { model.automaticRefresh.stop(); try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture(active: Bool = true, interval: TimeInterval = 3600,
                         inspect: @escaping @MainActor (URL) throws -> FileInspection = { _ in throw FiletoError.invalidExtension }) async -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = FakeWorkspace()
        workspace.rows[type.id] = Association(type: type, application: first, candidates: [first, second, third])
        let source = CatalogSource(catalog([type], apps: [first, second, third]))
        let model = AppModel(history: HistoryStore(url: directory.appendingPathComponent("history.json")),
                             workspace: workspace, discover: { source.discover() }, inspect: inspect,
                             observesSystemLifecycle: false, automaticRefreshDelay: 0, automaticRefreshInterval: interval)
        await model.start()
        if active { model.automaticRefresh.setAvailable(true); await model.automaticRefresh.task?.value }
        return Fixture(model: model, workspace: workspace, source: source, directory: directory)
    }
    func testAssociationCheckUpdatesReverseIndexAndPreservesInteractionState() async {
        let f = await fixture(); defer { f.cleanup() }
        let model = f.model
        model.mode = .applications; model.selectedApplication = second.id
        model.search = "testdoc"; model.appSearch = "Second"; model.applicationFilter = first.id
        model.selectedTypes = [type.id]; model.ascending = false; model.sortByApplication = true
        let calls = f.source.calls
        f.workspace.rows[type.id]?.application = second
        f.workspace.rows[type.id]?.candidates = [second, third]
        model.automaticRefresh.request(.associations)
        await model.automaticRefresh.task?.value
        XCTAssertEqual(model.associations.first?.application, second)
        XCTAssertEqual(model.associations.first?.candidates, [second, third])
        XCTAssertEqual(model.count(for: second), 1)
        XCTAssertEqual(model.count(for: first), 0)
        XCTAssertEqual(model.selectedTypes, [type.id])
        XCTAssertEqual(model.selectedApplication, second.id)
        XCTAssertEqual(model.applicationFilter, first.id)
        XCTAssertEqual(model.search, "testdoc"); XCTAssertEqual(model.appSearch, "Second")
        XCTAssertFalse(model.ascending); XCTAssertTrue(model.sortByApplication)
        XCTAssertEqual(f.source.calls, calls)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testBackgroundRequestsWaitForActivationAndDiscoverNewTypes() async {
        let f = await fixture(active: false); defer { f.cleanup() }
        let extra = FileType(id: "test.new", name: "New", extensions: ["newdoc"])
        f.workspace.rows[extra.id] = Association(type: extra, application: second, candidates: [second])
        f.source.replace(catalog([type, extra], apps: [first, second]))
        let calls = f.source.calls
        f.model.automaticRefresh.request(.associations)
        XCTAssertNil(f.model.automaticRefresh.task)
        XCTAssertEqual(f.source.calls, calls)
        f.model.automaticRefresh.setAvailable(true)
        await f.model.automaticRefresh.task?.value
        XCTAssertTrue(f.model.associations.contains { $0.id == extra.id })
        XCTAssertEqual(f.source.calls, calls + 1)
    }
    func testForegroundTimerChecksAssociationsWithoutRescanningCatalog() async {
        let f = await fixture(interval: 0.02); defer { f.cleanup() }
        let calls = f.source.calls
        let updated = expectation(description: "foreground timer detects external change")
        let observation = f.model.$associations.dropFirst().filter { $0.first?.application?.id == self.second.id }
            .first().sink { _ in updated.fulfill() }
        f.workspace.rows[type.id]?.application = second
        await fulfillment(of: [updated], timeout: 2)
        observation.cancel()
        XCTAssertEqual(f.source.calls, calls)
        XCTAssertFalse(f.model.scanning)
    }
    func testPreviewDefersAndCoalescesRefreshWithoutChangingPlan() async throws {
        let f = await fixture(); defer { f.cleanup() }
        let model = f.model
        model.selectedTypes = [type.id]; await model.beginChange(); model.choice = second.id; await model.prepareChange()
        model.didPresentSheet()
        f.workspace.rows[type.id]?.application = third
        let calls = f.source.calls
        for _ in 0..<5 { model.automaticRefresh.request(.catalog); model.automaticRefresh.request(.associations) }
        XCTAssertNil(model.automaticRefresh.task)
        XCTAssertEqual(model.associations.first?.application, first)
        XCTAssertEqual(model.plan.first?.before, first)
        let manager = AssociationManager(workspace: f.workspace)
        let results = await manager.apply(model.plan)
        XCTAssertEqual(results.first?.outcome, .conflict)
        model.cancelChoice()
        XCTAssertNil(model.automaticRefresh.task, "native dismissal must finish before refresh")
        model.didDismissSheet()
        await model.automaticRefresh.task?.value
        XCTAssertEqual(model.associations.first?.application, third)
        XCTAssertTrue(model.plan.isEmpty, "cancelled chooser cannot retain a submittable plan")
        XCTAssertEqual(f.source.calls, calls + 1)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testOpeningSheetDuringQueryDiscardsSnapshotUntilDismissal() async {
        let f = await fixture(); defer { f.cleanup() }
        f.workspace.rows[type.id]?.application = second
        f.workspace.onQuery = { _ in f.model.showingHistory = true }
        f.model.automaticRefresh.request(.associations)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.associations.first?.application, first)
        f.workspace.onQuery = nil
        f.model.showingHistory = false
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.associations.first?.application, second)
    }
    func testApplyingDefersFocusEventsAndExplicitRefreshSatisfiesPendingRequests() async {
        let f = await fixture(); defer { f.cleanup() }
        f.model.applying = true
        let calls = f.source.calls
        for _ in 0..<5 {
            f.model.automaticRefresh.setAvailable(false); f.model.automaticRefresh.setAvailable(true)
        }
        XCTAssertNil(f.model.automaticRefresh.task)
        f.workspace.rows[type.id]?.application = second
        f.model.applying = false
        await f.model.refresh()
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.associations.first?.application, second)
        XCTAssertEqual(f.source.calls, calls + 1)
    }
    func testExecutionPresentsFeedbackBeforeDeferredCatalogRefresh() async {
        let f = await fixture(); defer { f.cleanup() }
        let calls = f.source.calls
        f.workspace.onQuery = { _ in
            if f.model.applying { f.model.automaticRefresh.request(.catalog) }
        }
        var sawFeedback = false
        let observer = f.model.$message.compactMap { $0 }.sink { _ in
            sawFeedback = true
            XCTAssertEqual(f.source.calls, calls, "Pending background discovery must not delay verified feedback")
            XCTAssertFalse(f.model.scanning)
        }
        defer { observer.cancel() }
        await f.model.changeDefault(for: type.id, to: second)
        XCTAssertTrue(sawFeedback)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.source.calls, calls + 1, "Keep deferred external-change refreshes rather than dropping them")
        XCTAssertEqual(f.model.associations.first?.application, second)
    }
    func testQueryFailureKeepsPriorResultSelectionAndHistory() async {
        let f = await fixture(); defer { f.cleanup() }
        f.model.selectedTypes = [type.id]
        let result = ChangeResult(item: ChangeItem(type: type, before: first, target: second),
                                  outcome: .changed, message: "original", observed: second)
        let record = ChangeRecord(results: [result])
        f.model.records = [record]; f.model.latestResults = [result]
        f.workspace.failures.insert(type.id)
        f.model.automaticRefresh.request(.associations)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.associations.first?.application, first)
        XCTAssertEqual(f.model.selectedTypes, [type.id])
        XCTAssertFalse(f.model.warnings.isEmpty)
        XCTAssertEqual(f.model.records.first?.id, record.id)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
        XCTAssertEqual(f.model.latestResults.first?.observed, second)
    }
    func testRemovedApplicationClearsInvalidSelectionAndFilter() async {
        let f = await fixture(); defer { f.cleanup() }
        f.model.selectedApplication = first.id; f.model.applicationFilter = first.id
        f.workspace.rows[type.id] = Association(type: type, application: second, candidates: [second])
        f.source.replace(catalog([type], apps: [second]))
        f.model.automaticRefresh.request(.catalog)
        await f.model.automaticRefresh.task?.value
        XCTAssertNil(f.model.selectedApplication)
        XCTAssertEqual(f.model.applicationFilter, "")
        XCTAssertFalse(f.model.indexedApplications.contains { $0.id == first.id })
    }
    func testUnreadableCatalogDoesNotRemovePreviouslyDiscoveredTypes() async {
        let f = await fixture(); defer { f.cleanup() }
        f.model.selectedTypes = [type.id]
        var incomplete = catalog([], apps: [])
        incomplete.warnings = ["应用目录无法读取"]
        f.source.replace(incomplete)
        f.model.automaticRefresh.request(.catalog)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.associations.first?.id, type.id)
        XCTAssertEqual(f.model.selectedTypes, [type.id])
        XCTAssertTrue(f.model.warnings.contains("应用目录无法读取"))
    }
    func testInspectionQueryFailureKeepsConsistentPriorSnapshot() async {
        var application: Application?
        let f = await fixture(inspect: { [type] file in
            FileInspection(url: file, type: type, effectiveApplication: application)
        }); defer { f.cleanup() }
        application = first
        f.model.inspectFile(URL(fileURLWithPath: "/sample.testdoc"))
        XCTAssertEqual(f.model.sheet, .details)
        f.model.sheet = nil
        application = second; f.workspace.failures.insert(type.id)
        f.model.automaticRefresh.request(.associations)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.inspection?.effectiveApplication, first)
        XCTAssertNotNil(f.model.inspectionWarning)
    }
    func testInspectionUpdatesAndFailureRetainsLastQueryWithWarning() async {
        var application: Application?
        var fails = false
        let url = URL(fileURLWithPath: "/sample.testdoc")
        let f = await fixture(inspect: { [type] file in
            if fails { throw FiletoError.unknownType("sample") }
            return FileInspection(url: file, type: type, effectiveApplication: application)
        }); defer { f.cleanup() }
        application = first; f.model.inspectFile(url)
        f.model.sheet = nil
        application = second
        f.model.automaticRefresh.request(.associations)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.inspection?.effectiveApplication, second)
        XCTAssertNil(f.model.inspectionWarning)
        fails = true
        f.model.automaticRefresh.request(.associations)
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.inspection?.effectiveApplication, second)
        XCTAssertNotNil(f.model.inspectionWarning)
        XCTAssertEqual(f.model.selectedTypes, [type.id])
    }
}
