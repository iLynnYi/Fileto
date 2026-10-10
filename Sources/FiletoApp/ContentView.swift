import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FiletoCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    var presentsSheets = true
    @State private var extensionInput = ""
    @State private var dropping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fileto").font(.title2.weight(.semibold))
                    Text("管理你的 Mac 文件打开方式").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("视图", selection: Binding(get: { model.mode }, set: { model.switchMode($0) })) {
                    ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 180)
                Button { model.openFile() } label: { Image(systemName: "doc.text.magnifyingglass") }.accessibilityLabel("查询文件").help("查询文件，也可拖入文件")
                Button { model.showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("操作记录与恢复").help("操作记录与恢复")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新系统关联").help("刷新系统关联")
            }.padding(20).disabled(model.applying || model.scanning)
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索扩展名、类型名称或默认应用", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Picker("排序", selection: $model.sortByApplication) {
                    Text("按扩展名").tag(false); Text("按默认应用").tag(true)
                }.frame(width: 160)
                Button { model.ascending.toggle() } label: { Image(systemName: model.ascending ? "arrow.up" : "arrow.down") }.help("切换排序方向")
            }.padding(.horizontal, 20).padding(.vertical, 12).disabled(model.applying || model.scanning)
            HStack {
                Toggle("仅显示未解析类型", isOn: $model.onlyUnresolved).toggleStyle(.checkbox)
                if model.mode == .files {
                    Picker("默认应用", selection: $model.applicationFilter) {
                        Text("全部应用").tag("")
                        ForEach(model.indexedApplications.filter { model.count(for: $0) > 0 || $0.id == model.applicationFilter }) { app in Text(app.name).tag(app.id) }
                    }.frame(maxWidth: 240)
                } else {
                    Picker("关联范围", selection: $model.showCandidates) {
                        Text("当前默认负责").tag(false); Text("可用于打开").tag(true)
                    }.pickerStyle(.segmented).frame(width: 240)
                }
                Spacer()
                Text("已发现 \(model.associations.count) 个类型").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 12).disabled(model.applying || model.scanning)
            Divider()
            HSplitView {
                if model.mode == .applications { applicationList.frame(minWidth: 180, idealWidth: 210, maxWidth: 260) }
                typeTable.frame(minWidth: 440)
            }
            Divider()
            HStack {
                if model.applying {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在处理 \(model.latestResults.count) / \(model.plan.count)\(model.executingItem.map { " · " + $0.type.name } ?? "")")
                        Text(executionMessage).foregroundStyle(.secondary)
                    }.font(.caption)
                    Button(model.stopRequested ? "将在当前项后停止" : "停止后续修改") { model.stopRequested = true }
                        .disabled(model.stopRequested)
                }
                else if model.scanning { ProgressView().controlSize(.small); Text(model.scanMessage).font(.caption) }
                else {
                    Text("显示 \(model.visibleRows.count) 项 · 已选择 \(model.chosenRows.count) 个类型").font(.caption).foregroundStyle(.secondary)
                    if let date = model.lastRefreshed { Text(date, style: .time).font(.caption).foregroundStyle(.tertiary) }
                    if model.refreshingAutomatically {
                        ProgressView().controlSize(.small)
                        Text("正在检查系统关联…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.warnings.isEmpty {
                    Button("\(model.warnings.count) 条刷新提示") { model.showingWarnings = true }.font(.caption)
                }
                Spacer()
                Button("全选当前结果") { model.selectedTypes = Set(model.visibleRows.map(\.id)) }
                    .disabled(model.visibleRows.isEmpty || model.scanning || model.applying)
                if model.chosenRows.count > 1 {
                    Button("更改 \(model.chosenRows.count) 个类型…") { Task { await model.beginChange() } }
                        .buttonStyle(PrimaryActionStyle()).disabled(model.scanning || model.applying || model.choosingApplication || model.sheet != nil)
                }
            }.padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if dropping { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .overlay(alignment: .top) {
            if let message = model.message {
                HStack(alignment: .top, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: message.systemImage).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.title).fontWeight(.semibold)
                            Text(message.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }.accessibilityElement(children: .combine)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭提示")
                }
                .font(.callout)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)) }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .frame(maxWidth: 360)
                .padding(.horizontal, 20)
                .padding(.top, 80)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.message?.id)
        .task(id: model.message?.id) {
            guard let message = model.message else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            if model.message?.id == message.id { model.message = nil }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard !model.applying && !model.scanning, let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in model.inspectFile(url) } }
            }
            return true
        }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil && model.sheet == nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { presentsSheets && model.sheet != nil }, set: {
            if presentsSheets && !$0 { model.sheet = nil }
        }), onDismiss: {
            if presentsSheets { model.didDismissSheet() }
        }) {
            modal(model.sheet ?? .preview)
                .onAppear { if presentsSheets { model.didPresentSheet() } }
                .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("知道了") { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
    }
    @ViewBuilder private func modal(_ sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case .chooser: ChangeChooser(model: model)
        case .details: FileTypeDetail(model: model)
        case .preview: ChangePreview(model: model)
        case .results: ChangeResultsView(model: model)
        case .history: HistoryView(model: model)
        case .warnings:
            VStack(alignment: .leading) {
                Text("刷新提示").font(.title2)
                Text("查询失败的项目保留上次结果，新项目可能暂未列出。你可以刷新重试。").foregroundStyle(.secondary)
                List(Array(model.warnings.enumerated()), id: \.offset) { Text($0.element).textSelection(.enabled) }
                Button("关闭") { model.showingWarnings = false }
            }.padding(24).frame(width: 600, height: 420)
        }
    }
    private var applicationList: some View {
        VStack(spacing: 0) {
            TextField("搜索应用", text: $model.appSearch).textFieldStyle(.roundedBorder).padding(12)
            List(selection: Binding(get: { model.selectedApplication }, set: { model.selectApplication($0) })) {
                ForEach(model.indexedApplications.filter { model.appSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.appSearch) }) { app in
                    HStack {
                        AppIcon(application: app, size: 22)
                        VStack(alignment: .leading) {
                            Text(app.name).lineLimit(1)
                            Text("默认负责 \(model.count(for: app)) 个类型").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(app.id).help(app.url.path)
                }
            }
            Text("范围为已发现的文件类型").font(.caption).foregroundStyle(.secondary).padding(10)
        }.disabled(model.applying || model.scanning)
    }
    private var typeTable: some View {
        VStack(spacing: 0) {
            Table(model.visibleRows, selection: $model.selectedTypes) {
                TableColumn("扩展名") { row in
                    HStack(spacing: 5) {
                        Text(row.type.extensionLabel.isEmpty ? "无扩展名" : row.type.extensionLabel).lineLimit(1)
                        if row.type.isDynamic {
                            TypeHintButton(title: "未声明类型", systemImage: "questionmark.circle") {
                                showHint(title: "未声明类型", systemImage: "questionmark.circle",
                                         text: "系统未找到此类型的正式声明，仍可能有默认应用。可拖入具体文件查询打开方式。")
                            }
                        }
                        if let warning = model.queryErrors[row.id] {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(warning)
                                .accessibilityLabel(warning)
                        }
                        if !model.ambiguousTypes(for: row.type).isEmpty {
                            TypeHintButton(title: "同扩展名对应多种类型", systemImage: "info.circle") {
                                showHint(title: "同扩展名对应多种类型", systemImage: "info.circle",
                                         text: "这些扩展名还对应 \(model.ambiguousTypes(for: row.type).count) 个其他类型。可拖入具体文件确认；修改时仅处理选中的类型。")
                            }
                        }
                    }.help(row.type.extensionLabel)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.width(min: 100, ideal: 140)
                TableColumn("文件类型") { row in
                    Text(row.type.name).lineLimit(1).help("\(row.type.name) · 双击查看详情")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                TableColumn("默认应用") { row in
                    applicationMenu(row)
                }.width(min: 130, ideal: 170)
            }.contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("查看详情…") { model.showDetails(for: id) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.showDetails(for: id) }
            }
            .disabled(model.applying || model.scanning || model.choosingApplication)
            HStack {
                TextField("补充查询：例如 .pdf", text: $extensionInput).textFieldStyle(.roundedBorder)
                    .onSubmit { model.lookupExtension(extensionInput) }
                Button("查询") { model.lookupExtension(extensionInput) }.disabled(extensionInput.isEmpty)
            }.padding(12).disabled(model.scanning || model.applying)
        }
        .overlay {
            if model.visibleRows.isEmpty && !model.scanning {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.mode == .applications && model.selectedApplication == nil ? "选择一个应用" : "没有匹配的文件类型")
                    Text("可以调整筛选，或在下方输入扩展名补充查询。").font(.caption).foregroundStyle(.secondary)
                }.allowsHitTesting(false)
            }
        }
    }
    private func applicationMenu(_ row: Association) -> some View {
        let candidates = row.candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let choices = row.application.map { current in [current] + candidates.filter { $0.id != current.id } } ?? candidates
        return HStack(spacing: 6) {
            if let app = row.application { AppIcon(application: app, size: 18) }
            Menu {
                Picker("默认应用", selection: Binding(get: { row.application?.id ?? "" }, set: { id in
                    if let app = choices.first(where: { $0.id == id }) {
                        Task { await model.changeDefault(for: row.id, to: app, from: row) }
                    }
                })) {
                    if row.application == nil { Text("未找到默认应用").tag("").disabled(true) }
                    ForEach(choices) { app in
                        Label {
                            Text(app.name + (app.id == row.application?.id ? "（当前默认）" : "")
                                 + (choices.filter({ $0.name == app.name }).count > 1 ? " — " + app.url.path : ""))
                        } icon: {
                            AppIcon(application: app, size: 16)
                        }.tag(app.id).disabled(app.id == row.application?.id).help(app.url.path)
                    }
                }.pickerStyle(.inline)
                if choices.isEmpty { Text("系统未提供候选应用") }
                Divider()
                Button("其他应用…") { Task { await model.changeDefault(for: row.id) } }
            } label: {
                Text(row.application?.name ?? "选择默认应用…").lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更改\(row.type.name)的默认应用")
        }.frame(maxWidth: .infinity, alignment: .leading)
        .help(model.queryErrors[row.id] == nil ? "选择此类型的默认应用" : "上次查询值；选择时会重新查询系统关联")
    }

    private var executionMessage: String {
        if model.stopRequested { return "将在当前项结束后停止，已经完成的修改会保留。" }
        switch model.executionStage {
        case .checking: return "正在检查当前关联和目标应用…"
        case .requesting: return "等待 macOS 完成设置；如出现系统提示，请确认或取消。"
        case .verifying: return "系统已接受设置，正在重新查询验证…"
        case nil: return "正在准备修改…"
        }
    }

    private func showHint(title: String, systemImage: String, text: String) {
        model.showMessage(title: title, systemImage: systemImage, text: text)
    }
}

private struct TypeHintButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(title)，点击查看说明")
        .accessibilityLabel("\(title)，查看说明")
    }
}

struct AppIcon: View {
    let application: Application
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
            .renderingMode(.original).resizable().frame(width: size, height: size)
    }
}
