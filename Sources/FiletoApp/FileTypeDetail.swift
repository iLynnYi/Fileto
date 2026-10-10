import SwiftUI
import FiletoCore

struct FileTypeDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文件类型详情").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let row = model.detailRow {
                        detail(row)
                    } else {
                        Text("这个类型已不在当前发现结果中，请关闭后重新查询。").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { model.sheet = nil }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 560, height: 480)
    }

    @ViewBuilder private func detail(_ row: Association) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.type.name).font(.headline).textSelection(.enabled)
            Text(row.type.extensionLabel.isEmpty ? "无扩展名" : row.type.extensionLabel)
                .foregroundStyle(.secondary).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(model.queryErrors[row.id] == nil ? "当前默认应用" : "上次查询的默认应用").font(.headline)
            if let app = row.application {
                HStack { AppIcon(application: app, size: 32); Text(app.name) }.accessibilityElement(children: .combine)
            } else { Text("系统未找到可用的默认应用").foregroundStyle(.secondary) }
            if let warning = model.queryErrors[row.id] {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        if let inspection = model.inspection, inspection.type.id == row.id {
            VStack(alignment: .leading, spacing: 6) {
                Text("所查询文件").font(.headline)
                Text(inspection.url.lastPathComponent).textSelection(.enabled)
                Text("\(model.inspectionWarning == nil ? "实际打开应用" : "上次查询的实际打开应用")：\(inspection.effectiveApplication?.name ?? "未找到")")
                if let warning = model.inspectionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if inspection.effectiveApplication?.id != row.application?.id {
                    Text("这个文件的打开方式与类型默认值不同；本工具修改的是类型默认值。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        Text("修改会影响这个类型的所有关联扩展名。具体文件可能有独立打开方式。").font(.caption).foregroundStyle(.secondary)
        if !model.ambiguousTypes(for: row.type).isEmpty {
            Text("同扩展名还对应 \(model.ambiguousTypes(for: row.type).count) 个其他类型。可拖入具体文件确认；修改时仅处理选中的类型。")
                .font(.caption).foregroundStyle(.orange)
        }
        DisclosureGroup("高级信息") {
            VStack(spacing: 0) {
                informationRow("UTI", value: row.type.id)
                Divider()
                informationRow("状态", value: row.status)
                Divider()
                informationRow("系统候选应用", value: "\(row.candidates.count) 个")
                if let app = row.application {
                    Divider()
                    informationRow("Bundle ID", value: app.bundleID)
                    Divider()
                    informationRow("应用路径", value: app.url.path)
                }
            }
            .font(.caption)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)) }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.id(row.id)
    }

    private func informationRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
