import Foundation

public struct FileType: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var extensions: [String]
    public var isDynamic: Bool
    public init(id: String, name: String, extensions: [String], isDynamic: Bool = false) {
        self.id = id; self.name = name; self.extensions = extensions; self.isDynamic = isDynamic
    }
    public var extensionLabel: String { extensions.map { "." + $0 }.joined(separator: "、") }
}

public struct Application: Identifiable, Hashable, Codable, Sendable {
    public var url: URL
    public var bundleID: String
    public var name: String
    // URL is normalized once on construction; identity comparisons must never perform filesystem I/O.
    public var id: String { url.path }
    public init(url: URL, bundleID: String, name: String) {
        self.url = url.standardizedFileURL; self.bundleID = bundleID; self.name = name
    }
    public static func read(at url: URL) -> Application? {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Application(url: url, bundleID: identifier, name: name)
    }
}

public struct Association: Identifiable, Hashable, Sendable {
    public var type: FileType
    public var application: Application?
    public var candidates: [Application]
    public var id: String { type.id }
    public var status: String {
        if type.isDynamic { return "未声明的类型" }
        return application == nil ? "未找到默认应用" : "已解析"
    }
    public init(type: FileType, application: Application?, candidates: [Application]) {
        self.type = type; self.application = application; self.candidates = candidates
    }
}

public struct ChangeItem: Identifiable, Codable, Sendable {
    public var type: FileType
    public var before: Application?
    public var target: Application
    public var id: String { type.id }
    public init(type: FileType, before: Application?, target: Application) {
        self.type = type; self.before = before; self.target = target
    }
}

public enum ChangeOutcome: String, Codable, Sendable {
    case changed, alreadyDefault, failed, unverified, cancelled, conflict
    public var label: String {
        switch self {
        case .changed: return "已修改并验证"
        case .alreadyDefault: return "已是目标应用"
        case .failed: return "修改失败"
        case .unverified: return "尚未验证生效"
        case .cancelled: return "已取消"
        case .conflict: return "关联已变化"
        }
    }
}

public struct ChangeResult: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var item: ChangeItem
    public var outcome: ChangeOutcome
    public var message: String
    public var observed: Application?
    public var errorDetails: String?
    public init(item: ChangeItem, outcome: ChangeOutcome, message: String, observed: Application?, errorDetails: String? = nil) {
        self.item = item; self.outcome = outcome; self.message = message; self.observed = observed
        self.errorDetails = errorDetails
    }
}

public struct ChangeRecord: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var isRestore: Bool
    public var results: [ChangeResult]
    public init(isRestore: Bool = false, results: [ChangeResult]) {
        self.isRestore = isRestore; self.results = results
    }
}

public struct FileInspection: Sendable {
    public var url: URL
    public var type: FileType
    public var effectiveApplication: Application?
}

public enum FiletoError: LocalizedError {
    case invalidExtension, unknownType(String), unavailableApplication, unsupportedApplication(String), noRestorableChanges
    public var errorDescription: String? {
        switch self {
        case .invalidExtension: return "请输入有效扩展名，例如 pdf 或 .md。"
        case .unknownType(let id): return "系统无法解析文件类型：\(id)"
        case .unavailableApplication: return "目标应用已不存在或无法读取，请刷新后重新选择。"
        case .unsupportedApplication(let name): return "系统未将这个应用列为 \(name) 的候选应用。"
        case .noRestorableChanges: return "没有可以恢复的修改；原应用可能不存在，或当前关联已被再次更改。"
        }
    }
}
