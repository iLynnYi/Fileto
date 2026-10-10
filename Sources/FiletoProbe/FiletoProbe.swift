import AppKit
import UniformTypeIdentifiers
import FiletoCore

@main struct FiletoProbe {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let workspace = SystemWorkspace()
            if args.first == "--run-ui-smoke", args.count == 3 || args.count == 5 || (args.count == 4 && args.last == "--interactions") {
                let configuration = NSWorkspace.OpenConfiguration()
                // Writable integration runs need the same activation grant as
                // an app launched by the user. Read-only rendering stays hidden.
                configuration.activates = args.count == 5 || args.last == "--interactions"
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--ui-smoke"] + Array(args.dropFirst(2))
                let running = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args[1]), configuration: configuration)
                var lastStage = ""
                for _ in 0..<1800 {
                    if running.isTerminated { break }
                    if let stage = try? String(contentsOf: URL(fileURLWithPath: args[2]).appendingPathComponent("stage.txt"), encoding: .utf8), stage != lastStage {
                        print(stage); fflush(stdout); lastStage = stage
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if !running.isTerminated {
                    running.forceTerminate()
                    for application in NSWorkspace.shared.runningApplications {
                        if let url = application.bundleURL, Array(args.dropFirst(3)).contains(url.path) { application.forceTerminate() }
                    }
                    throw NSError(domain: "Fileto.SystemSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "原生界面验证超时（\(lastStage)）；测试进程已结束"])
                }
                let result = try String(contentsOf: URL(fileURLWithPath: args[2]).appendingPathComponent("smoke-result.txt"), encoding: .utf8)
                print(result)
                guard result.hasPrefix("PASS") else { exit(1) }
            } else if args.first == "--catalog" {
                let snapshot = TypeCatalog.discover()
                print("发现 \(snapshot.types.count) 个类型、\(snapshot.applications.count) 个应用")
                for warning in snapshot.warnings { print("提示：\(warning)") }
            } else if args.first == "--file", args.count == 2 {
                let result = try workspace.inspect(URL(fileURLWithPath: args[1]))
                print("文件：\(result.url.lastPathComponent)\n类型：\(result.type.id)\n实际应用：\(result.effectiveApplication?.name ?? "未找到")")
            } else {
                let extensions = args.isEmpty ? ["pdf", "jpg", "md", "json"] : args
                for ext in extensions {
                    for type in try TypeCatalog.lookup(ext) {
                        let association = try workspace.association(for: type)
                        print("\(type.extensionLabel) [\(type.id)] → \(association.application?.name ?? "未找到默认应用")")
                        print("  候选：\(association.candidates.map(\.name).joined(separator: "、"))")
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            FileHandle.standardError.write(Data("\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]\n".utf8))
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                FileHandle.standardError.write(Data("Underlying: \(underlying.domain):\(underlying.code) \(underlying.localizedDescription)\n".utf8))
            }
            exit(1)
        }
    }
}
