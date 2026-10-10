import XCTest
import Combine
@testable import FiletoCore
@testable import FiletoApp

@MainActor private final class BatchWorkspace: WorkspaceAccess {
    var rows: [String: Association] = [:]
    var queries: [String] = []
    func association(for type: FileType) throws -> Association {
        queries.append(type.id)
        return rows[type.id]!
    }
    func setDefault(_ application: Application, for type: FileType) async throws {
        XCTFail("Performance checks must not write system associations")
    }
}

@MainActor final class BatchPerformanceTests: XCTestCase {
    func testLargeBatchPublishesOnceAndPreparesDisplayedSnapshotWithoutRequery() async {
        let count = 1025
        let workspace = BatchWorkspace()
        let apps = (0..<20).map { Application(url: URL(fileURLWithPath: "/Diagnostic\($0).app"), bundleID: "test.\($0)", name: "Diagnostic \($0)") }
        let rows = (0..<count).map { index in
            Association(type: FileType(id: "test.type\(index)", name: "Type \(index)", extensions: ["t\(index)"]), application: apps[0], candidates: apps)
        }
        workspace.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(history: HistoryStore(url: directory.appendingPathComponent("history.json")), workspace: workspace, observesSystemLifecycle: false)
        defer { model.automaticRefresh.stop() }
        model.associations = rows; model.applications = apps
        model.selectedTypes = Set(rows.map(\.id))
        for row in rows { workspace.rows[row.id]?.application = apps[2] }
        var updates = 0
        let observer = model.$associations.dropFirst().sink { _ in updates += 1 }
        defer { observer.cancel() }
        let started = Date()
        await model.beginChange()
        let chooserSeconds = Date().timeIntervalSince(started)
        let choiceStarted = Date()
        for _ in 0..<20 { _ = model.choices }
        print("PERF n=\(count) chooser=\(chooserSeconds)s queries=\(workspace.queries.count) associationUpdates=\(updates) choices20=\(Date().timeIntervalSince(choiceStarted))s")
        XCTAssertEqual(updates, 1, "Publish the complete batch once to avoid rebuilding the application index per type")
        XCTAssertEqual(workspace.queries.count, count)
        XCTAssertEqual(model.count(for: apps[2]), count)
        XCTAssertEqual(model.currentCount(apps[2]), count)
        XCTAssertEqual(model.coverage(apps[1]), count)
        XCTAssertEqual(Set(model.changeRows.map(\.id)), model.selectedTypes)
        workspace.queries = []; updates = 0
        model.choice = apps[1].id
        for row in rows { workspace.rows[row.id]?.application = apps[3] }
        let previewStarted = Date()
        await model.prepareChange()
        print("PERF preview n=\(count) seconds=\(Date().timeIntervalSince(previewStarted)) queries=\(workspace.queries.count) associationUpdates=\(updates)")
        XCTAssertEqual(workspace.queries.count, 0, "Preparation uses the displayed snapshot; execution rechecks the system")
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(model.plan.count, count)
        XCTAssertEqual(model.plan.map(\.id), model.changeRows.map(\.id))
        XCTAssertTrue(model.plan.allSatisfy { $0.before == apps[2] && $0.target == apps[1] })
        XCTAssertEqual(model.count(for: apps[2]), count)
    }
}
