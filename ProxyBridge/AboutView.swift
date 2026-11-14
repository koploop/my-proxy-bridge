import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    // 从应用包读取版本，让关于窗口与当前构建保持一致。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("代理桥").font(.headline)
                    Text("版本 \(appVersion)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("macOS SOCKS5 代理客户端")
                .foregroundStyle(.secondary)
            Divider()

            // 保留上游项目署名和链接。
            Text("原项目作者 Sourav Kalal / InterceptSuite")
            HStack(spacing: 12) {
                Link("项目源码", destination: URL(string: "https://github.com/InterceptSuite/ProxyBridge")!)
                Link("作者网站", destination: URL(string: "https://interceptsuite.com")!)
                Spacer()
                Text("MIT 许可证").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(18)
        .frame(width: 350)
    }
}
