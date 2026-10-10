import SwiftUI

struct AboutView: View {
    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let version, !version.isEmpty else { return "开发版本" }
        guard let build, !build.isEmpty else { return "版本 \(version)" }
        return "版本 \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            if let icon = FiletoIcon.image {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 4)
            }
            Text("Fileto")
                .font(.headline)
            Text("轻松管理文件类型的默认打开方式")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(versionLabel)
                .font(.caption)
            Link(destination: URL(string: "https://github.com/iLynnYi/Fileto")!) {
                Text("访问官网")
                    .underline()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 300)
    }
}
