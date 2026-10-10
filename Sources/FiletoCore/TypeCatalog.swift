import Foundation
import UniformTypeIdentifiers

public struct CatalogSnapshot: Sendable {
    public var types: [FileType]
    public var applications: [Application]
    public var warnings: [String]
}

public enum TypeCatalog {
    public static let commonExtensions = ["pdf", "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "svg", "txt", "md", "markdown", "json", "yaml", "yml", "xml", "html", "css", "js", "ts", "swift", "py", "csv", "doc", "docx", "xls", "xlsx", "pptx", "pages", "numbers", "key", "zip", "7z", "rar", "dmg", "mp3", "wav", "flac", "mp4", "mov", "mkv", "epub"]
    public static func normalizedExtension(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+")).contains($0) }) else {
            throw FiletoError.invalidExtension
        }
        return value
    }
    public static func lookup(_ input: String) throws -> [FileType] {
        let ext = try normalizedExtension(input)
        return UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil).map {
            describe($0, extraExtensions: [ext])
        }
    }
    public static func describe(_ type: UTType, extraExtensions: [String] = []) -> FileType {
        let extensions = Set((type.tags[.filenameExtension] ?? []) + extraExtensions)
            .filter { (try? normalizedExtension($0)) != nil }.map { $0.lowercased() }.sorted()
        return FileType(id: type.identifier, name: type.localizedDescription ?? extensions.first.map { $0.uppercased() + " 文件" } ?? type.identifier,
                        extensions: extensions, isDynamic: type.isDynamic)
    }
    public static func commonTypes() -> [FileType] {
        merge(commonExtensions.flatMap { (try? lookup($0)) ?? [] })
    }
    public static func merge(_ types: [FileType]) -> [FileType] {
        var indexed: [String: FileType] = [:]
        for type in types {
            if var existing = indexed[type.id] {
                existing.extensions = Array(Set(existing.extensions + type.extensions)).sorted()
                indexed[type.id] = existing
            } else { indexed[type.id] = type }
        }
        return indexed.values.sorted { $0.extensionLabel.localizedStandardCompare($1.extensionLabel) == .orderedAscending }
    }
    // Only bounded application roots; do not traverse documents, mounted volumes, or app contents.
    public static func discover(roots: [URL]? = nil) -> CatalogSnapshot {
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                              URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices")]
        var types = commonTypes(), applications: [Application] = [], warnings: [String] = []
        var visited = Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { url, error in
                    if warnings.count < 20 { warnings.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                    return true
                }) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    guard visited.insert(url.standardizedFileURL.path).inserted else { continue }
                    if let application = Application.read(at: url) { applications.append(application) }
                    if let info = Bundle(url: url)?.infoDictionary { types += declaredTypes(in: info) }
                } else if url.pathExtension == "bundle" || url.pathExtension == "framework" || enumerator.level > 4 {
                    enumerator.skipDescendants()
                }
            }
        }
        return CatalogSnapshot(types: merge(types), applications: applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }
    public static func declaredTypes(in info: [String: Any]) -> [FileType] {
        var result: [FileType] = []
        for key in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            for declaration in info[key] as? [[String: Any]] ?? [] {
                guard let id = declaration["UTTypeIdentifier"] as? String, let type = UTType(id) else { continue }
                let tags = declaration["UTTypeTagSpecification"] as? [String: Any] ?? [:]
                let tagValue = tags["public.filename-extension"]
                let extensions = tagValue as? [String] ?? (tagValue as? String).map { [$0] } ?? []
                let described = describe(type, extraExtensions: extensions)
                if !described.extensions.isEmpty { result.append(described) }
            }
        }
        for document in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            if let ids = document["LSItemContentTypes"] as? [String] {
                result += ids.compactMap { UTType($0) }.map { describe($0) }.filter { !$0.extensions.isEmpty }
            } else {
                result += (document["CFBundleTypeExtensions"] as? [String] ?? []).flatMap { (try? lookup($0)) ?? [] }
            }
        }
        return merge(result)
    }
}
