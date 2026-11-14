import SwiftUI

struct ProxySettingsView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProxyId: String?
    @State private var showAddProxy = false
    @State private var editingConfig: ProxyBridgeViewModel.ProxyConfig?
    @State private var deletingConfig: ProxyBridgeViewModel.ProxyConfig?
    @State private var checkingConfig: ProxyBridgeViewModel.ProxyConfig?
    @State private var affectedRulesCount = 0

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            listContent
            Divider()
            footerButtons
        }
        .controlSize(.small)
        .frame(minWidth: 880, idealWidth: 880, maxWidth: .infinity, minHeight: 440, idealHeight: 480, maxHeight: .infinity)
        .onChange(of: viewModel.activeProfile) { _ in selectedProxyId = nil }
        .alert("删除代理服务器？", isPresented: Binding(
            get: { deletingConfig != nil },
            set: { if !$0 { deletingConfig = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let c = deletingConfig { viewModel.removeProxyConfig(c) }
                deletingConfig = nil
            }
            Button("取消", role: .cancel) { deletingConfig = nil }
        } message: {
            if affectedRulesCount > 0 {
                Text(verbatim: "有 \(affectedRulesCount) 条规则使用此代理，删除后这些规则将改为直连。")
            } else {
                Text("将永久删除此代理服务器。")
            }
        }
        .sheet(isPresented: $showAddProxy) {
            ProxyConfigEditorView(viewModel: viewModel, existing: nil)
        }
        .sheet(item: $editingConfig) { config in
            ProxyConfigEditorView(viewModel: viewModel, existing: config)
        }
        .sheet(item: $checkingConfig) { config in
            ProxyCheckerView(config: config)
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "network")
                .font(.headline)
                .foregroundColor(.accentColor)
            Text("代理服务器")
                .font(.headline)
                .fontWeight(.semibold)
            Text("\(viewModel.proxyConfigs.count) 台")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { showAddProxy = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("添加")
                }

            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var listContent: some View {
        if viewModel.proxyConfigs.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "network.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.gray)
                Text("尚未配置代理服务器")
                    .font(.title3)
                    .foregroundColor(.gray)
                Text("点击“添加”配置 SOCKS5 服务器")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            Table(viewModel.proxyConfigs, selection: $selectedProxyId) {
                TableColumn("名称") { config in
                    Text(config.name.isEmpty ? "未命名" : config.name)
                        .foregroundColor(config.name.isEmpty ? .secondary : .primary)
                }
                .width(140)

                TableColumn("协议") { config in
                    Text(config.type.uppercased())
                        .foregroundColor(typeColor(config.type))
                        .fontWeight(.semibold)
                }
                .width(70)

                TableColumn("服务器地址") { config in
                    // build the string first, interpolating an Int into a Text
                    // literal would add a locale grouping separator (1,080)
                    Text(verbatim: "\(config.host):\(String(config.port))")
                        .fontDesign(.monospaced)
                }
                .width(min: 180, ideal: 220, max: .infinity)

                TableColumn("认证") { config in
                    if config.username != nil {
                        Image(systemName: "lock.fill").foregroundColor(.secondary)
                    } else {
                        Text("-").foregroundColor(.secondary)
                    }
                }
                .width(40)

                TableColumn("测试") { config in
                    Button(action: { checkingConfig = config }) {
                        Label("测试", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderless)
                }
                .width(min: 60, ideal: 80)

                TableColumn("操作") { config in
                    HStack(spacing: 12) {
                        Button(action: { editingConfig = config }) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.blue)
                        .help("编辑")

                        Button { viewModel.cloneProxyConfig(config) } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.borderless)
                        .help("克隆代理服务器")
                        .accessibilityLabel("克隆代理服务器")

                        Button(action: { confirmDelete(config) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                        .help("删除")
                    }
                }
                .width(90)
            }
            // 通过原生表格的主操作处理双击，行内按钮仍可独立使用。
            .contextMenu(forSelectionType: String.self) { ids in
                if let config = viewModel.proxyConfigs.first(where: { ids.contains($0.id) }) {
                    Button("编辑") { editingConfig = config }
                    Button("克隆") { viewModel.cloneProxyConfig(config) }
                    Button("删除", role: .destructive) { confirmDelete(config) }
                }
            } primaryAction: { ids in
                editingConfig = viewModel.proxyConfigs.first { ids.contains($0.id) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
                    .allowsHitTesting(false)
            }
            .padding(12)
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func confirmDelete(_ config: ProxyBridgeViewModel.ProxyConfig) {
        affectedRulesCount = viewModel.rulesUsingProxy(id: config.id)
        deletingConfig = config
    }

    private func typeColor(_ type: String) -> Color {
        type.lowercased() == "socks5" ? .cyan : .orange
    }
}

struct ProxyConfigEditorView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    var existing: ProxyBridgeViewModel.ProxyConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var configName = ""
    @State private var proxyType = "socks5"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sendDomain = false
    @State private var testHost = ProxyBridgeViewModel.ProxyConfig.defaultTestHost
    @State private var testPort = String(ProxyBridgeViewModel.ProxyConfig.defaultTestPort)
    @State private var validationError = ""

    private let proxyTypes = ["socks5"]
    private var isSaveDisabled: Bool {
        proxyHost.isEmpty || proxyPort.isEmpty || !validationError.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "network")
                    .font(.headline)
                    .foregroundColor(.accentColor)
                Text(existing == nil ? "添加代理服务器" : "编辑代理服务器")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Form {
                Section {
                    formTextField(label: "名称", placeholder: "选填，例如家庭代理", text: $configName)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("代理协议").fontWeight(.medium); Text("*").foregroundColor(.red) }
                        Picker("选择代理协议", selection: $proxyType) {
                            ForEach(proxyTypes, id: \.self) { type in
                                Text(type.uppercased()).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.vertical, 3)

                    formTextField(label: "服务器 IP 或域名", placeholder: "127.0.0.1 或 proxy.example.com", text: $proxyHost, required: true)
                        .onChange(of: proxyHost) { _ in validateInputs() }
                    formTextField(label: "服务器端口", placeholder: "1080", text: $proxyPort, required: true)
                        .onChange(of: proxyPort) { _ in validateInputs() }
                    formTextField(label: "用户名", placeholder: "无需认证时留空", text: $username)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("密码").fontWeight(.medium)
                        SecureField("无需认证时留空", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, 3)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("由代理服务器解析域名", isOn: $sendDomain)
                        Text("开启后向代理发送域名，关闭后发送 IP 地址。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("请在“设置”菜单中开启 DNS 代理以发送域名。")
                            .font(.caption)
                            .foregroundColor(viewModel.isDNSEnabled ? .secondary : .orange)
                    }
                    .padding(.vertical, 3)

                    // 测试目标仅供连通性检查使用，与代理服务器自身的地址和端口独立。
                    formTextField(label: "测试地址", placeholder: "IP 地址或域名", text: $testHost, required: true)
                        .onChange(of: testHost) { _ in validateInputs() }
                    formTextField(label: "测试端口", placeholder: "80", text: $testPort, required: true)
                        .onChange(of: testPort) { _ in validateInputs() }

                    if !validationError.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(validationError).font(.caption).foregroundColor(.red)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaveDisabled)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .controlSize(.small)
        .frame(width: 500, height: 565)
        .onAppear {
            if let e = existing {
                configName = e.name
                proxyType = e.type
                proxyHost = e.host
                proxyPort = String(e.port)
                username = e.username ?? ""
                password = e.password ?? ""
                sendDomain = e.sendDomain
                testHost = e.testHost
                testPort = String(e.testPort)
            }
            validateInputs()
        }
    }

    @ViewBuilder
    private func formTextField(label: String, placeholder: String, text: Binding<String>, required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).fontWeight(.medium)
                if required { Text("*").foregroundColor(.red) }
            }
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 3)
    }

    private func validateInputs() {
        if !proxyHost.isEmpty {
            let validCharsIPv6 = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
            let isIPv6 = proxyHost.rangeOfCharacter(from: validCharsIPv6.inverted) == nil && proxyHost.contains(":")
            let ipv4Parts = proxyHost.split(separator: ".")
            let isIPv4 = ipv4Parts.count == 4 && ipv4Parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
            let domainPattern = "^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)*[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?$"
            let isDomain = NSPredicate(format: "SELF MATCHES %@", domainPattern).evaluate(with: proxyHost) || proxyHost == "localhost"
            if !isIPv4 && !isIPv6 && !isDomain {
                validationError = "请输入有效的 IP 地址或域名"
                return
            }
        }
        if !proxyPort.isEmpty {
            if let port = Int(proxyPort) {
                if port < 1 || port > 65535 {
                    validationError = "端口必须介于 1 和 65535 之间"
                    return
                }
            } else {
                validationError = "请输入数字端口"
                return
            }
        }
        if !ProxyCheckerModel.isValidTestHost(testHost.trimmingCharacters(in: .whitespacesAndNewlines)) {
            validationError = "请输入有效的测试 IP 地址或域名"
            return
        }
        guard let port = Int(testPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            validationError = "测试端口必须介于 1 和 65535 之间"
            return
        }
        validationError = ""
    }

    private func save() {
        guard let port = Int(proxyPort) else { return }
        let config = ProxyBridgeViewModel.ProxyConfig(
            id: existing?.id ?? UUID().uuidString,
            name: configName.trimmingCharacters(in: .whitespaces),
            type: proxyType,
            host: proxyHost,
            port: port,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            sendDomain: sendDomain,
            testHost: testHost.trimmingCharacters(in: .whitespacesAndNewlines),
            testPort: Int(testPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ProxyBridgeViewModel.ProxyConfig.defaultTestPort
        )
        if existing != nil {
            viewModel.updateProxyConfig(config)
        } else {
            viewModel.addProxyConfig(config)
        }
    }
}
