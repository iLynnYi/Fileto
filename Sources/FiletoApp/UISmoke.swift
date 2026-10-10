import AppKit
import SwiftUI
import FiletoCore

// Runs the actual native views and AppModel against the host's system services.
// Writing is allowed only for the two disposable com.fileto.validation fixtures.
@MainActor enum UISmoke {
    static func launch(arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableAutomaticTermination("Fileto system integration validation")
        Task { @MainActor in await run(arguments: arguments) }
        app.run()
    }
    static func run(arguments: [String]) async {
        do {
            guard let output = arguments.first else { throw SmokeError.failed("需要截图输出目录") }
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("smoke-result.txt"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("stage.txt"))
            let model = AppModel(history: HistoryStore(url: directory.appendingPathComponent("smoke-history.json")),
                                 observesSystemLifecycle: false)
            let runtimeWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1160, height: 740),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
            runtimeWindow.isReleasedWhenClosed = false
            runtimeWindow.title = "Fileto 系统验证"
            runtimeWindow.contentView = NSHostingView(rootView: ContentView(model: model))
            runtimeWindow.orderBack(nil)
            runtimeWindow.makeMain()
            defer { runtimeWindow.contentView = nil; runtimeWindow.close() }
            await model.start()
            try require(model.associations.contains { $0.type.id == "com.adobe.pdf" && $0.application != nil }, "真实 PDF 默认应用没有解析成功")
            model.search = "pdf"
            try require(!model.visibleRows.isEmpty, "搜索没有结果")
            model.selectedTypes = ["com.adobe.pdf"]
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("files.png"), size: NSSize(width: 1160, height: 740))
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("files-dark.png"), size: NSSize(width: 1160, height: 740), colorScheme: .dark)
            model.showDetails(for: "com.adobe.pdf")
            try require(model.sheet == .details && model.detailRow?.id == "com.adobe.pdf", "详情弹窗未指向所选类型")
            try await capture(FileTypeDetail(model: model), to: directory.appendingPathComponent("details.png"), size: NSSize(width: 560, height: 480))
            try await capture(FileTypeDetail(model: model), to: directory.appendingPathComponent("details-dark.png"), size: NSSize(width: 560, height: 480), colorScheme: .dark)
            model.sheet = nil
            model.search = ""; model.sortByApplication = true; model.ascending = false
            try require(model.visibleRows.count == model.associations.count, "搜索清除后结果没有恢复")
            let applicationNames = model.visibleRows.compactMap { $0.application?.name }
            try require(zip(applicationNames, applicationNames.dropFirst()).allSatisfy {
                $0.localizedStandardCompare($1) != .orderedAscending
            }, "按应用降序未保持应用名称顺序")
            model.sortByApplication = false; model.ascending = true
            let ascendingTypes = model.visibleRows.map(\.id)
            model.ascending = false
            try require(model.visibleRows.map(\.id) == Array(ascendingTypes.reversed()), "扩展名升降序不一致")
            try require(model.indexedApplications.reduce(0) { $0 + model.count(for: $1) }
                        == model.associations.filter { $0.application != nil }.count, "应用默认类型数量缓存不一致")
            let pdfApp = model.associations.first { $0.type.id == "com.adobe.pdf" }!.application!
            model.applicationFilter = pdfApp.id
            try require(!model.visibleRows.isEmpty && model.visibleRows.allSatisfy { $0.application?.id == pdfApp.id }, "默认应用筛选没有正确收窄结果")
            model.applicationFilter = ""; model.onlyUnresolved = true
            try require(model.visibleRows.allSatisfy { $0.status != "已解析" }, "待确认筛选混入已解析项")
            model.onlyUnresolved = false; model.sortByApplication = true
            model.switchMode(.applications); model.selectApplication(pdfApp.id)
            try require(model.visibleRows.allSatisfy { $0.application?.id == pdfApp.id }, "反向默认查询混入非默认类型")
            model.appSearch = pdfApp.name
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("applications.png"), size: NSSize(width: 1160, height: 740))
            model.appSearch = ""
            model.showCandidates = true
            try require(model.visibleRows.allSatisfy { $0.candidates.contains { $0.id == pdfApp.id } }, "可打开范围错误")
            model.lookupExtension(".json")
            try require(model.mode == .files && !model.selectedTypes.isEmpty && model.focusedRow?.id == "public.json", "补充查询未正确切换视图和选择")
            // Render once before checking selection to catch view-driven selection resets.
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("lookup.png"), size: NSSize(width: 1160, height: 740))
            try require(model.focusedRow?.id == "public.json", "渲染后补充查询选择被清空")
            await model.beginChange()
            try require(!model.choices.isEmpty, "应用选择没有候选")
            if let current = model.focusedRow?.application {
                model.choice = current.id
                try require(!model.canContinue, "当前默认应用仍允许继续")
            }
            guard let alternative = model.choices.first(where: { model.currentCount($0) == 0 }) else {
                throw SmokeError.failed("当前 JSON 类型没有其他候选应用，无法验证单项选择预览")
            }
            model.choice = alternative.id
            try require(model.sheet == .chooser, "候选选择没有通过弹窗展示")
            try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("chooser.png"), size: NSSize(width: 600, height: 560))
            try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("chooser-dark.png"), size: NSSize(width: 600, height: 560), colorScheme: .dark)
            await model.prepareChange()
            try require(model.sheet == .chooser && !model.showingPreview && !model.plan.isEmpty, "单项预览未生成")
            model.cancelChoice()
            model.search = ""; model.selectedTypes = Set(model.visibleRows.prefix(5).map(\.id))
            try require(model.focusedRow == nil, "多选仍展示单项详情")
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("selection-compact.png"), size: NSSize(width: 960, height: 600))
            try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("selection-wide.png"), size: NSSize(width: 1440, height: 900))
            await model.beginChange()
            try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("batch-chooser.png"), size: NSSize(width: 600, height: 560))
            try await capture(SelectedTypesDetail(rows: model.changeRows, target: model.choiceTarget), to: directory.appendingPathComponent("selected-types.png"), size: NSSize(width: 900, height: 440))
            try await capture(SelectedTypesDetail(rows: model.changeRows, target: model.choiceTarget), to: directory.appendingPathComponent("selected-types-dark.png"), size: NSSize(width: 900, height: 440), colorScheme: .dark)
            if let app = model.choices.first {
                model.choice = app.id
                try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("batch-summary.png"), size: NSSize(width: 600, height: 560))
                try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("batch-summary-dark.png"), size: NSSize(width: 600, height: 560), colorScheme: .dark)
            }
            model.cancelChoice()
            try await testLargeBatchChooser(model: model, directory: directory)
            print("PASS：两个视图原生渲染、详情弹窗、搜索、升降序、筛选、应用数量缓存、默认/候选反向查询、补充查询与选择预览弹窗")
            if arguments.last == "--interactions" {
                runtimeWindow.center()
                runtimeWindow.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await testTableInteractions(model: model, window: runtimeWindow, directory: directory)
            }
            if arguments.count == 3 {
                // Keep the app's real window visible for human system consent.
                runtimeWindow.center()
                runtimeWindow.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await testFixtureUI(model: model, firstURL: URL(fileURLWithPath: arguments[1]), secondURL: URL(fileURLWithPath: arguments[2]), directory: directory)
            }
            print("UI screenshots: \(directory.path)")
            try Data("PASS\n".utf8).write(to: directory.appendingPathComponent("smoke-result.txt"), options: .atomic)
            exit(0)
        } catch {
            let nsError = error as NSError
            FileHandle.standardError.write(Data("UI smoke failed: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]\n".utf8))
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                FileHandle.standardError.write(Data("Underlying: \(underlying.domain):\(underlying.code)\n".utf8))
            }
            if let output = arguments.first {
                try? Data("FAIL: \(error.localizedDescription)\n".utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("smoke-result.txt"), options: .atomic)
            }
            exit(1)
        }
    }
    // Query every discovered type and prepare a preview, then cancel without writing.
    private static func testLargeBatchChooser(model: AppModel, directory: URL) async throws {
        model.switchMode(.files); model.search = ""; model.applicationFilter = ""; model.onlyUnresolved = false
        model.selectedTypes = Set(model.associations.map(\.id))
        let count = model.selectedTypes.count
        let start = Date()
        await model.beginChange()
        let chooserSeconds = Date().timeIntervalSince(start)
        try require(!model.loadingChoices && model.hasCompleteChoiceSnapshot && model.changeRows.count == count,
                    "完整批量候选查询没有完成")
        try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("large-batch-chooser.png"), size: NSSize(width: 600, height: 560))
        try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("large-batch-chooser-dark.png"), size: NSSize(width: 600, height: 560), colorScheme: .dark)
        guard let target = model.choices.first(where: { app in
            model.choice = app.id
            return model.canContinue
        }) else { throw SmokeError.failed("完整批量没有可准备预览的候选应用") }
        model.choice = target.id
        let previewStart = Date()
        await model.prepareChange()
        let previewSeconds = Date().timeIntervalSince(previewStart)
        try require(model.sheet == .chooser && !model.showingPreview && model.plan.count + model.skipped.count == count,
                    "完整批量预览没有保留所有类型和跳过项")
        let result = "types=\(count)\nchooser_seconds=\(chooserSeconds)\npreview_seconds=\(previewSeconds)\nplanned=\(model.plan.count)\nskipped=\(model.skipped.count)\nsystem_writes=0\n"
        try Data(result.utf8).write(to: directory.appendingPathComponent("batch-performance.txt"), options: .atomic)
        model.cancelChoice()
        print("PASS：\(count) 个真实类型批量候选查询与预览（无系统写入），查询 \(chooserSeconds)s，预览 \(previewSeconds)s")
    }
    // Exercise public native control actions and accessibility on the visible test window.
    // This path only prepares/cancels previews; it never calls execute or a workspace write.
    private static func testTableInteractions(model: AppModel, window: NSWindow, directory: URL) async throws {
        func stage(_ value: String) throws {
            try Data(value.utf8).write(to: directory.appendingPathComponent("stage.txt"), options: .atomic)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func table() throws -> NSTableView {
            guard let content = window.contentView,
                  let table = descendants(content).compactMap({ $0 as? NSTableView }).first(where: { $0.tableColumns.count == 3 }) else {
                throw SmokeError.failed("没有找到原生类型表格")
            }
            return table
        }
        func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<50 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func escape() throws {
            guard let sheet = window.attachedSheet,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                                              context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                throw SmokeError.failed("没有实际原生弹窗可关闭")
            }
            sheet.sendEvent(event)
        }
        for mode in AppModel.Mode.allCases {
            model.switchMode(mode); model.sortByApplication = false; model.ascending = true
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            model.search = "pdf"
            if mode == .applications {
                guard let sidebar = model.indexedApplications.first(where: { app in
                    model.associations.filter { ($0.type.name.lowercased().contains("pdf") || $0.type.extensionLabel.contains("pdf"))
                        && $0.candidates.contains(where: { $0.id == app.id }) }.count >= 3
                }) else { throw SmokeError.failed("应用视图没有覆盖三个 PDF 类型的系统候选") }
                model.selectApplication(sidebar.id); model.showCandidates = true
            }
            try await settle()
            let types = model.visibleRows.map(\.id)
            try require(types.count >= 3, "原生多选验证需要至少三个 PDF 查询结果")
            let nativeTable = try table()
            window.contentView?.layoutSubtreeIfNeeded()
            for _ in 0..<20 {
                if nativeTable.numberOfRows == types.count && nativeTable.rowView(atRow: 0, makeIfNecessary: false) != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try stage("只读交互：原生表格选择")
            nativeTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try await waitUntil { model.selectedTypes == [types[0]] }
            try require(model.selectedTypes == [types[0]], "原生表格选择没有同步到界面状态")
            nativeTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: true)
            try await waitUntil { model.selectedTypes == [types[0], types[1]] }
            try require(model.selectedTypes == [types[0], types[1]], "原生表格多选没有同步到界面状态")
            nativeTable.selectRowIndexes(IndexSet(integersIn: 1...2), byExtendingSelection: false)
            try await waitUntil { model.selectedTypes == [types[1], types[2]] }
            try require(model.selectedTypes == [types[1], types[2]], "原生表格连续选择没有同步到界面状态")
            try stage("只读交互：详情动作与 Escape")
            nativeTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try require(nativeTable.doubleAction != nil, "原生表格没有双击动作入口")
            // Synthetic pointer coordinates can be disrupted by window focus changes.
            // Check the registered Table action, then verify native presentation directly.
            model.showDetails(for: types[0])
            try await waitUntil { model.sheet == .details && window.attachedSheet != nil }
            try require(model.sheet == .details && model.detailRow?.id == types[0] && window.attachedSheet != nil, "详情动作没有打开对应类型的原生弹窗（状态=\(String(describing: model.sheet))，类型=\(model.detailRow?.id ?? "nil")，原生弹窗=\(window.attachedSheet != nil)）")
            try escape(); try await waitUntil { model.sheet == nil && window.attachedSheet == nil }
            try require(model.sheet == nil && window.attachedSheet == nil, "Escape 没有关闭详情弹窗")

            // Find the actual native popup backing SwiftUI.Menu, rather than invoking model methods.
            guard let row = model.visibleRows.first(where: { $0.id == "com.adobe.pdf" }),
                  let index = model.visibleRows.firstIndex(where: { $0.id == row.id }) else {
                throw SmokeError.failed("没有找到默认应用单元格的原生菜单")
            }
            try stage("只读交互：默认应用菜单")
            var renderedMenu: NSMenu?
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await settle()
                // SwiftUI may replace native controls after an appearance change.
                let themedTable = try table()
                themedTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                try await settle()
                guard let themedCell = themedTable.view(atColumn: 2, row: index, makeIfNecessary: true),
                      let themedPopup = descendants(themedCell).compactMap({ $0 as? NSPopUpButton }).first,
                      let content = window.contentView else { throw SmokeError.failed("主题切换后缺少原生菜单") }
                let closer = MenuCloser(button: themedPopup, view: content)
                let prefix = "\(mode == .files ? "files" : "applications")-menu-\(theme)"
                try nativeSnapshot(content).write(to: directory.appendingPathComponent(prefix + "-before.png"))
                closer.captureURL = directory.appendingPathComponent(prefix + "-pressed.png")
                let timer = Timer(timeInterval: 0.2, target: closer, selector: #selector(MenuCloser.close(_:)), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
                themedPopup.performClick(nil)
                timer.invalidate()
                if let error = closer.captureError { throw error }
                try require(closer.menu != nil && FileManager.default.fileExists(atPath: closer.captureURL!.path), "原生菜单未展开或缺少按下状态截图")
                renderedMenu = closer.menu
            }
            try await settle()
            guard let menu = renderedMenu else { throw SmokeError.failed("原生应用菜单未展开") }
            let items = menu.items.flatMap { $0.submenu?.items ?? [$0] }
            try require(items.contains { $0.state == .on && $0.title.contains("当前默认") }, "原生菜单没有勾选当前默认应用")
            try require(items.contains { $0.title == "其他应用…" }, "原生菜单缺少其他应用入口")
            guard let target = row.candidates.first(where: { $0.id != row.application?.id }),
                  let item = items.first(where: { $0.title == target.name }) else {
                throw SmokeError.failed("没有可验证的原生候选菜单项")
            }
            try require(item.image != nil, "原生候选应用菜单没有应用图标")
            // Candidate selection now submits a write. Read-only checks inspect the
            // menu without activating candidates for everyday file types.
            try require(model.sheet == nil && model.records.isEmpty, "只读菜单检查意外开始修改")

            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await settle()
            let batchTable = try table()
            batchTable.selectRowIndexes(IndexSet(integersIn: 0...1), byExtendingSelection: false)
            try await waitUntil { model.selectedTypes == Set(types.prefix(2)) }
            try await settle()
            try stage("只读交互：\(mode.rawValue)视图批量选择弹窗")
            // SwiftUI virtual nodes expose the public Objective-C accessibility methods
            // without necessarily declaring formal NSAccessibilityProtocol conformance.
            func accessibilityElements(_ node: Any) -> [NSObject] {
                guard let object = node as? NSObject else { return [] }
                let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
                let children = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? [Any] : nil
                return [object] + (children ?? []).flatMap(accessibilityElements)
            }
            func value(_ object: NSObject, _ selector: Selector) -> String? {
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue() as? String
            }
            func batchButton() -> NSObject? {
                (window.contentView.map { descendants($0).flatMap(accessibilityElements) } ?? []).first {
                    value($0, #selector(NSAccessibilityProtocol.accessibilityRole)) == "AXButton"
                    && (value($0, #selector(NSAccessibilityProtocol.accessibilityLabel)) == "更改 2 个类型…"
                        || value($0, #selector(NSAccessibilityProtocol.accessibilityTitle)) == "更改 2 个类型…")
                }
            }
            try await waitUntil { batchButton() != nil }
            guard let batch = batchButton() else {
                let nodes = (window.contentView.map { descendants($0).flatMap(accessibilityElements) } ?? []).map {
                    [value($0, #selector(NSAccessibilityProtocol.accessibilityRole)),
                     value($0, #selector(NSAccessibilityProtocol.accessibilityLabel)),
                     value($0, #selector(NSAccessibilityProtocol.accessibilityTitle))].compactMap { $0 }.joined(separator: " | ")
                }.joined(separator: "\n")
                try Data(nodes.utf8).write(to: directory.appendingPathComponent("accessibility.txt"))
                if let content = window.contentView { try nativeSnapshot(content).write(to: directory.appendingPathComponent("batch-button.png")) }
                throw SmokeError.failed("多选后没有可访问的批量按钮（选中 \(model.selectedTypes.count)，可见选中 \(model.chosenRows.count)，弹窗 \(String(describing: model.sheet))）")
            }
            let pressSelector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
            guard batch.responds(to: pressSelector), let implementation = batch.method(for: pressSelector) else {
                throw SmokeError.failed("批量按钮没有辅助功能操作入口")
            }
            let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            try require(press(batch, pressSelector), "批量按钮没有执行辅助功能动作")
            try await waitUntil { model.sheet == .chooser && window.attachedSheet != nil && !model.loadingChoices }
            try require(model.sheet == .chooser && window.attachedSheet != nil, "批量按钮没有打开候选选择弹窗")
            guard let chooserSheet = window.attachedSheet else { throw SmokeError.failed("缺少候选弹窗") }
            let selected = model.choices.first!
            model.choice = selected.id
            try await settle()
            let selectionButton = chooserSheet.contentView.map { descendants($0).flatMap(accessibilityElements) }?.first {
                value($0, #selector(NSAccessibilityProtocol.accessibilityRole)) == "AXButton"
                && (value($0, #selector(NSAccessibilityProtocol.accessibilityLabel)) == "查看所选类型（2）…"
                    || value($0, #selector(NSAccessibilityProtocol.accessibilityTitle)) == "查看所选类型（2）…")
            }
            guard let selectionButton, let selectionImplementation = selectionButton.method(for: pressSelector) else {
                throw SmokeError.failed("缺少所选类型明细入口")
            }
            let selectionPress = unsafeBitCast(selectionImplementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            try require(selectionPress(selectionButton, pressSelector), "所选类型明细没有打开")
            try await waitUntil { chooserSheet.attachedSheet != nil }
            guard let selectionSheet = chooserSheet.attachedSheet, let detailContent = selectionSheet.contentView,
                  let detailTable = descendants(detailContent).compactMap({ $0 as? NSTableView }).first else {
                throw SmokeError.failed("没有打开独立的原生所选类型表格")
            }
            try require(detailTable.tableColumns.count == 4 && detailTable.numberOfRows == 2, "所选类型明细列或行数不正确")
            try await capture(SelectedTypesDetail(rows: model.changeRows, target: model.choiceTarget), to: directory.appendingPathComponent("native-selected-types.png"), size: NSSize(width: 900, height: 440))
            guard let escapeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: selectionSheet.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                throw SmokeError.failed("无法创建关闭明细的键盘事件")
            }
            selectionSheet.sendEvent(escapeEvent)
            try await waitUntil { chooserSheet.attachedSheet == nil }
            try require(chooserSheet.attachedSheet == nil && model.sheet == .chooser && model.choosingApplication
                        && model.choice == selected.id, "关闭明细没有保留候选弹窗或已选应用")
            try escape(); try await waitUntil { model.sheet == nil && window.attachedSheet == nil }
            try require(model.sheet == nil && !model.choosingApplication, "取消批量弹窗后仍处于选择状态")
            print("PASS：\(mode.rawValue)视图原生表格选择、详情动作、Escape、默认应用菜单勾选与图标、批量选择弹窗（无系统写入）")
        }
    }
    @MainActor private final class MenuCloser: NSObject {
        let button: NSPopUpButton
        let view: NSView
        var menu: NSMenu?
        var captureURL: URL?
        var captureError: Error?
        init(button: NSPopUpButton, view: NSView) { self.button = button; self.view = view }
        @objc func close(_ timer: Timer) {
            menu = button.menu
            do { if let captureURL { try UISmoke.nativeSnapshot(view).write(to: captureURL) } }
            catch { captureError = error }
            menu?.cancelTracking()
        }
    }
    private static func testFixtureUI(model: AppModel, firstURL: URL, secondURL: URL, directory: URL) async throws {
        guard let first = Application.read(at: firstURL), let second = Application.read(at: secondURL),
              first.bundleID == "com.fileto.validation.first", second.bundleID == "com.fileto.validation.second" else {
            throw SmokeError.failed("拒绝使用非临时测试应用")
        }
        for ext in ["filetovalidationone", "filetovalidationtwo"] { model.lookupExtension(ext) }
        let types = model.associations.filter { $0.type.id.hasPrefix("com.fileto.validation.") }
        try require(types.count == 2, "未发现两个测试类型")
        let workspace = SystemWorkspace()
        func stage(_ message: String) throws {
            try Data(message.utf8).write(to: directory.appendingPathComponent("stage.txt"), options: .atomic)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.environment = ["FILETO_FIXTURE_OUTPUT": directory.path]
        var fixtureProcesses: [NSRunningApplication] = []
        defer { for application in fixtureProcesses { application.terminate() } }
        for url in [firstURL, secondURL] {
            try stage("启动测试应用：\(url.lastPathComponent)")
            fixtureProcesses.append(try await NSWorkspace.shared.openApplication(at: url, configuration: configuration))
        }
        let appIsActive = NSApplication.shared.isActive
        let mainIsVisible = NSApplication.shared.mainWindow?.isVisible == true
        let mainHasScreen = NSApplication.shared.mainWindow?.screen != nil
        try stage("设置测试基线：First（调用者激活=\(appIsActive)，主窗口可见=\(mainIsVisible)，位于屏幕=\(mainHasScreen)）")
        try require(appIsActive && mainIsVisible && mainHasScreen, "系统验证调用者没有在屏幕上激活；未发起默认应用更改")
        for row in types { try await workspace.setDefault(first, for: row.type) }
        await model.refresh()
        // Exercise direct row-menu submission only with the isolated fixture type.
        model.lookupExtension("filetovalidationone")
        guard let singleRow = model.focusedRow else { throw SmokeError.failed("没有找到单项测试类型") }
        try stage("单项直接修改：First → Second")
        await model.changeDefault(for: singleRow.id, to: second)
        try require(model.latestResults.count == 1 && model.latestResults.first?.outcome == .changed, "真实界面单项更改未生效：\(model.latestResults.first?.message ?? "没有结果")")
        try require(model.sheet == nil && model.message?.title == "已修改并验证", "单项成功仍弹窗或缺少成功提示")
        try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("single-success.png"), size: NSSize(width: 1160, height: 740))
        guard let singleRecord = model.records.first else { throw SmokeError.failed("单项更改没有记录") }
        model.prepareRestore(singleRecord)
        try require(model.plan.count == 1, "单项恢复预览不完整")
        try await Task.sleep(nanoseconds: 500_000_000)
        try stage("单项恢复：Second → First")
        await model.execute()
        try require(model.latestResults.first?.outcome == .changed, "单项恢复未生效")
        model.showingResults = false
        model.search = "filetovalidation"; model.selectedTypes = Set(types.map(\.id))
        await model.beginChange(); model.choice = second.id; await model.prepareChange()
        try require(model.plan.count == 2 && model.skipped.isEmpty, "批量预览不完整")
        try await capture(ChangeChooser(model: model), to: directory.appendingPathComponent("batch-chooser.png"), size: NSSize(width: 600, height: 560))
        try await Task.sleep(nanoseconds: 500_000_000)
        try stage("批量修改：First → Second")
        await model.execute()
        try require(model.latestResults.count == 2 && model.latestResults.allSatisfy { $0.outcome == .changed }, "真实界面批量执行没有全部验证成功")
        try await capture(ChangeResultsView(model: model), to: directory.appendingPathComponent("batch-results.png"), size: NSSize(width: 680, height: 500))
        model.showingResults = false
        model.switchMode(.applications); model.selectApplication(second.id)
        try require(Set(model.visibleRows.map(\.id)).isSuperset(of: Set(types.map(\.id))), "批量操作后反向索引没有更新")
        guard let record = model.records.first else { throw SmokeError.failed("没有保存操作记录") }
        try await capture(HistoryView(model: model), to: directory.appendingPathComponent("history.png"), size: NSSize(width: 720, height: 540))
        model.prepareRestore(record)
        try require(model.plan.count == 2 && model.plan.allSatisfy { $0.target.id == first.id }, "恢复预览没有保留原应用")
        try await capture(ChangePreview(model: model), to: directory.appendingPathComponent("restore-preview.png"), size: NSSize(width: 650, height: 500))
        try await Task.sleep(nanoseconds: 500_000_000)
        try stage("批量恢复：Second → First")
        await model.execute()
        try require(model.latestResults.allSatisfy { $0.outcome == .changed }, "真实界面恢复未生效")
        model.showingResults = false
        let file = directory.appendingPathComponent("sample.filetovalidationone")
        try Data("Fileto isolated validation\n".utf8).write(to: file)
        model.inspectFile(file)
        try require(model.inspection?.effectiveApplication?.id == first.id && model.focusedRow?.application?.id == first.id, "文件检查与恢复结果不同")
        configuration.createsNewApplicationInstance = false
        try stage("通过系统默认应用打开样本文件")
        let opened = try await NSWorkspace.shared.open(file, configuration: configuration)
        try require(opened.bundleIdentifier == first.bundleID, "实际打开文件应用不一致：\(opened.bundleIdentifier ?? "无应用标识")，预期 \(first.bundleID)")
        let marker = directory.appendingPathComponent("First.opened.json")
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let deliveredPaths = try JSONDecoder().decode([String].self, from: Data(contentsOf: marker))
        let expectedFile = file.resolvingSymlinksInPath().standardizedFileURL
        try require(deliveredPaths.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == expectedFile
        }, "临时应用没有收到实际文件打开事件")
        try await capture(ContentView(model: model, presentsSheets: false), to: directory.appendingPathComponent("file-inspection.png"), size: NSSize(width: 1160, height: 740))
        let store = HistoryStore(url: directory.appendingPathComponent("smoke-history.json"))
        try require(try store.load().count == 4, "操作记录未持久化")
        print("PASS：真实 AppModel 单项与批量预览 → 设置 → 验证 → 反向索引更新 → 记录 → 恢复 → 文件打开事件")
    }
    private static func capture<V: View>(_ view: V, to url: URL, size: NSSize, colorScheme: ColorScheme = .light) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, colorScheme))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        // SwiftUI's layer-backed text/buttons commit on the next run-loop iteration.
        try await Task.sleep(nanoseconds: 100_000_000)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        try nativeSnapshot(hosting).write(to: url)
        // Windows remain offscreen; this tests app rendering without changing the user's foreground app.
        window.contentView = nil
        window.close()
    }
    private static func nativeSnapshot(_ view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SmokeError.failed("无法创建界面截图") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
            context.concatenate(context.ctm.inverted())
            view.window?.appearance?.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            }
            context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
            context.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: -CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            layer.render(in: context)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.failed("无法编码界面截图") }
        return data
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeError.failed(message) }
    }
    private enum SmokeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
