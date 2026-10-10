import XCTest
@testable import FiletoCore

@MainActor final class FakeWorkspace: WorkspaceAccess {
    var rows: [String: Association] = [:]
    var failures = Set<String>()
    var ignoresWrites = Set<String>()
    var errors: [String: NSError] = [:]
    var writes: [String] = []
    var queryFailures = Set<String>()
    var failQueriesAfterWrite = false
    var queries: [String] = []
    func association(for type: FileType) throws -> Association {
        queries.append(type.id)
        if queryFailures.contains(type.id) { throw FiletoError.unknownType(type.id) }
        guard let row = rows[type.id] else { throw FiletoError.unknownType(type.id) }; return row
    }
    func setDefault(_ application: Application, for type: FileType) async throws {
        writes.append(type.id)
        if let error = errors[type.id] { throw error }
        if failures.contains(type.id) { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟系统拒绝"]) }
        if !ignoresWrites.contains(type.id) { rows[type.id]?.application = application }
        if failQueriesAfterWrite { queryFailures.insert(type.id) }
    }
}

final class AssociationManagerTests: XCTestCase {
    let first = Application(url: URL(fileURLWithPath: "/First.app"), bundleID: "test.first", name: "First")
    let second = Application(url: URL(fileURLWithPath: "/Second.app"), bundleID: "test.second", name: "Second")
    let third = Application(url: URL(fileURLWithPath: "/Third.app"), bundleID: "test.third", name: "Third")
    let pdf = FileType(id: "com.adobe.pdf", name: "PDF", extensions: ["pdf"])
    let jpeg = FileType(id: "public.jpeg", name: "JPEG", extensions: ["jpg", "jpeg"])

    @MainActor func makeWorkspace() -> FakeWorkspace {
        let workspace = FakeWorkspace()
        for type in [pdf, jpeg] { workspace.rows[type.id] = Association(type: type, application: first, candidates: [first, second, third]) }
        return workspace
    }
    @MainActor func testDeduplicatedBatchReportsPartialFailureAndRestoresOnlySuccessfulChanges() async throws {
        let workspace = makeWorkspace(); workspace.failures.insert(jpeg.id)
        let manager = AssociationManager(workspace: workspace)
        let plan = try manager.preview(types: [pdf, pdf, jpeg], target: second)
        XCTAssertEqual(plan.count, 2)
        let results = await manager.apply(plan)
        XCTAssertEqual(results.map(\.outcome), [.changed, .failed])
        XCTAssertEqual(workspace.writes, [pdf.id, jpeg.id])
        let restore = try manager.restorePreview(ChangeRecord(results: results))
        XCTAssertEqual(restore.map(\.id), [pdf.id])
        let restored = await manager.apply(restore)
        XCTAssertEqual(restored.first?.outcome, .changed)
        XCTAssertEqual(workspace.rows[pdf.id]?.application, first)
    }
    @MainActor func testExecutionSharesActualQueriesWithoutExtraReadbackOrStoppedItemQueries() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let plan = try [pdf, jpeg].map { try manager.preview(association: workspace.rows[$0.id]!, target: second) }
        var observations: [Association] = []
        var stop = false
        let results = await manager.apply(plan, shouldStop: { stop }, onStage: { item, stage in
            if stage == .verifying { workspace.rows[item.id]?.candidates = [self.second, self.third] }
        }, onQuery: { _, query in
            if case .success(let row) = query { observations.append(row) }
        }, onResult: { _ in stop = true })
        XCTAssertEqual(results.map(\.outcome), [.changed, .cancelled])
        XCTAssertEqual(workspace.queries, [pdf.id, pdf.id])
        XCTAssertEqual(observations.map(\.application), [first, second])
        XCTAssertEqual(observations.last?.candidates, [second, third])
        XCTAssertEqual(workspace.writes, [pdf.id])
    }
    @MainActor func testExecutionSharesQueryFailureWithoutReportingAnAcceptedWriteAsSuccess() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        workspace.failQueriesAfterWrite = true
        let item = try manager.preview(association: workspace.rows[pdf.id]!, target: second)
        var knownRows: [Association] = []
        var failedIDs: [String] = []
        let results = await manager.apply([item], onQuery: { type, query in
            switch query {
            case .success(let row): knownRows.append(row)
            case .failure: failedIDs.append(type.id)
            }
        })
        XCTAssertEqual(results.first?.outcome, .unverified)
        XCTAssertEqual(knownRows.map(\.application), [first])
        XCTAssertEqual(failedIDs, [pdf.id])
        XCTAssertEqual(workspace.queries, [pdf.id, pdf.id])
    }
    @MainActor func testStalePreviewDoesNotOverwriteLaterChange() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let plan = try manager.preview(types: [pdf], target: second)
        workspace.rows[pdf.id]?.application = third
        let results = await manager.apply(plan)
        XCTAssertEqual(results.first?.outcome, .conflict)
        XCTAssertTrue(workspace.writes.isEmpty)
    }
    @MainActor func testSnapshotPreviewReusesQueryAndRejectsUnsupportedTarget() throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let association = try manager.query(pdf)
        let item = try manager.preview(association: association, target: second)
        XCTAssertEqual(workspace.queries, [pdf.id])
        XCTAssertEqual(item.type, pdf)
        XCTAssertEqual(item.before, first)
        XCTAssertEqual(item.target, second)
        let unsupported = Association(type: pdf, application: first, candidates: [first])
        XCTAssertThrowsError(try manager.preview(association: unsupported, target: second))
        XCTAssertEqual(workspace.queries, [pdf.id])
        XCTAssertTrue(workspace.writes.isEmpty)
    }
    @MainActor func testSnapshotPreviewStillChecksConflictAndRemovedCandidateBeforeWrite() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let item = try manager.preview(association: manager.query(pdf), target: second)
        workspace.rows[pdf.id]?.application = third
        let conflict = await manager.apply([item])
        XCTAssertEqual(conflict.first?.outcome, .conflict)
        workspace.rows[pdf.id]?.application = first
        workspace.rows[pdf.id]?.candidates = [first]
        let unavailable = await manager.apply([item])
        XCTAssertEqual(unavailable.first?.outcome, .failed)
        XCTAssertTrue(workspace.writes.isEmpty)
    }
    @MainActor func testRestoreDoesNotOverwriteLaterChange() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let plan = try manager.preview(types: [pdf], target: second)
        let results = await manager.apply(plan)
        workspace.rows[pdf.id]?.application = third
        XCTAssertThrowsError(try manager.restorePreview(ChangeRecord(results: results)))
    }
    @MainActor func testCancelStopsRemainingItemsAndKeepsFirstResult() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let plan = try manager.preview(types: [pdf, jpeg], target: second)
        var stop = false
        let results = await manager.apply(plan, shouldStop: { stop }, onResult: { _ in stop = true })
        XCTAssertEqual(results.map(\.outcome), [.changed, .cancelled])
        XCTAssertEqual(workspace.writes, [pdf.id])
    }
    @MainActor func testAcceptedWriteIsNotSuccessWithoutVerification() async throws {
        let workspace = makeWorkspace(); workspace.ignoresWrites.insert(pdf.id)
        let manager = AssociationManager(workspace: workspace)
        let results = await manager.apply(try manager.preview(types: [pdf], target: second))
        XCTAssertEqual(results.first?.outcome, .unverified)
        XCTAssertEqual(results.first?.observed, first)
    }
    @MainActor func testQueryFailureAfterAcceptedWriteRemainsUnverified() async throws {
        let workspace = makeWorkspace(); workspace.failQueriesAfterWrite = true
        let manager = AssociationManager(workspace: workspace)
        let results = await manager.apply(try manager.preview(types: [pdf], target: second))
        XCTAssertEqual(results.first?.outcome, .unverified)
        XCTAssertEqual(workspace.rows[pdf.id]?.application, second)
        XCTAssertNotNil(results.first?.errorDetails)
    }
    @MainActor func testExecutionStagesFollowRealRequestAndReadback() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        var stages: [AssociationManager.ExecutionStage] = []
        let results = await manager.apply(try manager.preview(types: [pdf], target: second), onStage: { item, stage in
            XCTAssertEqual(item.type.id, self.pdf.id); stages.append(stage)
        })
        XCTAssertEqual(stages, [.checking, .requesting, .verifying])
        XCTAssertEqual(results.first?.outcome, .changed)
    }
    @MainActor func testUnavailableCandidateCannotBeSelectedOrWritten() async throws {
        let workspace = makeWorkspace(); workspace.rows[pdf.id]?.candidates = [first]
        let manager = AssociationManager(workspace: workspace)
        XCTAssertThrowsError(try manager.preview(types: [pdf], target: second))
        let plan = [ChangeItem(type: pdf, before: first, target: second)]
        let results = await manager.apply(plan)
        XCTAssertEqual(results.first?.outcome, .failed)
        XCTAssertTrue(workspace.writes.isEmpty)
    }
    @MainActor func testAlreadyDefaultIsNotRecordedAsChanged() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let results = await manager.apply(try manager.preview(types: [pdf], target: first))
        XCTAssertEqual(results.first?.outcome, .alreadyDefault)
        XCTAssertTrue(workspace.writes.isEmpty)
        XCTAssertThrowsError(try manager.restorePreview(ChangeRecord(results: results)))
    }
    @MainActor func testWrappedSystemCancellationIsReportedAsCancelled() async throws {
        let workspace = makeWorkspace()
        workspace.errors[pdf.id] = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)
        ])
        let manager = AssociationManager(workspace: workspace)
        let results = await manager.apply(try manager.preview(types: [pdf], target: second))
        XCTAssertEqual(results.first?.outcome, .cancelled)
        XCTAssertEqual(workspace.rows[pdf.id]?.application, first)
    }
    @MainActor func testRemovedCandidateAfterPreviewIsNotWritten() async throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let plan = try manager.preview(types: [pdf], target: second)
        workspace.rows[pdf.id]?.candidates = [first]
        let results = await manager.apply(plan)
        XCTAssertEqual(results.first?.outcome, .failed)
        XCTAssertTrue(workspace.writes.isEmpty)
    }
    @MainActor func testDifferentTypesSharingAnExtensionAreNotDeduplicated() throws {
        let workspace = makeWorkspace(); let manager = AssociationManager(workspace: workspace)
        let other = FileType(id: "test.other-pdf", name: "Other PDF", extensions: ["pdf"])
        workspace.rows[other.id] = Association(type: other, application: first, candidates: [first, second])
        let plan = try manager.preview(types: [pdf, other], target: second)
        XCTAssertEqual(plan.count, 2)
    }
    @MainActor func testOriginalNilCannotPromiseRestore() async throws {
        let workspace = makeWorkspace(); workspace.rows[pdf.id]?.application = nil
        let manager = AssociationManager(workspace: workspace)
        let results = await manager.apply(try manager.preview(types: [pdf], target: second))
        XCTAssertEqual(results.first?.outcome, .changed)
        XCTAssertThrowsError(try manager.restorePreview(ChangeRecord(results: results)))
    }
    func testCatalogUsesModernDeclarationsAndGroupsSharedExtensions() throws {
        let info: [String: Any] = ["CFBundleDocumentTypes": [
            ["LSItemContentTypes": ["public.jpeg"], "CFBundleTypeExtensions": ["wrong-legacy"]],
            ["CFBundleTypeExtensions": ["jpg", "jpeg"]]
        ]]
        let types = TypeCatalog.declaredTypes(in: info)
        XCTAssertEqual(types.filter { $0.id == "public.jpeg" }.count, 1)
        XCTAssertTrue(types.contains { $0.extensions.contains("jpg") && $0.extensions.contains("jpeg") })
        XCTAssertFalse(types.contains { $0.extensions.contains("wrong-legacy") })
        XCTAssertEqual(try TypeCatalog.normalizedExtension(" .PDF "), "pdf")
        XCTAssertThrowsError(try TypeCatalog.lookup("../../anything"))
        XCTAssertThrowsError(try TypeCatalog.lookup("*"))
    }
    func testHistoryPersistsResultsAndCapsRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.json"))
        let item = ChangeItem(type: pdf, before: first, target: second)
        let result = ChangeResult(item: item, outcome: .changed, message: "已验证", observed: second)
        try store.save((0..<35).map { _ in ChangeRecord(results: [result]) })
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 30)
        XCTAssertEqual(loaded.first?.results.first?.item.before, first)
        XCTAssertEqual(loaded.first?.results.first?.observed, second)
    }
}
