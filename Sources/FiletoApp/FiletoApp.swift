import SwiftUI
import AppKit
import FiletoCore

@main enum FiletoEntry {
    @MainActor static func main() {
        FiletoIcon.configureApplication()
        if CommandLine.arguments.dropFirst().first == "--ui-smoke" {
            UISmoke.launch(arguments: Array(CommandLine.arguments.dropFirst(2)))
        } else {
            FiletoApp.main()
        }
    }
}

struct FiletoApp: App {
    @NSApplicationDelegateAdaptor(FiletoApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Fileto") {
            ContentView(model: model)
                .background(MainWindowRegistration(register: { [weak model] window in model?.automaticRefresh.register(window) },
                                                   onClose: { [weak model] in model?.mainWindowClosed() }))
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.start() }
                .onAppear { applicationDelegate.operationInProgress = { [weak model] in model?.applying == true } }
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Fileto") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {}
            CommandGroup(after: .windowSize) {
                Button("切换全屏") {
                    NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandMenu("文件关联") {
                Button("刷新") { Task { await model.refresh() } }.keyboardShortcut("r")
                    .disabled(model.scanning || model.applying)
                Button("查询文件…") { model.openFile() }.keyboardShortcut("o")
                    .disabled(model.scanning || model.applying)
            }
        }
        Window("关于 Fileto", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
