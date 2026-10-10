import AppKit
import UniformTypeIdentifiers
import OSLog

@MainActor public protocol WorkspaceAccess {
    func association(for type: FileType) throws -> Association
    func setDefault(_ application: Application, for type: FileType) async throws
}

@MainActor public final class SystemWorkspace: WorkspaceAccess {
    private var pendingRequests = Set<UUID>()
    private let logger = Logger(subsystem: "com.fileto.app", category: "DefaultApplication")
    public init() {}
    public func association(for type: FileType) throws -> Association {
        guard let contentType = UTType(type.id) else { throw FiletoError.unknownType(type.id) }
        let workspace = NSWorkspace.shared
        let current = workspace.urlForApplication(toOpen: contentType).flatMap(Application.read)
        var seen = Set<String>()
        let candidates = workspace.urlsForApplications(toOpen: contentType).compactMap(Application.read).filter {
            seen.insert($0.id).inserted
        }
        return Association(type: type, application: current, candidates: candidates)
    }
    public func setDefault(_ application: Application, for type: FileType) async throws {
        logger.notice("Request started: type=\(type.id, privacy: .public), active=\(NSApplication.shared.isActive), sheet=\(NSApplication.shared.mainWindow?.attachedSheet != nil)")
        guard let contentType = UTType(type.id) else { throw FiletoError.unknownType(type.id) }
        guard Application.read(at: application.url)?.bundleID == application.bundleID else {
            throw FiletoError.unavailableApplication
        }
        let request = UUID()
        let requestLogger = logger
        pendingRequests.insert(request)
        // The confirmation is owned by a separate system agent. It may open
        // behind the requesting app; bring it forward without answering it.
        let consentFocus = Task { @MainActor in
            // Consent can arrive after the system agent has queued earlier work.
            // Limit foreground assistance to 30 seconds; cancellation/completion
            // removes the request immediately and ends this task.
            for _ in 0..<75 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.pendingRequests.contains(request) else { return }
                if let agent = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == "com.apple.coreservices.uiagent"
                }) {
                    agent.activate(options: [.activateAllWindows])
                }
            }
        }
        defer { pendingRequests.remove(request); consentFocus.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: application.url, toOpen: contentType) { error in
                if let error {
                    let nsError = error as NSError
                    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                    requestLogger.notice("Request completed: type=\(type.id, privacy: .public), error=\(nsError.domain, privacy: .public):\(nsError.code), underlying=\(underlying?.code ?? 0)")
                } else {
                    requestLogger.notice("Request completed: type=\(type.id, privacy: .public), success")
                }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            logger.notice("Request submitted: type=\(type.id, privacy: .public)")
        }
    }
    public func inspect(_ url: URL) throws -> FileInspection {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isPackageKey])
        guard values.isRegularFile == true || values.isPackage == true, let type = values.contentType else {
            throw FiletoError.unknownType(url.lastPathComponent)
        }
        return FileInspection(url: url, type: TypeCatalog.describe(type),
                              effectiveApplication: NSWorkspace.shared.urlForApplication(toOpen: url).flatMap(Application.read))
    }
}
