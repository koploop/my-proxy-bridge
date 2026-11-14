import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    let profileActions: AnyView
    let settingsActions: AnyView
    @State private var connectionSearchText = ""
    @State private var activitySearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            // 连接和活动日志同时显示。拖动中间分隔线可调整两块区域的高度。
            VSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("连接记录").font(.headline)
                        Spacer()
                        TextField("搜索连接记录…", text: $connectionSearchText)
                            .frame(width: 176)
                        Button("清空", action: viewModel.clearConnections)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Table(filteredConnections) {
                        TableColumn("应用", value: \.process)
                        TableColumn("目标地址") { connection in
                            let host = connection.destination
                            let address = host.contains(":") ? "[\(host)]" : host
                            Text("\(address):\(connection.port)")
                        }
                        TableColumn("时间", value: \.timestamp).width(90)
                        TableColumn("代理") { connection in
                            Text(connection.proxy == "Direct" ? "直连" : connection.proxy)
                        }
                        TableColumn("协议", value: \.connectionProtocol).width(60)
                    }
                }
                .frame(minHeight: 220, idealHeight: 360)

                ActivityLogsView(logs: filteredActivityLogs, searchText: $activitySearchText,
                                 onClear: viewModel.clearActivityLogs)
                    .frame(minHeight: 155, idealHeight: 230)
            }
            .padding(12)
        }
        .frame(minWidth: 850, minHeight: 500)
        .controlSize(.small)
    }

    private var headerView: some View {
        HStack(spacing: 9) {
            Text("代理桥").font(.headline)
            Circle()
                .fill(viewModel.isProxyActive ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(viewModel.isProxyActive ? "代理运行中" : (viewModel.isStartingProxy ? "正在启动代理…" : "代理未连接"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // 保留现有配置窗口，工具栏提供和菜单一致的操作。
            Button {
                NSApp.sendAction(#selector(AppDelegate.openProxySettings), to: nil, from: nil)
            } label: {
                Label("代理服务器", systemImage: "server.rack")
            }
            Button {
                NSApp.sendAction(#selector(AppDelegate.openProxyRules), to: nil, from: nil)
            } label: {
                Label("代理规则", systemImage: "list.bullet.rectangle")
            }
            Menu {
                settingsActions
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Menu {
                // 使用单选菜单显示系统勾选标记，选择后立即加载对应方案。
                Picker("切换配置方案", selection: Binding(
                    get: { viewModel.activeProfile },
                    set: { viewModel.switchProfile(to: $0) }
                )) {
                    ForEach(viewModel.profiles, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                profileActions
            } label: {
                Label {
                    Text("方案：\(viewModel.activeProfile)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .frame(maxWidth: 165)
                .help("当前方案：\(viewModel.activeProfile)")
            }
            Button(viewModel.isProxyActive ? "停止代理" : "启动代理") {
                if viewModel.isProxyActive {
                    viewModel.stopProxy()
                } else {
                    viewModel.installAndStartProxy()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isStartingProxy)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filteredConnections: [ProxyBridgeViewModel.ConnectionLog] {
        let q = connectionSearchText
        if q.isEmpty {
            return viewModel.connections
        }
        // 按连接记录的所有字段搜索，便于用应用名、目标地址或协议定位流量。
        return viewModel.connections.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.connectionProtocol.localizedCaseInsensitiveContains(q) ||
            $0.process.localizedCaseInsensitiveContains(q) ||
            $0.destination.localizedCaseInsensitiveContains(q) ||
            $0.port.localizedCaseInsensitiveContains(q) ||
            $0.proxy.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredActivityLogs: [ProxyBridgeViewModel.ActivityLog] {
        let q = activitySearchText
        if q.isEmpty {
            return viewModel.activityLogs
        }
        return viewModel.activityLogs.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.level.localizedCaseInsensitiveContains(q) ||
            $0.message.localizedCaseInsensitiveContains(q)
        }
    }
}
struct ActivityLogsView: View {
    let logs: [ProxyBridgeViewModel.ActivityLog]
    @Binding var searchText: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            LogTextView(text: logsText)
        }
    }

    private var searchBar: some View {
        HStack {
            Text("活动日志").font(.headline)
            Spacer()
            TextField("搜索活动日志…", text: $searchText)
                .frame(width: 176)
            Button("清空", action: onClear)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var logsText: NSAttributedString {
        let out = NSMutableAttributedString()
        for log in logs {
            out.append(LogText.seg("[\(log.timestamp)] ", .secondaryLabelColor))
            out.append(LogText.seg("[\(log.level)] ", log.level == "ERROR" ? .systemRed : .systemBlue))
            out.append(LogText.seg(log.message, log.level == "ERROR" ? .systemRed : .labelColor))
            out.append(LogText.seg("\n", .labelColor))
        }
        return out
    }
}

// 使用等宽字体对齐日志时间与级别。
enum LogText {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static func seg(_ string: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font])
    }
}

// read-only NSTextView so the whole log behaves like a text area, multi-row
// drag select, select all and copy all work like any text box
struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = LogText.font
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        // nothing changed, leave the current selection and scroll position alone
        if storage.string == text.string { return }

        // keep the user's selection if it still fits (holds while not trimming),
        // otherwise stick to the bottom so new lines stay in view
        let previousSelection = textView.selectedRanges
        let wasAtBottom = isScrolledToBottom(scrollView)

        storage.setAttributedString(text)

        let length = (text.string as NSString).length
        let validSelection = previousSelection.filter { value in
            let r = value.rangeValue
            return r.location + r.length <= length
        }

        if let sel = validSelection.first, sel.rangeValue.length > 0 {
            textView.selectedRanges = validSelection
        } else if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let visible = scrollView.contentView.bounds
        return visible.maxY >= docHeight - 24
    }
}
