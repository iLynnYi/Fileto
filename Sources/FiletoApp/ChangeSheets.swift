import SwiftUI
import FiletoCore

struct ChangeChooser: View {
    @ObservedObject var model: AppModel
    @State private var showingSelectedTypes = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择默认应用").font(.title2.weight(.semibold))
            Text("已选择 \(model.selectedTypes.count) 个类型").foregroundStyle(.secondary)
            if model.changeRows.count == 1, let row = model.changeRows.first {
                Text(row.type.name).font(.headline)
                Text(row.type.extensionLabel.isEmpty ? "无扩展名" : row.type.extensionLabel).font(.caption).textSelection(.enabled)
                HStack {
                    if let app = row.application { AppIcon(application: app, size: 24) }
                    Text("当前：\(row.application?.name ?? "未找到默认应用")")
                }
            } else {
                Button("查看所选类型（\(model.selectedTypes.count)）…") { showingSelectedTypes = true }
                    .disabled(model.loadingChoices || !model.hasCompleteChoiceSnapshot)
            }
            Text("系统候选应用 · \(model.systemChoiceCount)").font(.headline)
            if model.loadingChoices {
                VStack(spacing: 8) {
                    if let progress = model.choiceQueryProgress {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            .frame(maxWidth: 300)
                        Text(progress.preparingPreview ? "正在准备修改…" : "正在查询当前默认应用与候选…")
                        Text("\(progress.preparingPreview ? "已准备" : "已查询") \(progress.completed) / \(progress.total) 个类型").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.choice) {
                    ForEach(model.choices) { app in
                        HStack(spacing: 8) {
                            AppIcon(application: app, size: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name)
                                if model.hasDuplicateChoiceName(app) {
                                    Text(app.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if model.changeRows.count > 1 {
                                    Text("可用于 \(model.coverage(app)) / \(model.changeRows.count) 个类型").font(.caption).foregroundStyle(.secondary)
                                }
                                if model.currentCount(app) > 0 {
                                    Text(model.changeRows.count == 1 ? "当前默认应用" : "\(model.currentCount(app)) 项当前默认")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if model.coverage(app) == 0 {
                                    Text("系统未确认支持，无法修改").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if model.choice == app.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }.tag(app.id).help(app.url.path)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(model.choice == app.id ? "已选择" : "未选择")
                    }
                }.listStyle(.inset).frame(minHeight: 100)
            }
            if model.choices.isEmpty && !model.loadingChoices {
                Text("系统未提供候选应用。可浏览其他应用，只有系统确认支持的应用才能修改。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if let error = model.choiceError {
                    Text(error).foregroundStyle(.orange)
                } else if let summary = model.choiceSummary {
                    Text(summaryMessage(summary)).foregroundStyle(.secondary)
                } else if !model.loadingChoices {
                    Text("选择应用后会显示需修改、无需修改和跳过的数量。").foregroundStyle(.secondary)
                }
            }.font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if let target = model.choiceTarget {
                    Text("目标应用：\(target.name)").font(.headline)
                }
                Text("修改本机的类型默认应用，共享同一类型的扩展名会一起受影响。具体文件可能有独立打开方式。")
                    .foregroundStyle(.secondary)
                if model.choiceHasAmbiguousTypes {
                    Text("部分扩展名对应多个类型；本次仅修改所选类型，其他类型不会一起修改。")
                        .foregroundStyle(.orange)
                }
                Label(model.selectedTypes.count == 1 ? "macOS 可能要求确认，请在系统提示中确认或取消。" :
                    "macOS 可能逐项要求确认，需手动完成；开始后可停止后续修改。", systemImage: "info.circle")
            }.font(.caption).fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("浏览其他应用…") { model.browseApplication() }.disabled(model.loadingChoices)
            HStack {
                Button("取消") { model.cancelChoice() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.selectedTypes.count == 1 ? "修改" : "开始修改") { Task { await model.submitChange() } }.buttonStyle(PrimaryActionStyle())
                    .disabled(!model.canContinue).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 600, height: 560)
            .sheet(isPresented: $showingSelectedTypes) { SelectedTypesDetail(rows: model.changeRows, target: model.choiceTarget) }
    }
    private func summaryMessage(_ summary: AppModel.ChoiceSummary) -> String {
        if model.changeRows.count == 1 {
            if summary.unsupported > 0 { return "系统未确认此应用支持该类型，请选择其他应用。" }
            return summary.changes > 0 ? "将修改 1 个类型的默认应用。" : "此类型已是该应用，无需修改。"
        }
        if summary.changes == 0 {
            return "没有需要修改的类型。\(summary.unchanged) 项已是该应用，\(summary.unsupported) 项不受支持。"
        }
        return "将修改 \(summary.changes) 项，\(summary.unchanged) 项无需修改，\(summary.unsupported) 项不受支持，将跳过。"
    }
}

struct SelectedTypesDetail: View {
    let rows: [Association]
    var target: Application? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("所选类型与当前默认应用").font(.title2.weight(.semibold))
            Text("共 \(rows.count) 个类型；同一类型关联的扩展名会共同受影响。")
                .font(.caption).foregroundStyle(.secondary)
            Table(rows) {
                TableColumn("扩展名") { row in
                    Text(row.type.extensionLabel.isEmpty ? "无扩展名" : row.type.extensionLabel)
                        .lineLimit(1).help(row.type.extensionLabel)
                }.width(min: 140, ideal: 200)
                TableColumn("文件类型") { row in
                    Text(row.type.name).lineLimit(1).help(row.type.name)
                }.width(min: 140, ideal: 220)
                TableColumn("当前默认应用") { row in
                    HStack(spacing: 6) {
                        if let app = row.application { AppIcon(application: app, size: 18) }
                        Text(row.application?.name ?? "未找到默认应用").lineLimit(1)
                    }.help(row.application?.name ?? "未找到默认应用")
                }.width(min: 160, ideal: 220)
                TableColumn("处理方式") { row in
                    Text(disposition(row)).foregroundStyle(.secondary)
                }.width(min: 160, ideal: 200)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 900, height: 440)
    }
    private func disposition(_ row: Association) -> String {
        guard let target else { return "请选择目标应用" }
        guard row.candidates.contains(where: { $0.id == target.id }) else { return "不受支持，将跳过" }
        return row.application?.id == target.id ? "已是目标应用，无需修改" : "修改为 \(target.name)"
    }
}

struct ChangePreview: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.isRestore ? "恢复到修改前应用" : "确认更改默认应用").font(.title2.weight(.semibold))
            Text("将处理 \(model.plan.count) 个类型，跳过 \(model.skipped.count) 项。每项修改后都会重新查询系统结果。").foregroundStyle(.secondary)
            List {
                ForEach(model.plan) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.type.name).font(.headline)
                        Text(item.type.extensionLabel.isEmpty ? "无扩展名" : item.type.extensionLabel).textSelection(.enabled)
                        Text("\(item.before?.name ?? "未找到默认应用") → \(item.target.name)")
                        DisclosureGroup("应用信息") {
                            VStack(alignment: .leading, spacing: 6) {
                                if let before = item.before { Text("当前应用：\(before.url.path)") }
                                Text("目标应用：\(item.target.url.path)")
                            }.font(.caption).textSelection(.enabled)
                        }
                    }.padding(.vertical, 4)
                }
                if !model.skipped.isEmpty {
                    Section("以下 \(model.skipped.count) 项不会修改") {
                        Text(model.skipped.joined(separator: "、"))
                        Text(model.isRestore ? "原应用不可用、没有可恢复记录，或当前关联已变化。" : "目标应用未被系统列为这些类型的候选应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(model.isRestore ? "恢复是再次设置默认应用，并非撤销系统配置；关联再次变化时会跳过。" : "修改这些文件类型在本机的默认打开应用，共享同一类型的扩展名会一起受影响。具体文件可能有独立打开方式。macOS 可能要求系统确认。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isRestore && model.plan.contains(where: { !model.ambiguousTypes(for: $0.type).isEmpty }) {
                Text("部分扩展名对应多个类型；本次仅修改预览中列出的类型，其他类型不会一起修改。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { model.showingPreview = false }.keyboardShortcut(.cancelAction)
                Button(model.isRestore ? "确认恢复" : "确认修改") { Task { await model.execute() } }
                    .buttonStyle(PrimaryActionStyle()).disabled(model.plan.isEmpty || model.applying).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650, height: 500)
    }
}

struct ChangeResultsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.applying ? "正在更改默认应用…" : "处理结果").font(.title2.weight(.semibold))
            if model.applying {
                ProgressView(value: Double(model.latestResults.count), total: Double(max(model.plan.count, 1)))
                Text("\(model.latestResults.count) / \(model.plan.count) · 系统确认期间请完成或取消系统提示。").font(.caption).foregroundStyle(.secondary)
            } else {
                ResultSummaryView(results: model.latestResults, skippedCount: model.resultSkipped.count)
            }
            Text("这是本次操作记录；当前默认应用以列表的重新查询为准。修改后的类型可能不再属于当前应用或筛选范围。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.latestResults) { ResultRow(result: $0) }
                if !model.resultSkipped.isEmpty {
                    Section("未进入执行的项目") { ForEach(Array(model.resultSkipped.enumerated()), id: \.offset) { Text($0.element) } }
                }
            }
            HStack {
                if model.applying {
                    Button(model.stopRequested ? "将在当前项结束后停止" : "停止后续修改") { model.stopRequested = true }
                        .disabled(model.stopRequested)
                } else {
                    Button("刷新核对") { model.showingResults = false; Task { await model.refresh() } }.disabled(model.scanning)
                    Button("重新预览失败项") { model.retry(model.latestResults, restoring: model.resultsAreRestore) }
                        .disabled(!model.latestResults.contains { $0.outcome == .failed } || model.scanning)
                }
                Spacer()
                Button("关闭") { model.showingResults = false }.disabled(model.applying)
            }
        }.padding(24).frame(width: 680, height: 500).interactiveDismissDisabled(model.applying)
    }
}

struct ResultRow: View {
    let result: ChangeResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.item.type.extensionLabel.isEmpty ? result.item.type.name : result.item.type.extensionLabel).font(.headline)
                Spacer()
                Text(result.outcome.label).foregroundStyle(result.outcome == .changed || result.outcome == .alreadyDefault ? Color.green : Color.secondary)
            }
            Text("\(result.item.before?.name ?? "未找到默认应用") → \(result.item.target.name)")
            Text(result.message).font(.caption).foregroundStyle(.secondary)
            if let observed = result.observed { Text("最近查询：\(observed.name)").font(.caption).foregroundStyle(.secondary) }
            if let details = result.errorDetails {
                DisclosureGroup("错误详情") { Text(details).font(.caption).textSelection(.enabled) }
            }
        }.padding(.vertical, 6)
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("操作记录").font(.title2.weight(.semibold))
            Text("本机保留最近 30 次操作。恢复前会检查应用和当前关联。").foregroundStyle(.secondary)
            List {
                if model.records.isEmpty { Text("还没有修改记录").foregroundStyle(.secondary) }
                ForEach(model.records) { record in
                    DisclosureGroup {
                        ForEach(record.results) { ResultRow(result: $0) }
                        HStack {
                            Button("预览恢复到修改前应用") { model.prepareRestore(record) }
                                .disabled(model.scanning || model.applying)
                            Button("重新预览失败项") { model.showingHistory = false; model.retry(record.results, restoring: record.isRestore) }
                                .disabled(model.scanning || model.applying || !record.results.contains { $0.outcome == .failed })
                        }.padding(.vertical, 8)
                    } label: {
                        HStack {
                            Text(record.isRestore ? "恢复操作" : "修改默认应用")
                            Text(record.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(record.results.count) 个类型").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { model.showingHistory = false } }
        }.padding(24).frame(width: 720, height: 540)
    }
}

struct ResultSummaryView: View {
    let results: [ChangeResult]
    var skippedCount = 0
    private func count(_ outcome: ChangeOutcome) -> Int { results.filter { $0.outcome == outcome }.count }
    private var title: String {
        if results.isEmpty { return "尚无执行结果" }
        let succeeded = count(.changed) + count(.alreadyDefault)
        if succeeded == results.count && skippedCount == 0 { return "处理完成，系统已验证" }
        if succeeded > 0 { return "部分完成，请查看逐项结果" }
        if count(.failed) == results.count { return "修改失败" }
        return "处理结束，请核对结果"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text("\(count(.changed)) 项已修改并验证 · \(count(.failed)) 项失败 · \(count(.unverified)) 项待验证")
            Text("\(count(.alreadyDefault)) 项无需修改 · \(count(.conflict)) 项关联已变化 · \(count(.cancelled)) 项取消或未执行 · \(skippedCount) 项跳过")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
