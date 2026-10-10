import AppKit
import SwiftUI

// Owns one observer set and one refresh task for all of the app's main windows.
@MainActor final class AutomaticRefresh {
    enum Scope { case associations, catalog }
    private let canRefresh: () -> Bool
    private let refresh: (Scope) async -> Bool
    private let delay: UInt64
    private let interval: TimeInterval
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var timer: Timer?
    private var pending: Scope?
    private var available = false
    private var sleeping = false
    private var observing = false
    private(set) var task: Task<Void, Never>?

    init(delay: UInt64 = 1_000_000_000, interval: TimeInterval = 30,
         canRefresh: @escaping () -> Bool, refresh: @escaping (Scope) async -> Bool) {
        self.delay = delay; self.interval = interval
        self.canRefresh = canRefresh; self.refresh = refresh
    }
    var canRun: Bool { available && canRefresh() }

    func start() {
        guard !observing else { return }
        observing = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observe(name, in: .default) { [weak self] in self?.updateAvailability() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, in: workspaceCenter) { [weak self] in
            self?.sleeping = true; self?.updateAvailability()
        }
        observe(NSWorkspace.didWakeNotification, in: workspaceCenter) { [weak self] in
            self?.sleeping = false; self?.updateAvailability()
            self?.request(.catalog)
        }
        observe(NSApplication.willTerminateNotification, in: .default) { [weak self] in self?.stop() }
        updateAvailability()
    }
    private func observe(_ name: Notification.Name, in center: NotificationCenter, action: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, observer))
    }
    func register(_ window: NSWindow) {
        windows.add(window)
        updateAvailability()
    }
    private func updateAvailability() {
        setAvailable(!sleeping && NSApp.isActive && !NSApp.isHidden && windows.allObjects.contains {
            $0.isVisible && !$0.isMiniaturized
        })
    }
    func setAvailable(_ value: Bool) {
        let becameAvailable = value && !available
        available = value
        if becameAvailable { request(.catalog) }
        stateChanged()
    }
    func request(_ scope: Scope) {
        if pending != .catalog { pending = scope }
        stateChanged()
    }
    func stateChanged() {
        guard canRun else {
            timer?.invalidate(); timer = nil
            task?.cancel()
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.request(.associations) }
            }
        }
        guard pending != nil, task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.delay) }
            catch { self.task = nil; self.stateChanged(); return }
            guard self.canRun, let scope = self.pending else {
                self.task = nil; self.stateChanged(); return
            }
            self.pending = nil
            if !(await self.refresh(scope)), self.pending != .catalog { self.pending = scope }
            self.task = nil
            self.stateChanged()
        }
    }
    // Explicit refreshes await the cancelled worker before taking ownership.
    func suspend() async {
        task?.cancel()
        await task?.value
        pending = nil
    }
    func stop() {
        available = false; pending = nil
        timer?.invalidate(); timer = nil; task?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []; observing = false
    }
    deinit {
        timer?.invalidate(); task?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}

// Register the actual content window; the About window must not enable polling.
struct MainWindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    var onClose: () -> Void = {}
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(register: register, onClose: onClose) }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}
    final class RegistrationView: NSView {
        private let register: (NSWindow) -> Void
        private let onClose: () -> Void
        private var closeObserver: NSObjectProtocol?
        init(register: @escaping (NSWindow) -> Void, onClose: @escaping () -> Void) {
            self.register = register; self.onClose = onClose; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
            if let window {
                register(window)
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
            }
        }
        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
}
