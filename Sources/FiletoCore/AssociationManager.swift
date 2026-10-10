import Foundation

@MainActor public final class AssociationManager {
    public enum ExecutionStage: Sendable { case checking, requesting, verifying }
    private let workspace: any WorkspaceAccess
    public init(workspace: any WorkspaceAccess) { self.workspace = workspace }
    public func query(_ type: FileType) throws -> Association { try workspace.association(for: type) }
    public func preview(types: [FileType], target: Application) throws -> [ChangeItem] {
        var seen = Set<String>()
        return try types.filter { seen.insert($0.id).inserted }.map { type in
            try preview(association: query(type), target: target)
        }
    }
    // Use the caller's fresh query for both support checking and the before snapshot.
    // apply still re-queries before submitting any system request.
    public func preview(association: Association, target: Application) throws -> ChangeItem {
        guard association.candidates.contains(where: { $0.id == target.id }) else {
            throw FiletoError.unsupportedApplication(association.type.extensionLabel)
        }
        return ChangeItem(type: association.type, before: association.application, target: target)
    }
    public func apply(_ plan: [ChangeItem], shouldStop: () -> Bool = { false },
                      onStage: (ChangeItem, ExecutionStage) -> Void = { _, _ in },
                      onQuery: (FileType, Result<Association, Error>) -> Void = { _, _ in },
                      onResult: (ChangeResult) -> Void = { _ in }) async -> [ChangeResult] {
        var results: [ChangeResult] = []
        for item in plan {
            let result: ChangeResult
            if shouldStop() {
                result = ChangeResult(item: item, outcome: .cancelled, message: "已停止后续修改，此项未执行。", observed: nil)
            } else {
                result = await execute(item, onStage: onStage, onQuery: onQuery)
            }
            results.append(result); onResult(result)
        }
        return results
    }
    private func execute(_ item: ChangeItem, onStage: (ChangeItem, ExecutionStage) -> Void,
                         onQuery: (FileType, Result<Association, Error>) -> Void) async -> ChangeResult {
        // Share the actual preflight/readback snapshots without adding queries or
        // changing the persisted operation result. A failure preserves the last value.
        func queryCurrent() throws -> Association {
            do {
                let row = try query(item.type)
                onQuery(item.type, .success(row))
                return row
            } catch {
                onQuery(item.type, .failure(error))
                throw error
            }
        }
        var observed: Application?
        var accepted = false
        do {
            onStage(item, .checking)
            let latest = try queryCurrent()
            observed = latest.application
            if latest.application?.id == item.target.id {
                return ChangeResult(item: item, outcome: .alreadyDefault, message: "无需重复设置。", observed: observed)
            }
            guard latest.application?.id == item.before?.id else {
                return ChangeResult(item: item, outcome: .conflict, message: "默认应用在预览后发生变化，请重新预览。", observed: observed)
            }
            guard latest.candidates.contains(where: { $0.id == item.target.id }) else {
                throw FiletoError.unsupportedApplication(item.type.extensionLabel)
            }
            onStage(item, .requesting)
            try await workspace.setDefault(item.target, for: item.type)
            accepted = true
            onStage(item, .verifying)
            for attempt in 0..<6 {
                observed = try queryCurrent().application
                if observed?.id == item.target.id {
                    return ChangeResult(item: item, outcome: .changed, message: "系统查询结果已确认。", observed: observed)
                }
                if attempt < 5 { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            return ChangeResult(item: item, outcome: .unverified, message: "系统接受了设置，但重新查询尚未得到目标应用；请刷新检查。", observed: observed)
        } catch {
            let nsError = error as NSError
            if accepted {
                return ChangeResult(item: item, outcome: .unverified,
                                    message: "系统已接受设置，但无法完成查询验证。请刷新核对后再操作。", observed: observed,
                                    errorDetails: Self.describeError(nsError))
            }
            // A rejected/cancelled request does not prove that the association is unchanged.
            if let latest = try? queryCurrent() { observed = latest.application }
            let cancelled = Self.isCancellation(nsError)
            return ChangeResult(item: item, outcome: cancelled ? .cancelled : .failed,
                                message: cancelled ? "用户或系统取消了这次设置。请刷新核对当前关联。" :
                                    (error is FiletoError ? error.localizedDescription : "macOS 未完成这次设置。请刷新核对，确认目标应用可用后重新预览失败项。"), observed: observed,
                                errorDetails: Self.describeError(nsError))
        }
    }
    private static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        if error.domain == NSOSStatusErrorDomain && error.code == -128 { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isCancellation(underlying) }
        return false
    }
    private static func describeError(_ error: NSError) -> String {
        let description = "\(error.domain):\(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return description + " → " + describeError(underlying)
        }
        return description
    }
    public func restorePreview(_ record: ChangeRecord) throws -> [ChangeItem] {
        let plan = try record.results.filter { $0.outcome == .changed || $0.outcome == .unverified }.compactMap { result -> ChangeItem? in
            guard let previous = result.item.before else { return nil }
            let current = try query(result.item.type)
            guard current.application?.id == result.item.target.id,
                  current.candidates.contains(where: { $0.id == previous.id }) else { return nil }
            return ChangeItem(type: result.item.type, before: current.application, target: previous)
        }
        guard !plan.isEmpty else { throw FiletoError.noRestorableChanges }
        return plan
    }
}
