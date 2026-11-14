import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers
import AppKit

struct ProxyRule: Identifiable, Codable {
    var localId: String
    var name: String
    let processNames: String
    let targetHosts: String
    let targetPorts: String
    let ruleProtocol: String
    var action: String
    var enabled: Bool

    // localId is the stable gui side identity, ruleId in the extension is not stable
    var id: String { localId }

    enum CodingKeys: String, CodingKey {
        case localId
        case name
        case processNames
        case targetHosts
        case targetPorts
        case ruleProtocol = "protocol"
        case action
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.localId = try c.decodeIfPresent(String.self, forKey: .localId) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.processNames = try c.decode(String.self, forKey: .processNames)
        self.targetHosts = try c.decode(String.self, forKey: .targetHosts)
        self.targetPorts = try c.decode(String.self, forKey: .targetPorts)
        self.ruleProtocol = try c.decode(String.self, forKey: .ruleProtocol)
        self.action = try c.decode(String.self, forKey: .action)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // drop localId on export so imported rules get fresh ids
        try c.encode(name, forKey: .name)
        try c.encode(processNames, forKey: .processNames)
        try c.encode(targetHosts, forKey: .targetHosts)
        try c.encode(targetPorts, forKey: .targetPorts)
        try c.encode(ruleProtocol, forKey: .ruleProtocol)
        try c.encode(action, forKey: .action)
        try c.encode(enabled, forKey: .enabled)
    }

    init(localId: String = UUID().uuidString, name: String = "", processNames: String, targetHosts: String, targetPorts: String, ruleProtocol: String, action: String, enabled: Bool) {
        self.localId = localId
        self.name = name
        self.processNames = processNames
        self.targetHosts = targetHosts
        self.targetPorts = targetPorts
        self.ruleProtocol = ruleProtocol
        self.action = action
        self.enabled = enabled
    }

    // UserDefaults stores rules as plain dictionaries, these bridge to that
    init(dict: [String: Any]) {
        self.localId = dict["localId"] as? String ?? UUID().uuidString
        self.name = dict["name"] as? String ?? ""
        self.processNames = dict["processNames"] as? String ?? ""
        self.targetHosts = dict["targetHosts"] as? String ?? ""
        self.targetPorts = dict["targetPorts"] as? String ?? ""
        self.ruleProtocol = dict["protocol"] as? String ?? "BOTH"
        self.action = dict["action"] as? String ?? "DIRECT"
        self.enabled = dict["enabled"] as? Bool ?? true
    }

    func toDict() -> [String: Any] {
        return [
            "localId": localId,
            "name": name,
            "processNames": processNames,
            "targetHosts": targetHosts,
            "targetPorts": targetPorts,
            "protocol": ruleProtocol,
            "action": action,
            "enabled": enabled
        ]
    }
}

struct ProxyRulesView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @State private var rules: [ProxyRule] = []
    @State private var showAddRule = false
    @State private var editingRule: ProxyRule?
    @State private var draggingRuleId: String?
    @State private var dragStartIndex: Int?
    @State private var dragOffset: CGFloat = 0
    private let ruleRowHeight: CGFloat = 32
    @State private var reorderSync: Task<Void, Never>?
    @State private var ruleToDelete: ProxyRule?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("代理规则")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("\(rules.count) 条 · 自上而下匹配")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Button(action: { exportRules() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出规则")
                    }

                }
                .disabled(rules.isEmpty)
                
                Button(action: { importRulesFromFile() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入")
                    }

                }
                
                Button(action: { showAddRule = true }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("添加规则")
                    }

                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            
            if rules.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.gray)
                    Text("尚未配置代理规则")
                        .font(.title3)
                        .foregroundColor(.gray)
                    Text("点击“添加规则”创建分流规则")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ruleList
            }
        }
        .controlSize(.small)
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            loadRules()
        }
        // reload when the active profile changes so an open window isn't stale
        .onChange(of: viewModel.activeProfile) { _ in
            draggingRuleId = nil
            dragStartIndex = nil
            dragOffset = 0
            reorderSync?.cancel()
            editingRule = nil
            ruleToDelete = nil
            showAddRule = false
            loadRules()
        }
        .alert("删除规则？", isPresented: Binding(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        ), presenting: ruleToDelete) { rule in
            Button("删除", role: .destructive) { deleteRule(rule) }
            Button("取消", role: .cancel) {}
        } message: { rule in
            Text(rule.name.isEmpty ? "未命名规则" : rule.name)
        }
        .sheet(isPresented: $showAddRule) {
            RuleEditorView(viewModel: viewModel, onCommit: { commitRule($0) })
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(viewModel: viewModel, existingRule: rule, onCommit: { commitRule($0) })
        }
    }
    
    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("顺序").frame(width: 46)
                Text("启用").frame(width: 44)
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("应用").frame(maxWidth: .infinity, alignment: .leading)
                Text("目标主机").frame(maxWidth: .infinity, alignment: .leading)
                Text("端口").frame(width: 65, alignment: .leading)
                Text("协议").frame(width: 50, alignment: .leading)
                Text("动作").frame(width: 145, alignment: .leading)
                Text("操作").frame(width: 116)
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
            .background(Color(nsColor: .controlBackgroundColor))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                // 固定行高用于计算指针跨过的行。规则顺序在拖动过程中即时预览。
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(rule, index: index)
                            .offset(y: draggingRuleId == rule.id ? dragOffset : 0)
                            .zIndex(draggingRuleId == rule.id ? 1 : 0)
                    }
                }
                .coordinateSpace(name: "ruleList")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(12)
    }

    private func ruleRow(_ rule: ProxyRule, index: Int) -> some View {
        let isDragging = draggingRuleId == rule.id
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .monospacedDigit()
                    .frame(width: 46)
                Toggle("启用规则", isOn: binding(for: rule))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(width: 44)
                Text(rule.name.isEmpty ? "未命名" : rule.name).frame(maxWidth: .infinity, alignment: .leading)
                Text(rule.processNames.isEmpty ? "任意" : rule.processNames).frame(maxWidth: .infinity, alignment: .leading)
                Text(rule.targetHosts.isEmpty ? "任意" : rule.targetHosts)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(rule.targetHosts)
                Text(rule.targetPorts.isEmpty ? "任意" : rule.targetPorts).frame(width: 65, alignment: .leading)
                Text(rule.ruleProtocol).frame(width: 50, alignment: .leading)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { editingRule = rule }
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("ruleList"))
                .onChanged { value in
                    guard draggingRuleId == nil || draggingRuleId == rule.id,
                          let current = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                    if dragStartIndex == nil {
                        dragStartIndex = current
                        draggingRuleId = rule.id
                    }
                    guard let start = dragStartIndex else { return }
                    // 越过相邻行中心即换位。浮起的行抵消布局位移，继续跟随指针。
                    let distance = value.translation.height
                    let target = min(max(start + Int((distance / ruleRowHeight).rounded()), 0), rules.count - 1)
                    dragOffset = distance - CGFloat(target - start) * ruleRowHeight
                    if current != target {
                        withAnimation(.easeOut(duration: 0.12)) {
                            let moving = rules.remove(at: current)
                            rules.insert(moving, at: target)
                        }
                    }
                }
                .onEnded { _ in
                    guard draggingRuleId == rule.id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        draggingRuleId = nil
                        dragStartIndex = nil
                        dragOffset = 0
                    }
                    saveAndSync()
                }, including: .gesture)

            Menu {
                Button("直连") { changeAction("DIRECT", for: rule) }
                Button("阻止") { changeAction("BLOCK", for: rule) }
                ForEach(viewModel.proxyConfigs) { config in
                    Button(config.displayName) { changeAction(config.id, for: rule) }
                        .disabled(rule.ruleProtocol != "TCP" && config.type.lowercased() != "socks5")
                }
            } label: {
                Text(actionDisplayName(rule.action))
                    .foregroundStyle(actionColor(rule.action))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 145, alignment: .leading)

            HStack(spacing: 8) {
                Button { moveRule(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("上移规则")
                Button { moveRule(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == rules.count - 1).help("下移规则")
                Button { editingRule = rule } label: { Image(systemName: "pencil") }
                    .help("编辑规则")
                Button { cloneRule(rule) } label: { Image(systemName: "plus.square.on.square") }
                    .help("克隆规则")
                    .accessibilityLabel("克隆规则")
                Button { ruleToDelete = rule } label: { Image(systemName: "trash") }
                    .help("删除规则")
            }
            .buttonStyle(.borderless)
            .frame(width: 116)
        }
        .padding(.horizontal, 8)
        .frame(height: ruleRowHeight)
        // 使用系统交替行底色，让浅色和深色模式都能清楚区分相邻规则。
        .background {
            let stripes = NSColor.alternatingContentBackgroundColors
            Color(nsColor: stripes[index % stripes.count])
                .overlay(isDragging ? Color.accentColor.opacity(0.18) : .clear)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45).allowsHitTesting(false)
        }
        .shadow(color: isDragging ? .black.opacity(0.24) : .clear, radius: 5, y: 2)
        .contextMenu {
            Button("编辑规则") { editingRule = rule }
            Button("克隆规则") { cloneRule(rule) }
            Button("删除规则", role: .destructive) { ruleToDelete = rule }
        }
    }

    private func binding(for rule: ProxyRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                toggleRule(rule, enabled: newValue)
            }
        )
    }
    
    // 只更新动作字段，保持当前列表顺序和规则的其他匹配条件。
    private func changeAction(_ action: String, for rule: ProxyRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }),
              rules[index].action != action else { return }
        rules[index].action = action
        saveAndSync()
    }

    private func actionColor(_ action: String) -> Color {
        switch action {
        case "BLOCK": return .red
        case "DIRECT": return .blue
        default: return .green  // any proxy config UUID
        }
    }

    private func actionDisplayName(_ action: String) -> String {
        switch action {
        case "DIRECT": return "直连"
        case "BLOCK": return "阻止"
        default:
            return viewModel.proxyConfigs.first(where: { $0.id == action })?.displayName ?? action
        }
    }
    
    // 界面在 UserDefaults 中保存规则，扩展持有运行时副本。
    private func loadRules() {
        let dicts = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        rules = dicts.map { ProxyRule(dict: $0) }
    }

    private func moveRule(from: Int, to: Int) {
        withAnimation(.easeInOut(duration: 0.16)) {
            let rule = rules.remove(at: from)
            rules.insert(rule, at: to)
        }
        // 立即保存顺序，连续移动时只向扩展同步最后一次结果。
        UserDefaults.standard.set(rules.map { $0.toDict() }, forKey: "proxyRules")
        ProfileDirectory.save()
        reorderSync?.cancel()
        reorderSync = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let session = viewModel.tunnelSession else { return }
            RuleManager.resyncRules(session: session) { _, _ in }
        }
    }

    // 保存列表顺序。隧道运行时将完整规则列表同步到扩展。
    private func saveAndSync() {
        UserDefaults.standard.set(rules.map { $0.toDict() }, forKey: "proxyRules")
        ProfileDirectory.save()
        if let session = viewModel.tunnelSession {
            RuleManager.resyncRules(session: session) { _, _ in }
        }
    }

    func commitRule(_ rule: ProxyRule) {
        if let index = rules.firstIndex(where: { $0.localId == rule.localId }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        saveAndSync()
    }

    private func cloneRule(_ rule: ProxyRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        // 副本沿用匹配条件和动作，使用独立标识，并插入原规则下方。
        var copy = rules[index]
        copy.localId = UUID().uuidString
        copy.name = copy.name.isEmpty ? "未命名规则（副本）" : "\(copy.name)（副本）"
        rules.insert(copy, at: index + 1)
        saveAndSync()
    }

    private func deleteRule(_ rule: ProxyRule) {
        rules.removeAll { $0.localId == rule.localId }
        saveAndSync()
    }

    private func toggleRule(_ rule: ProxyRule, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.localId == rule.localId }) else { return }
        rules[index].enabled = enabled
        saveAndSync()
    }
    
    // 按列表顺序导出当前方案的全部规则，保留规则优先级。
    private func exportRules() {
        guard !rules.isEmpty else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "导出代理规则"
        savePanel.message = "Choose a location to save the selected rules"
        savePanel.nameFieldStringValue = "ProxyBridge-Rules.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        
        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)
            try data.write(to: url)
        } catch {
            print("Export failed: \(error)")
        }
    }
    
    private func importRulesFromFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "导入代理规则"
        openPanel.message = "Choose a rules file to import"
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        
        let response = openPanel.runModal()
        guard response == .OK, let url = openPanel.urls.first else { return }
        
        importRules(from: url)
    }
    
    private func importRules(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let importedRules = try JSONDecoder().decode([ProxyRule].self, from: data)
            // decode drops localId so each imported rule already has a fresh one
            rules.append(contentsOf: importedRules)
            saveAndSync()
        } catch {
            print("Failed to import rules: \(error)")
        }
    }
}

struct RuleEditorView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    var existingRule: ProxyRule?
    var onCommit: (ProxyRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ruleName: String
    @State private var processNames: String
    @State private var targetHosts: String
    @State private var targetPorts: String
    @State private var selectedProtocol: String
    @State private var selectedAction: String

    private var isEditMode: Bool { existingRule != nil }

    init(viewModel: ProxyBridgeViewModel, existingRule: ProxyRule? = nil, onCommit: @escaping (ProxyRule) -> Void) {
        self.viewModel = viewModel
        self.existingRule = existingRule
        self.onCommit = onCommit

        _ruleName = State(initialValue: existingRule?.name ?? "")
        _processNames = State(initialValue: existingRule?.processNames ?? "*")
        // 现有分号格式在编辑器中逐行显示，保存时再转回匹配器支持的格式。
        _targetHosts = State(initialValue: (existingRule?.targetHosts ?? "*")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n"))
        _targetPorts = State(initialValue: existingRule?.targetPorts ?? "*")
        _selectedProtocol = State(initialValue: existingRule?.ruleProtocol ?? "TCP")
        // default to first proxy config if there is one, otherwise direct
        let defaultAction = existingRule?.action ?? viewModel.proxyConfigs.first?.id ?? "DIRECT"
        _selectedAction = State(initialValue: defaultAction)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(isEditMode ? "编辑规则" : "添加规则")
                .font(.headline)
                .fontWeight(.semibold)

            Form {
                Section {
                    formField(
                        label: "规则名称",
                        placeholder: "选填，例如工作流量",
                        text: $ruleName,
                        hint: "用于在列表中识别规则，可留空。"
                    )

                    formField(
                        label: "进程名或应用包标识符",
                        placeholder: "*",
                        text: $processNames,
                        hint: "匹配包标识符或进程名，例如 com.apple.Safari; curl; Google Chrome Helper; *chrome*; *"
                    )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标主机").fontWeight(.medium)
                        TextEditor(text: $targetHosts)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 76, idealHeight: 92)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                            .accessibilityLabel("目标主机")
                        Text("每行一个主机，也可用分号分隔。留空匹配任意主机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isDNSEnabled ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundColor(viewModel.isDNSEnabled ? .secondary : .orange)
                        Text(viewModel.isDNSEnabled
                             ? "启用 DNS 代理后可匹配域名，IP 地址始终可匹配。"
                             : "DNS 代理已关闭，目前只能按 IP 地址匹配目标主机。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    
                    formField(
                        label: "目标端口",
                        placeholder: "*",
                        text: $targetPorts,
                        hint: "例如 80; 8000-9000; 3128"
                    )

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text("目标主机和端口条件仅适用于 TCP。UDP 按应用的包标识符匹配。")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("协议")
                            .fontWeight(.medium)
                        Picker("", selection: $selectedProtocol) {
                            Text("TCP").tag("TCP")
                            Text("UDP").tag("UDP")
                            Text("TCP 和 UDP").tag("BOTH")
                        }
                        .pickerStyle(.segmented)
                        if selectedProtocol == "UDP" || selectedProtocol == "BOTH" {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                Text("UDP 转发要求 SOCKS5 服务器支持 UDP ASSOCIATE。QUIC 和 HTTP/3 请单独测试。")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("动作")
                            .fontWeight(.medium)
                        Picker("", selection: $selectedAction) {
                            Text("直连").tag("DIRECT")
                            Text("阻止").tag("BLOCK")
                            if !viewModel.proxyConfigs.isEmpty {
                                Divider()
                                ForEach(viewModel.proxyConfigs) { config in
                                    Text(config.displayName).tag(config.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        if selectedProtocol == "UDP" || selectedProtocol == "BOTH" {
                            let isHttp = viewModel.proxyConfigs.first(where: { $0.id == selectedAction })?.type.lowercased() == "http"
                            if isHttp {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                    Text("UDP 转发需要 SOCKS5 代理。")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        if viewModel.proxyConfigs.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle").foregroundColor(.secondary)
                                Text("请先在“代理服务器”中添加 SOCKS5 服务器。")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存规则") {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding(12)
        .controlSize(.small)
        .frame(width: 560, height: 570)
    }
    
    @ViewBuilder
    private func formField(label: String, placeholder: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .fontWeight(.medium)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func saveRule() {
        let rule = ProxyRule(
            localId: existingRule?.localId ?? UUID().uuidString,
            name: ruleName.trimmingCharacters(in: .whitespaces),
            processNames: processNames,
            targetHosts: targetHosts.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";")))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; "),
            targetPorts: targetPorts,
            ruleProtocol: selectedProtocol,
            action: selectedAction,
            enabled: existingRule?.enabled ?? true
        )
        onCommit(rule)
        dismiss()
    }
}

struct RulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    var rules: [ProxyRule]
    
    init(rules: [ProxyRule]) {
        self.rules = rules
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        rules = try decoder.decode([ProxyRule].self, from: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        return FileWrapper(regularFileWithContents: data)
    }
}
