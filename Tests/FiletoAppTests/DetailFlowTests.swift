import XCTest
import AppKit
import Combine
@testable import FiletoCore
@testable import FiletoApp

@MainActor private final class DetailWorkspace: WorkspaceAccess {
    var rows: [String: Association] = [:]
    var queryFailures = Set<String>()
    var writeErrors: [String: NSError] = [:]
    var ignoreWrites = Set<String>()
    var failReadback = Set<String>()
    var writes: [String] = []
    var onWrite: (() -> Void)?
    var suspendWrite = false
    var pendingWrite: CheckedContinuation<Void, Never>?
    var onQuery: ((FileType) -> Void)?
    func association(for type: FileType) throws -> Association {
        onQuery?(type)
        if queryFailures.contains(type.id) { throw FiletoError.unknownType(type.id) }
        return rows[type.id]!
    }
    func setDefault(_ application: Application, for type: FileType) async throws {
        writes.append(type.id)
        if suspendWrite {
            await withCheckedContinuation { pendingWrite = $0; onWrite?() }
        }
        if let error = writeErrors[type.id] { throw error }
        if !ignoreWrites.contains(type.id) { rows[type.id]?.application = application }
        if failReadback.contains(type.id) { queryFailures.insert(type.id) }
    }
}

@MainActor final class DetailFlowTests: XCTestCase {
    private let first = Application(url: URL(fileURLWithPath: "/First.app"), bundleID: "test.first", name: "First")
    private let second = Application(url: URL(fileURLWithPath: "/Second.app"), bundleID: "test.second", name: "Second")
    private let one = FileType(id: "test.one", name: "One", extensions: ["one", "shared"])
    private let two = FileType(id: "test.two", name: "Two", extensions: ["two"])
    private struct Fixture {
        let model: AppModel
        let workspace: DetailWorkspace
        let directory: URL
    }
    private func fixture(inspect: (@MainActor (URL) throws -> FileInspection)? = nil) async -> Fixture {
        let workspace = DetailWorkspace()
        for type in [one, two] { workspace.rows[type.id] = Association(type: type, application: first, candidates: [first, second]) }
        var catalog = TypeCatalog.discover(roots: [])
        catalog.types = [one, two]; catalog.applications = [first, second]; catalog.warnings = []
        let snapshot = catalog
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(history: HistoryStore(url: directory.appendingPathComponent("history.json")), workspace: workspace,
                             discover: { snapshot }, inspect: inspect, observesSystemLifecycle: false, automaticRefreshDelay: 0)
        await model.start()
        model.selectedTypes = [one.id]
        return Fixture(model: model, workspace: workspace, directory: directory)
    }
    private func cleanup(_ f: Fixture) { f.model.automaticRefresh.stop(); try? FileManager.default.removeItem(at: f.directory) }
    private func preview(_ f: Fixture) async {
        await f.model.beginChange(); f.model.choice = second.id; await f.model.prepareChange()
    }
    func testDirectChangeDoesNotRescanCatalogOrQueryUnrelatedTypesBeforeSuccess() async {
        let workspace = DetailWorkspace()
        let rows = (0..<1025).map { index in
            Association(type: FileType(id: "test.incremental\(index)", name: "Type \(index)", extensions: ["i\(index)"]),
                        application: first, candidates: [first, second])
        }
        workspace.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let snapshot = CatalogSnapshot(types: rows.map(\.type), applications: [first, second], warnings: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(history: HistoryStore(url: directory.appendingPathComponent("history.json")), workspace: workspace,
                             discover: { XCTFail("Single-item feedback must not wait for catalog discovery"); return snapshot },
                             observesSystemLifecycle: false)
        defer { model.automaticRefresh.stop() }
        model.associations = rows; model.applications = [first, second]
        var queriedIDs: [String] = []
        workspace.onQuery = { queriedIDs.append($0.id) }
        var blockedByScan = false
        let observer = model.$scanning.sink { if $0 { blockedByScan = true } }
        defer { observer.cancel() }
        await model.changeDefault(for: rows[0].id, to: second)
        print("PERF single types=1025 queries=\(queriedIDs.count) unrelated=\(queriedIDs.filter { $0 != rows[0].id }.count)")
        XCTAssertEqual(queriedIDs.count, 2, "Reuse preflight and verified readback without another refresh")
        XCTAssertEqual(Set(queriedIDs), [rows[0].id], "Do not query unrelated types")
        XCTAssertFalse(blockedByScan, "The interface must not enter a full blocking scan after a write")
        XCTAssertEqual(model.associations.first?.application, second)
        XCTAssertEqual(model.count(for: second), 1)
        XCTAssertEqual(model.message?.title, "已修改并验证")
    }

    func testExecutionKeepsUnrelatedQueryWarningsAndUpdatesCandidateSnapshot() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.queryFailures.insert(two.id)
        await f.model.refresh()
        let warnings = f.model.warnings
        let refreshDate = f.model.lastRefreshed
        f.workspace.onQuery = { type in
            if type.id == self.one.id && !f.workspace.writes.isEmpty {
                f.workspace.rows[type.id]?.candidates = [self.second]
            }
        }
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.associations.first { $0.id == one.id }?.candidates, [second])
        XCTAssertNotNil(f.model.queryErrors[two.id])
        XCTAssertEqual(f.model.warnings, warnings)
        XCTAssertEqual(f.model.lastRefreshed, refreshDate, "A partial update must not claim the whole catalog was refreshed")
        XCTAssertEqual(f.model.message?.title, "已修改并验证")
    }

    func testExecutionRefreshesRelatedFileOpeningWithoutAssumingItsDefaultMatchesTheType() async {
        var inspections = 0
        let f = await fixture(inspect: { file in
            inspections += 1
            // This file keeps its own opening preference even when the type default changes.
            return FileInspection(url: file, type: self.one, effectiveApplication: self.first)
        }); defer { cleanup(f) }
        f.model.inspectFile(URL(fileURLWithPath: "/sample.one")); f.model.sheet = nil
        var queriedIDs: [String] = []
        f.workspace.onQuery = { queriedIDs.append($0.id) }
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.focusedRow?.application, second)
        XCTAssertEqual(f.model.inspection?.effectiveApplication, first)
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(queriedIDs, [one.id, one.id])
        XCTAssertNil(f.model.inspectionWarning)
    }

    func testExecutionPreservesRelatedFileSnapshotWhenVerificationQueryFails() async {
        let f = await fixture(inspect: { file in
            FileInspection(url: file, type: self.one, effectiveApplication: self.first)
        }); defer { cleanup(f) }
        f.model.inspectFile(URL(fileURLWithPath: "/sample.one")); f.model.sheet = nil
        f.workspace.failReadback.insert(one.id)
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .unverified)
        XCTAssertEqual(f.model.inspection?.effectiveApplication, first)
        XCTAssertNotNil(f.model.inspectionWarning)
        XCTAssertNotNil(f.model.queryErrors[one.id])
        XCTAssertFalse(f.model.warnings.isEmpty)
    }

    func testExecutionDoesNotReinspectAnUnrelatedFile() async {
        let f = await fixture(inspect: { _ in
            XCTFail("An unrelated file must not delay modification feedback")
            throw FiletoError.invalidExtension
        }); defer { cleanup(f) }
        f.model.inspection = FileInspection(url: URL(fileURLWithPath: "/sample.two"), type: two, effectiveApplication: first)
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.inspection?.type, two)
        XCTAssertEqual(f.model.inspection?.effectiveApplication, first)
        XCTAssertNil(f.model.inspectionWarning)
    }

    func testChooserSnapshotAndVerifiedWriteUpdateDetailAndList() async {
        let f = await fixture(); defer { cleanup(f) }
        XCTAssertEqual(f.model.focusedRow?.application, first)
        await preview(f)
        XCTAssertEqual(f.model.plan.first?.before, first)
        XCTAssertEqual(f.model.plan.first?.type.extensions, ["one", "shared"])
        await f.model.execute()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed])
        XCTAssertEqual(f.model.focusedRow?.application, second)
        XCTAssertEqual(f.model.count(for: second), 1)
        XCTAssertEqual(f.model.records.first?.results.first?.outcome, .changed)
        XCTAssertNil(f.model.sheet, "ordinary single-item chooser success uses a message")
        XCTAssertEqual(f.model.message?.title, "已修改并验证")
        await f.model.execute()
        XCTAssertEqual(f.workspace.writes, [one.id], "completed preview cannot be submitted again")
    }
    func testCancelChoiceAndCancelPreviewNeverWrite() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange(); f.model.choice = second.id; f.model.cancelChoice(); await f.model.prepareChange()
        XCTAssertFalse(f.model.showingPreview)
        XCTAssertTrue(f.model.plan.isEmpty)
        await preview(f); f.model.cancelChoice()
        await f.model.execute()
        XCTAssertTrue(f.workspace.writes.isEmpty)
        f.workspace.rows[one.id]?.application = second
        let result = ChangeResult(item: ChangeItem(type: one, before: first, target: second), outcome: .changed, message: "verified", observed: second)
        f.model.prepareRestore(ChangeRecord(results: [result]))
        XCTAssertTrue(f.model.showingPreview)
        f.model.showingPreview = false
        await f.model.execute()
        XCTAssertTrue(f.workspace.writes.isEmpty, "cancelled restore preview must not write")
    }
    func testCurrentApplicationAndUnsupportedBrowseChoiceCannotContinue() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange()
        XCTAssertFalse(f.model.canContinue)
        f.model.choice = first.id
        XCTAssertFalse(f.model.canContinue)
        await f.model.prepareChange()
        XCTAssertFalse(f.model.showingPreview)
        let other = Application(url: URL(fileURLWithPath: "/Other.app"), bundleID: "test.other", name: "Other")
        f.model.extraChoice = other; f.model.choice = other.id
        XCTAssertEqual(f.model.coverage(other), 0)
        XCTAssertFalse(f.model.canContinue)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testNoDefaultApplicationCanBeChangedWithoutPromisingRestore() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[one.id]?.application = nil
        await preview(f)
        XCTAssertNil(f.model.plan.first?.before)
        await f.model.execute()
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
        f.model.prepareRestore(f.model.records[0])
        XCTAssertNotNil(f.model.error)
    }
    func testRemovedCandidateFailsWithoutSystemWriteAndRetryCanRecover() async {
        let f = await fixture(); defer { cleanup(f) }
        await preview(f)
        f.workspace.rows[one.id]?.candidates = [first]
        await f.model.execute()
        XCTAssertEqual(f.model.latestResults.first?.outcome, .failed)
        XCTAssertTrue(f.workspace.writes.isEmpty)
        XCTAssertEqual(f.model.focusedRow?.application, first)
        f.workspace.rows[one.id]?.candidates = [first, second]
        f.model.retry(f.model.latestResults)
        await f.model.execute()
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
    }
    func testRejectedAndCancelledRequestsHaveDistinctResults() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        f.workspace.writeErrors[one.id] = NSError(domain: NSOSStatusErrorDomain, code: -54)
        f.workspace.writeErrors[two.id] = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        await preview(f); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.failed, .cancelled])
        XCTAssertEqual(f.model.chosenRows.map(\.application), [first, first])
        XCTAssertNotNil(f.model.latestResults.first?.errorDetails)
    }
    func testAcceptedButUnchangedReadbackRemainsUnverifiedAndIsNotRetried() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.ignoreWrites.insert(one.id)
        await preview(f); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.first?.outcome, .unverified)
        XCTAssertEqual(f.model.focusedRow?.application, first)
        f.model.retry(f.model.latestResults)
        XCTAssertFalse(f.model.showingPreview)
        XCTAssertEqual(f.workspace.writes, [one.id])
    }
    func testReadbackFailureAfterAcceptedWriteIsUnverifiedAndMarksOldDetail() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.failReadback.insert(one.id)
        await preview(f); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.first?.outcome, .unverified)
        XCTAssertNotNil(f.model.queryErrors[one.id])
        XCTAssertEqual(f.model.focusedRow?.application, first)
        f.workspace.queryFailures = []
        await f.model.refresh()
        XCTAssertNil(f.model.queryErrors[one.id])
        XCTAssertEqual(f.model.focusedRow?.application, second)
    }
    func testBatchSuccessAndPartialFailureRetryOnlyFailedItems() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        XCTAssertNil(f.model.focusedRow)
        f.workspace.writeErrors[two.id] = NSError(domain: NSOSStatusErrorDomain, code: -54)
        await preview(f); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed, .failed])
        let results = f.model.latestResults + [ChangeResult(item: ChangeItem(type: one, before: first, target: second), outcome: .conflict, message: "conflict", observed: second)]
        f.workspace.writeErrors = [:]
        f.model.retry(results)
        XCTAssertEqual(f.model.plan.map(\.id), [two.id])
        await f.model.execute()
        XCTAssertEqual(f.workspace.writes, [one.id, two.id, two.id])
        XCTAssertTrue(f.model.chosenRows.allSatisfy { $0.application == second })
        XCTAssertTrue(f.model.showingResults)
        f.model.showingResults = false
        f.workspace.rows[one.id]?.application = first; f.workspace.rows[two.id]?.application = first
        await preview(f); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed, .changed])
    }
    func testBatchPreviewIncludesUnsupportedTypes() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        f.workspace.rows[two.id]?.candidates = [first]
        await f.model.beginChange(); f.model.choice = second.id
        XCTAssertEqual(f.model.choiceSummary, .init(changes: 1, unchanged: 0, unsupported: 1))
        XCTAssertTrue(f.model.canContinue)
        await f.model.prepareChange()
        XCTAssertEqual(f.model.plan.map(\.id), [one.id])
        XCTAssertEqual(f.model.skipped.count, 1)
        XCTAssertTrue(f.model.skipped[0].contains("Two"))
        await f.model.execute()
        XCTAssertEqual(f.model.resultSkipped.count, 1)
    }
    func testBatchIncludesAlreadyDefaultItemWithoutRepeatingWrite() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[two.id]?.application = second
        f.model.selectedTypes = [one.id, two.id]
        await f.model.beginChange(); f.model.choice = second.id
        XCTAssertEqual(f.model.choiceSummary, .init(changes: 1, unchanged: 1, unsupported: 0))
        XCTAssertTrue(f.model.canContinue)
        await f.model.prepareChange(); await f.model.execute()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed, .alreadyDefault])
        XCTAssertEqual(f.workspace.writes, [one.id])
    }
    func testBatchWithOnlyAlreadyDefaultAndUnsupportedTypesExplainsNoChanges() async {
        let f = await fixture(); defer { cleanup(f) }
        // A current default can be absent from the fresh candidate range. Count it as
        // unsupported, matching prepareChange, rather than subtracting currentCount from coverage.
        f.workspace.rows[two.id]?.candidates = [second]
        f.model.selectedTypes = [one.id, two.id]
        await f.model.beginChange()
        XCTAssertNil(f.model.choiceSummary)
        f.model.choice = first.id
        XCTAssertEqual(f.model.currentCount(first), 2)
        XCTAssertEqual(f.model.choiceSummary, .init(changes: 0, unchanged: 1, unsupported: 1))
        XCTAssertFalse(f.model.canContinue)
        await f.model.prepareChange()
        XCTAssertTrue(f.model.plan.isEmpty)
        XCTAssertTrue(f.workspace.writes.isEmpty)
        f.model.cancelChoice()
        XCTAssertNil(f.model.choiceSummary)
    }

    func testChoiceIndexCountsTypesOnceAndUpdatesBrowsedApplicationNames() async {
        let f = await fixture(); defer { cleanup(f) }
        let sameName = Application(url: URL(fileURLWithPath: "/SameName.app"), bundleID: "test.same-name", name: first.name)
        f.workspace.rows[one.id]?.candidates = [first, second, second, sameName]
        f.workspace.rows[two.id]?.candidates = [first]
        f.model.selectedTypes = [one.id, two.id]
        await f.model.beginChange()
        XCTAssertEqual(f.model.systemChoiceCount, 3)
        XCTAssertEqual(f.model.coverage(second), 1)
        XCTAssertEqual(f.model.choices.first, first)
        XCTAssertTrue(f.model.hasDuplicateChoiceName(first))
        f.model.choice = second.id
        XCTAssertEqual(f.model.choiceSummary, .init(changes: 1, unchanged: 0, unsupported: 1))
        let renamed = Application(url: sameName.url, bundleID: sameName.bundleID, name: "Renamed")
        f.model.extraChoice = renamed
        XCTAssertFalse(f.model.hasDuplicateChoiceName(first))
        XCTAssertEqual(f.model.choices.first { $0.id == renamed.id }?.name, "Renamed")
        XCTAssertEqual(f.model.coverage(renamed), 1)
        f.model.extraChoice = nil
        XCTAssertTrue(f.model.hasDuplicateChoiceName(first))
        let other = Application(url: URL(fileURLWithPath: "/Other.app"), bundleID: "test.other", name: first.name)
        f.model.extraChoice = other; f.model.choice = other.id
        XCTAssertEqual(f.model.systemChoiceCount, 3)
        XCTAssertEqual(f.model.choices.count, 4)
        XCTAssertEqual(f.model.choiceSummary, .init(changes: 0, unchanged: 0, unsupported: 2))
        XCTAssertFalse(f.model.canContinue)
        f.model.cancelChoice()
        f.model.selectedTypes = [two.id]
        await f.model.beginChange()
        XCTAssertEqual(f.model.choices, [first])
        XCTAssertEqual(f.model.coverage(second), 0)
        XCTAssertFalse(f.model.hasDuplicateChoiceName(first))
    }

    func testChoiceQueryProgressCountsCompletedTypesInBothPhases() async {
        let f = await fixture(); defer { cleanup(f) }
        let rows = (0..<25).map { index in
            Association(type: FileType(id: "test.progress\(index)", name: "Progress \(index)", extensions: ["p\(index)"]), application: first, candidates: [first, second])
        }
        f.model.associations = rows
        for row in rows { f.workspace.rows[row.id] = row }
        f.model.selectedTypes = Set(rows.map(\.id))
        var queries = 0
        f.workspace.onQuery = { _ in
            queries += 1
            if queries == 21 {
                XCTAssertEqual(f.model.choiceQueryProgress, .init(completed: 20, total: 25))
                XCTAssertTrue(f.model.loadingChoices)
                XCTAssertFalse(f.model.canContinue)
            }
        }
        await f.model.beginChange()
        XCTAssertEqual(queries, 25)
        XCTAssertNil(f.model.choiceQueryProgress)
        f.model.choice = second.id; queries = 0
        var sawPreparationProgress = false
        let observer = f.model.$choiceQueryProgress.sink { progress in
            if progress == .init(completed: 20, total: 25, preparingPreview: true) { sawPreparationProgress = true }
        }
        defer { observer.cancel() }
        await f.model.prepareChange()
        XCTAssertTrue(sawPreparationProgress)
        XCTAssertEqual(queries, 0, "Preparation must retain the displayed snapshot")
        XCTAssertEqual(f.model.plan.count, 25)
        XCTAssertNil(f.model.choiceQueryProgress)
    }
    func testRapidSelectionChangeDiscardsChooserAndCannotSubmitOldTarget() async {
        let f = await fixture(); defer { cleanup(f) }
        for _ in 0..<20 {
            f.model.selectedTypes = [one.id]; await f.model.beginChange(); f.model.choice = second.id
            f.model.selectedTypes = [two.id]
            XCTAssertFalse(f.model.choosingApplication)
            XCTAssertFalse(f.model.canContinue)
            await f.model.prepareChange()
            XCTAssertFalse(f.model.showingPreview)
        }
        XCTAssertEqual(f.model.focusedRow?.id, two.id)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testSelectionChangesDuringCandidateQueryDiscardOldSnapshot() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[one.id]?.application = second
        f.workspace.onQuery = { _ in
            XCTAssertTrue(f.model.loadingChoices)
            f.model.selectedTypes = [self.two.id]
        }
        await f.model.beginChange()
        XCTAssertFalse(f.model.choosingApplication)
        XCTAssertFalse(f.model.loadingChoices)
        XCTAssertTrue(f.model.changeRows.isEmpty)
        XCTAssertEqual(f.model.associations.first { $0.id == one.id }?.application, first, "late candidate snapshot must not commit")
        f.workspace.onQuery = nil
        await f.model.beginChange()
        XCTAssertEqual(f.model.changeRows.map(\.id), [two.id])
        XCTAssertEqual(f.model.focusedRow?.id, two.id)
    }
    func testSelectionChangesDuringPreparationCannotSubmitStaleSnapshot() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange(); f.model.choice = second.id
        let observer = f.model.$choiceQueryProgress.compactMap { $0 }.filter { $0.preparingPreview }.first().sink { _ in
            f.model.selectedTypes = [self.two.id]
        }
        defer { observer.cancel() }
        await f.model.submitChange()
        XCTAssertFalse(f.model.showingPreview)
        XCTAssertTrue(f.model.plan.isEmpty)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testChooserSubmitsWithoutPresentingAnotherPreviewAndWaitsForDismissal() async {
        for ids: Set<String> in [[one.id], [one.id, two.id]] {
            let f = await fixture(); defer { cleanup(f) }
            f.model.selectedTypes = ids
            await f.model.beginChange(); f.model.choice = second.id; f.model.didPresentSheet()
            var presentedPreview = false
            let observer = f.model.$sheet.sink { if $0 == .preview { presentedPreview = true } }
            defer { observer.cancel() }
            let task = Task { await f.model.submitChange() }
            for _ in 0..<50 { if f.model.applying { break }; await Task.yield() }
            XCTAssertTrue(f.model.applying)
            XCTAssertNil(f.model.sheet)
            XCTAssertEqual(f.model.plan.count, ids.count, "keep the total visible while the chooser closes")
            XCTAssertTrue(f.workspace.writes.isEmpty)
            f.model.didDismissSheet()
            await task.value
            XCTAssertFalse(presentedPreview)
            XCTAssertEqual(f.model.latestResults.map(\.outcome), Array(repeating: .changed, count: ids.count))
            XCTAssertEqual(Set(f.workspace.writes), ids)
        }
    }
    func testTargetChangeDuringPreparationCancelsOldPlanAndAllowsNewSubmission() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange(); f.model.choice = second.id
        let observer = f.model.$choiceQueryProgress.compactMap { $0 }.filter { $0.preparingPreview }.first().sink { _ in
            f.model.choice = self.first.id
        }
        defer { observer.cancel() }
        await f.model.submitChange()
        XCTAssertFalse(f.model.loadingChoices)
        XCTAssertTrue(f.model.plan.isEmpty)
        XCTAssertTrue(f.workspace.writes.isEmpty)
        f.model.choice = second.id
        await f.model.submitChange()
        XCTAssertEqual(f.workspace.writes, [one.id])
    }
    func testExternalChangeAfterChooserIsAConflictEvenBeforePreparation() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange(); f.model.choice = second.id
        f.workspace.rows[one.id]?.application = nil
        await f.model.submitChange()
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.conflict])
        XCTAssertEqual(f.model.latestResults.first?.item.before, first)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
    func testChangingTargetOrClosingChooserInvalidatesPreparedPlan() async {
        let f = await fixture(); defer { cleanup(f) }
        await preview(f)
        XCTAssertEqual(f.model.sheet, .chooser)
        f.model.choice = first.id
        await f.model.execute()
        XCTAssertTrue(f.model.plan.isEmpty)
        f.model.choice = second.id; await f.model.prepareChange()
        f.model.cancelChoice(); await f.model.execute()
        XCTAssertTrue(f.model.plan.isEmpty)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }

    func testQueryFailureBlocksIncompleteBatchAndRefreshRecovers() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.queryFailures.insert(two.id); f.model.selectedTypes = [one.id, two.id]
        await f.model.beginChange(); f.model.choice = second.id
        XCTAssertFalse(f.model.canContinue)
        XCTAssertNotNil(f.model.choiceError)
        XCTAssertNotNil(f.model.queryErrors[two.id])
        f.workspace.queryFailures = []
        await f.model.refresh()
        XCTAssertFalse(f.model.choosingApplication)
        await f.model.beginChange(); f.model.choice = second.id
        XCTAssertTrue(f.model.canContinue)
    }
    func testWindowClosureStopsLaterItemsKeepsCurrentRequestAndPreventsDoubleSubmit() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        await preview(f)
        f.workspace.suspendWrite = true
        let started = expectation(description: "system request submitted")
        f.workspace.onWrite = { started.fulfill() }
        let task = Task { await f.model.execute() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(f.model.executionStage, .requesting)
        await f.model.execute()
        XCTAssertEqual(f.workspace.writes, [one.id])
        // Use an offscreen AppKit window to exercise the production close observer.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let registration = MainWindowRegistration.RegistrationView(register: { _ in }, onClose: { f.model.mainWindowClosed() })
        window.contentView = registration
        window.close()
        XCTAssertTrue(f.model.applying)
        XCTAssertTrue(f.model.stopRequested)
        f.workspace.pendingWrite?.resume(); f.workspace.pendingWrite = nil
        await task.value
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed, .cancelled])
        XCTAssertEqual(f.workspace.writes, [one.id])
        XCTAssertEqual(f.model.records.first?.results.count, 2)
        XCTAssertFalse(f.model.applying)
        window.contentView = nil
    }
    func testExecuteWaitsForActualNativeSheetDismissal() async {
        let f = await fixture(); defer { cleanup(f) }
        await preview(f); f.model.didPresentSheet()
        let task = Task { await f.model.execute() }
        await Task.yield()
        XCTAssertTrue(f.model.applying)
        XCTAssertTrue(f.workspace.writes.isEmpty)
        f.model.didDismissSheet()
        await task.value
        XCTAssertEqual(f.workspace.writes, [one.id])
    }
    func testAutomaticRefreshDefersWhileChoosingAndDoesNotRewriteSnapshot() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange()
        f.workspace.rows[one.id]?.application = second
        f.model.automaticRefresh.setAvailable(true)
        XCTAssertNil(f.model.automaticRefresh.task)
        XCTAssertEqual(f.model.changeRows.first?.application, first)
        f.model.cancelChoice()
        await f.model.automaticRefresh.task?.value
        XCTAssertEqual(f.model.focusedRow?.application, second)
    }
    func testCancelledNewChoiceDoesNotChangeRestoreResultRetryKind() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[one.id]?.application = second
        let original = ChangeResult(item: ChangeItem(type: one, before: first, target: second),
                                    outcome: .changed, message: "verified", observed: second)
        f.model.prepareRestore(ChangeRecord(results: [original]))
        f.workspace.writeErrors[one.id] = NSError(domain: NSOSStatusErrorDomain, code: -54)
        await f.model.execute()
        XCTAssertTrue(f.model.resultsAreRestore)
        f.model.showingResults = false
        await f.model.beginChange(); f.model.cancelChoice()
        XCTAssertFalse(f.model.isRestore)
        f.model.retry(f.model.latestResults, restoring: f.model.resultsAreRestore)
        XCTAssertTrue(f.model.isRestore)
        XCTAssertEqual(f.model.plan.first?.target, first)
    }

    func testRowMenuTargetsOnlyClickedUTIInBothViewsDespiteMultipleSelection() async {
        for mode in AppModel.Mode.allCases {
            let f = await fixture(); defer { cleanup(f) }
            f.model.switchMode(mode)
            if mode == .applications { f.model.selectApplication(first.id) }
            f.model.selectedTypes = [one.id, two.id]
            await f.model.changeDefault(for: two.id, to: second)
            XCTAssertNil(f.model.sheet)
            XCTAssertFalse(f.model.choosingApplication)
            XCTAssertEqual(f.model.associations.first { $0.id == two.id }?.application, second)
            XCTAssertEqual(f.workspace.writes, [two.id])
            XCTAssertEqual(f.model.records.first?.results.first?.item.before, first)
            XCTAssertEqual(f.model.message?.title, "已修改并验证")
            await f.model.execute()
            XCTAssertEqual(f.workspace.writes, [two.id], "completed direct change cannot be submitted again")
        }
    }

    func testStaleRowMenuCandidateShowsFailureWithoutWrite() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[one.id]?.candidates = [first]
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.sheet, .results)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .failed)
        XCTAssertEqual(f.model.records.first?.results.first?.outcome, .failed)
        XCTAssertNil(f.model.message)
        XCTAssertTrue(f.workspace.writes.isEmpty)
        XCTAssertFalse(f.model.choosingApplication)
    }

    func testRowMenuQueryFailureKeepsOldValueAndShowsFailure() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.queryFailures.insert(one.id)
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.sheet, .results)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .failed)
        XCTAssertNotNil(f.model.queryErrors[one.id])
        XCTAssertNil(f.model.message)
        XCTAssertEqual(f.model.focusedRow?.application, first)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }

    func testDirectChangeKeepsDisplayedSnapshotAndRejectsExternalDefaultChange() async {
        let f = await fixture(); defer { cleanup(f) }
        let displayed = f.model.focusedRow!
        f.workspace.rows[one.id]?.application = nil
        // Even if a refresh arrives while the native menu is open, preserve the
        // default shown in that menu rather than replacing the before snapshot.
        await f.model.refresh()
        await f.model.changeDefault(for: one.id, to: second, from: displayed)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .conflict)
        XCTAssertEqual(f.model.latestResults.first?.item.before, first)
        XCTAssertEqual(f.model.sheet, .results)
        XCTAssertNil(f.model.message)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }

    func testDirectChangeAlreadyAtTargetDoesNotWriteAndShowsMessage() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.rows[one.id]?.application = second
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .alreadyDefault)
        XCTAssertNil(f.model.sheet)
        XCTAssertEqual(f.model.message?.title, "已是目标应用，无需修改")
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }

    func testDirectChangeCancelledOrUnverifiedKeepsResultDetails() async {
        for outcome in [ChangeOutcome.cancelled, .unverified] {
            let f = await fixture(); defer { cleanup(f) }
            if outcome == .cancelled {
                f.workspace.writeErrors[one.id] = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            } else {
                f.workspace.ignoreWrites.insert(one.id)
            }
            await f.model.changeDefault(for: one.id, to: second)
            XCTAssertEqual(f.model.latestResults.first?.outcome, outcome)
            XCTAssertEqual(f.model.records.first?.results.first?.outcome, outcome)
            XCTAssertEqual(f.model.sheet, .results)
            XCTAssertNil(f.model.message)
        }
    }

    func testDirectChangeBlocksRepeatedSubmissionAndDefersAutomaticRefresh() async {
        let f = await fixture(); defer { cleanup(f) }
        f.workspace.suspendWrite = true
        let started = expectation(description: "direct system request submitted")
        f.workspace.onWrite = { started.fulfill() }
        let task = Task { await f.model.changeDefault(for: one.id, to: second) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(f.model.applying)
        XCTAssertNil(f.model.sheet)
        XCTAssertEqual(f.model.executionStage, .requesting)
        f.model.automaticRefresh.setAvailable(true)
        XCTAssertNil(f.model.automaticRefresh.task)
        await f.model.changeDefault(for: two.id, to: second)
        XCTAssertEqual(f.workspace.writes, [one.id])
        f.workspace.pendingWrite?.resume(); f.workspace.pendingWrite = nil
        await task.value
        XCTAssertFalse(f.model.applying)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
        XCTAssertEqual(f.model.records.count, 1)
    }

    func testSingleSuccessWithHistorySaveFailureStillShowsResults() async throws {
        let f = await fixture(); defer { cleanup(f) }
        // Make the history parent a regular file so persistence fails after the write.
        try Data().write(to: f.directory)
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
        XCTAssertEqual(f.model.sheet, .results)
        XCTAssertTrue(f.model.error?.contains("操作记录保存失败") == true)
        XCTAssertNil(f.model.message)
        XCTAssertEqual(f.workspace.writes, [one.id])
    }

    func testDetailIdentifiesClickedRowWithoutChangingBatchSelection() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        f.model.showDetails(for: two.id)
        XCTAssertEqual(f.model.sheet, .details)
        XCTAssertEqual(f.model.detailRow?.id, two.id)
        XCTAssertEqual(f.model.selectedTypes, [one.id, two.id])
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.sheet, .details)
        XCTAssertTrue(f.model.plan.isEmpty)
        f.model.sheet = nil
        f.model.showDetails(for: one.id)
        XCTAssertEqual(f.model.detailRow?.type.extensions, ["one", "shared"])
    }

    func testApplicationDefaultScopeRemovesChangedRowAndUpdatesCounts() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.switchMode(.applications); f.model.selectApplication(first.id)
        await f.model.changeDefault(for: one.id, to: second)
        XCTAssertEqual(f.model.visibleRows.map(\.id), [two.id])
        XCTAssertEqual(f.model.count(for: first), 1)
        XCTAssertEqual(f.model.count(for: second), 1)
        XCTAssertTrue(f.model.chosenRows.isEmpty, "hidden rows cannot be included in another batch")
        XCTAssertEqual(f.model.latestResults.first?.outcome, .changed)
        XCTAssertNil(f.model.sheet)
        XCTAssertTrue(f.model.message?.text.contains(one.extensionLabel) == true, "feedback identifies the type after it leaves the filter")
        XCTAssertEqual(f.model.records.first?.results.first?.item.type, one)
        f.model.showCandidates = true
        XCTAssertEqual(Set(f.model.visibleRows.map(\.id)), [one.id, two.id])
    }

    func testCandidateScopeChangesDefaultWithoutUsingSidebarApplicationAsTarget() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.switchMode(.applications); f.model.selectApplication(second.id); f.model.showCandidates = true
        f.model.selectedTypes = [one.id, two.id]
        await f.model.beginChange()
        XCTAssertEqual(f.model.sheet, .chooser)
        XCTAssertEqual(f.model.choice, "")
        f.model.choice = second.id; await f.model.prepareChange(); await f.model.execute()
        XCTAssertEqual(Set(f.model.visibleRows.map(\.id)), [one.id, two.id])
        XCTAssertEqual(f.model.latestResults.map(\.outcome), [.changed, .changed])
    }

    func testBatchOnlyIncludesSelectedRowsStillInFilter() async {
        let f = await fixture(); defer { cleanup(f) }
        f.model.selectedTypes = [one.id, two.id]
        f.model.search = "Two"
        await f.model.beginChange()
        XCTAssertEqual(f.model.selectedTypes, [two.id])
        XCTAssertEqual(f.model.changeRows.map(\.id), [two.id])
        f.model.choice = second.id; await f.model.prepareChange()
        XCTAssertEqual(f.model.plan.map(\.id), [two.id])
    }

    func testClosingChooserCancelsAndCannotPrepareOldSelection() async {
        let f = await fixture(); defer { cleanup(f) }
        await f.model.beginChange(); f.model.choice = second.id
        f.model.sheet = nil
        await f.model.prepareChange()
        XCTAssertFalse(f.model.choosingApplication)
        XCTAssertTrue(f.model.plan.isEmpty)
        XCTAssertTrue(f.workspace.writes.isEmpty)
    }
}
