import Foundation

public struct HistoryStore {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fileto/history.json")
    }
    public func load() throws -> [ChangeRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ChangeRecord].self, from: Data(contentsOf: url))
    }
    public func save(_ records: [ChangeRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(records.prefix(30))).write(to: url, options: .atomic)
    }
}
