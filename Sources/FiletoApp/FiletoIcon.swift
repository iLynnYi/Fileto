import AppKit

@MainActor enum FiletoIcon {
    static let image: NSImage? = {
        let applicationURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        #if SWIFT_PACKAGE
        let iconURL = applicationURL ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        #else
        let iconURL = applicationURL
        #endif
        guard let url = iconURL else { return nil }
        return NSImage(contentsOf: url)
    }()

    static func configureApplication() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let image {
            NSApplication.shared.applicationIconImage = image
        }
    }
}

@MainActor final class FiletoApplicationDelegate: NSObject, NSApplicationDelegate {
    var operationInProgress: () -> Bool = { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard operationInProgress() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "默认应用修改仍在进行"
        alert.informativeText = "请先完成或取消 macOS 系统提示。可在 Fileto 中停止后续修改，等待当前项结束并保存结果后再退出。"
        alert.addButton(withTitle: "继续等待")
        alert.runModal()
        return .terminateCancel
    }
    private var menuObserver: NSObjectProtocol?
    private var menuCleanupScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        FiletoIcon.configureApplication()
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            Task { @MainActor [weak self] in
                guard menu === NSApp.mainMenu else { return }
                self?.scheduleMenuCleanup()
            }
        }
        scheduleMenuCleanup()
    }

    private func scheduleMenuCleanup() {
        guard !menuCleanupScheduled else { return }
        menuCleanupScheduled = true
        // SwiftUI finishes populating menus before we remove their empty containers.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuCleanupScheduled = false
            self.removeUnusedMenus()
        }
    }

    private func removeUnusedMenus() {
        guard let menu = NSApp.mainMenu else { return }
        if let helpMenu = NSApp.helpMenu {
            if let item = menu.items.first(where: { $0.submenu === helpMenu }) {
                menu.removeItem(item)
            }
            NSApp.helpMenu = nil
        }
        // An empty View menu can retain a separator. Avoid matching localized titles.
        for item in menu.items.dropFirst() {
            guard let submenu = item.submenu,
                  submenu !== NSApp.windowsMenu,
                  submenu.items.allSatisfy(\.isSeparatorItem) else { continue }
            menu.removeItem(item)
        }
    }
}
