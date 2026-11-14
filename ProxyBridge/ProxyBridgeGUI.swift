import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

// launch-at-login. the desired state lives in the "runAtStartup" working key so
// it can be part of a profile, and applyToSystem keeps the real login item in sync
enum LoginItem {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "runAtStartup") }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "runAtStartup")
        applyToSystem(enabled)
    }

    static func applyToSystem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // registration can fail if the app isn't in /Applications, ignore
        }
    }
}

// 外观是应用级偏好，覆盖 SwiftUI 窗口和 AppKit 对话框。
private enum InterfaceAppearance: String, CaseIterable {
    static let storageKey = "interfaceAppearance"
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    func apply(to application: NSApplication) {
        switch self {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// no @main here, main.swift starts this for a normal launch (and the command line mode otherwise)
struct ProxyBridgeGUIApp: App {
    @StateObject private var viewModel = ProxyBridgeViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage(InterfaceAppearance.storageKey) private var interfaceAppearance = InterfaceAppearance.system
    @AppStorage("showStatusBarIcon") private var showStatusBarIcon = true
    @AppStorage("keepDockIconInBackground") private var keepDockIconInBackground = true

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, profileActions: AnyView(Group {
                Button("新建配置方案…") {
                    promptProfileName(title: "新建配置方案", message: "请输入新配置方案的名称。") { viewModel.createProfile($0) }
                }
                profileActions
            }), settingsActions: AnyView(settingsActions))
                .background(WindowAccessor())
                .onAppear {
                    AppDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu("代理") {
                Button("代理服务器…") {
                    openProxySettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button("代理规则…") {
                    openProxyRulesWindow()
                }
                .keyboardShortcut("r", modifiers: .command)
                
                Divider()
                
                Toggle("记录连接日志", isOn: Binding(
                    get: { viewModel.isTrafficLoggingEnabled },
                    set: { _ in viewModel.toggleTrafficLogging() }
                ))


            }

            CommandMenu("配置方案") {
                // 菜单栏和主窗口都由当前方案驱动单选勾选状态。
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

                Button("新建配置方案…") {
                    promptProfileName(title: "新建配置方案", message: "请输入新配置方案的名称。") {
                        viewModel.createProfile($0)
                    }
                }

                Button("重命名 \"\(viewModel.activeProfile)\"...") {
                    promptProfileName(title: "重命名配置方案", message: "请输入新名称。", defaultText: viewModel.activeProfile) {
                        viewModel.renameProfile(viewModel.activeProfile, to: $0)
                    }
                }

                Button("删除 \"\(viewModel.activeProfile)\"") {
                    viewModel.deleteProfile(viewModel.activeProfile)
                }
                .disabled(viewModel.profiles.count <= 1)

                Divider()

                profileActions
            }

            CommandMenu("设置") {
                settingsActions
            }

            CommandGroup(replacing: .help) {
                Button("参考项目文档") {
                    if let url = URL(string: "https://interceptsuite.com/docs/proxybridge/") {
                        NSWorkspace.shared.open(url)
                    }
                }


                Divider()

                Button("关于代理桥") {
                    openAboutWindow()
                }
            }
        }
        
        Window("代理服务器", id: "proxy-settings") {
            ProxySettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Window("代理规则", id: "proxy-rules") {
            ProxyRulesView(viewModel: viewModel)
        }
        .defaultPosition(.center)
        
        Window("关于代理桥", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
    }
    
    private func openProxySettingsWindow() {
        NSApp.sendAction(#selector(AppDelegate.openProxySettings), to: nil, from: nil)
    }
    
    private func openProxyRulesWindow() {
        NSApp.sendAction(#selector(AppDelegate.openProxyRules), to: nil, from: nil)
    }
    
    private func openAboutWindow() {
        NSApp.sendAction(#selector(AppDelegate.openAbout), to: nil, from: nil)
    }
    

    // 菜单栏和主窗口共用相同的保存及文件操作。
    // 主窗口和菜单栏共用设置，确保两处的开关状态一致。
    private var settingsActions: some View {
        Group {
            Button("选择配置目录…") {
                do {
                    if try ProfileDirectory.authorize() { viewModel.reloadAuthorizedProfiles() }
                } catch {
                    showProfileError(error.localizedDescription)
                }
            }
            Button("使用应用的 iCloud 容器…") {
                do {
                    try ProfileDirectory.useContainer()
                    viewModel.reloadAuthorizedProfiles()
                } catch {
                    showProfileError(error.localizedDescription)
                }
            }
            Button("使用 iCloud Drive 配置目录…") {
                do {
                    if try ProfileDirectory.authorize(inICloud: true) { viewModel.reloadAuthorizedProfiles() }
                } catch {
                    showProfileError(error.localizedDescription)
                }
            }
                Picker("界面外观", selection: Binding(
                    get: { interfaceAppearance },
                    set: { appearance in
                        interfaceAppearance = appearance
                        appearance.apply(to: NSApp)
                    }
                )) {
                    ForEach(InterfaceAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.menu)
                Toggle("启用 DNS 代理", isOn: Binding(
                    get: { viewModel.isDNSEnabled },
                    set: { _ in viewModel.toggleDNS() }
                ))
                Toggle("在菜单栏显示代理桥", isOn: Binding(
                    get: { showStatusBarIcon },
                    set: { visible in
                        showStatusBarIcon = visible
                        AppDelegate.shared?.setStatusBarVisible(visible)
                    }
                ))
                Toggle("后台运行时保留 Dock 图标", isOn: $keepDockIconInBackground)
                Toggle("登录时启动", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }
                ))
                Toggle("记录连接日志", isOn: Binding(
                    get: { viewModel.isTrafficLoggingEnabled },
                    set: { _ in viewModel.toggleTrafficLogging() }
                ))
        }
    }

    private var profileActions: some View {
        Group {
            Button("保存配置方案") { viewModel.saveActiveProfile() }
            Button("配置方案另存为…") {
                promptProfileName(title: "配置方案另存为", message: "请输入新的配置方案名称。") {
                    if !viewModel.saveProfileAs($0) {
                        showProfileError("请输入尚未使用的配置方案名称。")
                    }
                }
            }
            Divider()
            Button("管理方案…") {
                do {
                    if try !ProfileDirectory.manage(), try ProfileDirectory.authorize() {
                        viewModel.reloadAuthorizedProfiles()
                        _ = try ProfileDirectory.manage()
                    }
                } catch {
                    showProfileError(error.localizedDescription)
                }
            }
            Button("导出代理桥配置（.pbprofile）…") { exportActiveProfile(asProxifier: false) }
            Button("导出 Proxifier 配置（.ppx）…") { exportActiveProfile(asProxifier: true) }
            Menu("iCloud Drive") {
                Button("从 iCloud 导入…") { importProfileFromFile(inICloud: true) }
                Button("导出代理桥配置到 iCloud…") { exportActiveProfile(asProxifier: false, inICloud: true) }
                Button("导出 Proxifier 配置到 iCloud…") { exportActiveProfile(asProxifier: true, inICloud: true) }
            }
            Button("导入配置方案…") { importProfileFromFile() }
        }
    }

    private func exportActiveProfile(asProxifier: Bool, inICloud: Bool = false) {
        let name = viewModel.activeProfile
        let fileExtension = asProxifier ? "ppx" : "pbprofile"
        let panel = NSSavePanel()
        if inICloud { panel.directoryURL = ProfileDirectory.iCloudDriveURL }
        panel.title = "导出配置方案"
        // 保存面板根据文件类型补上后缀，输入框只提供基本名称。
        let fileType = UTType(filenameExtension: fileExtension)
        panel.nameFieldStringValue = profileExportBaseName(name)
        panel.allowedContentTypes = [fileType ?? .data]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 用户也可能手动键入后缀。规范化写入路径，并确认最终路径上的同名文件。
        let exportURL = url.deletingLastPathComponent()
            .appendingPathComponent(profileExportBaseName(url.lastPathComponent) + "." + fileExtension)
        if exportURL != url, FileManager.default.fileExists(atPath: exportURL.path) {
            let alert = NSAlert()
            alert.messageText = "替换已有配置文件？"
            alert.informativeText = exportURL.lastPathComponent
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            guard let nativeData = viewModel.exportProfileData(name) else {
                throw ProxifierProfile.FormatError("无法读取当前配置方案。")
            }
            let data = asProxifier ? try ProxifierProfile.exportData(nativeData) : nativeData
            try data.write(to: exportURL, options: .atomic)
        } catch {
            showProfileError(error.localizedDescription)
        }
    }

    // 连续移除旧版本可能留下的重复后缀，保留名称中其他点号。
    private func profileExportBaseName(_ name: String) -> String {
        var baseName = name
        while ["ppx", "pbprofile", "json"].contains((baseName as NSString).pathExtension.lowercased()) {
            baseName = (baseName as NSString).deletingPathExtension
        }
        return baseName
    }

    private func importProfileFromFile(inICloud: Bool = false) {
        let panel = NSOpenPanel()
        if inICloud { panel.directoryURL = ProfileDirectory.iCloudDriveURL }
        panel.title = "导入配置方案（.pbprofile、.json 或 .ppx）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .xml] + ["pbprofile", "ppx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let profile = ["ppx", "xml"].contains(url.pathExtension.lowercased())
                ? try ProxifierProfile.importData(data, name: url.deletingPathExtension().lastPathComponent)
                : data
            guard viewModel.importProfile(from: profile) else {
                throw ProxifierProfile.FormatError("无法识别此配置方案。")
            }
        } catch {
            showProfileError(error.localizedDescription)
        }
    }

    private func showProfileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "配置方案操作失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // small AppKit text prompt, SwiftUI has no clean text-input alert on macOS
    private func promptProfileName(title: String, message: String, defaultText: String = "", onSubmit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            onSubmit(field.stringValue)
        }
    }

}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var viewModel: ProxyBridgeViewModel?
    static weak var shared: AppDelegate?
    static weak var mainWindow: NSWindow?
    // set at launch, tells WindowAccessor to keep the first window hidden
    static var startHidden = false

    private var statusItem: NSStatusItem?

    // 此偏好适用于整个应用，首次运行默认保留 Dock 图标。
    private var backgroundActivationPolicy: NSApplication.ActivationPolicy {
        let keepIcon = UserDefaults.standard.object(forKey: "keepDockIconInBackground") as? Bool ?? true
        // 隐藏菜单栏图标时保留 Dock 入口，方便恢复主窗口。
        return keepIcon || statusItem == nil ? .regular : .accessory
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let savedAppearance = UserDefaults.standard.string(forKey: InterfaceAppearance.storageKey) ?? ""
        (InterfaceAppearance(rawValue: savedAppearance) ?? .system).apply(to: NSApp)
        setStatusBarVisible(UserDefaults.standard.object(forKey: "showStatusBarIcon") as? Bool ?? true)
        // keep the real login item in sync with the active profile's setting
        LoginItem.applyToSystem(LoginItem.isEnabled)

        // a login-item / resume launch is not a "default" launch. if we got here
        // that way and startup is enabled, come up in the menu bar with no window
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !isDefaultLaunch && LoginItem.isEnabled {
            AppDelegate.startHidden = true
            NSApp.setActivationPolicy(backgroundActivationPolicy)
        }
    }

    // 主窗口隐藏后，菜单栏仍可打开窗口或主动退出应用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === AppDelegate.mainWindow else { return true }
        // 还有其他窗口可见时继续使用正常的 Dock 和菜单栏行为。
        sender.orderOut(nil)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
            NSApp.setActivationPolicy(backgroundActivationPolicy)
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // 点击 Dock 图标时恢复主窗口，包括主窗口隐藏但设置窗口仍打开的情况。
        guard let window = AppDelegate.mainWindow else { return true }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func setStatusBarVisible(_ visible: Bool) {
        if !visible {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            NSApp.setActivationPolicy(.regular)
            return
        }
        guard statusItem == nil else { return }

        // 打开菜单时读取当前状态，避免启停或切换方案后显示过期信息。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 模板图标跟随系统菜单栏颜色，手工构建包从资源目录加载同一图形。
        let icon = NSImage(named: "MenuBarIcon")
            ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "代理桥")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.setAccessibilityLabel("代理桥")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = AppDelegate.viewModel
        let status = NSMenuItem(title: model?.isProxyActive == true ? "代理运行中" :
                                (model?.isStartingProxy == true ? "正在启动代理…" : "代理未连接"),
                                action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("打开代理桥", #selector(showMainWindow)),
            (model?.isProxyActive == true ? "停止代理" : "启动代理", #selector(toggleStatusProxy)),
            ("代理服务器…", #selector(openProxySettings)),
            ("代理规则…", #selector(openProxyRules))
        ]
        for (title, action) in actions {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        if let model {
            let profiles = NSMenu()
            for name in model.profiles {
                let entry = NSMenuItem(title: name, action: #selector(selectStatusProfile(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = name
                entry.state = name == model.activeProfile ? .on : .off
                profiles.addItem(entry)
            }
            let entry = NSMenuItem(title: "配置方案", action: nil, keyEquivalent: "")
            entry.submenu = profiles
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出代理桥", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleStatusProxy() {
        guard let model = AppDelegate.viewModel, !model.isStartingProxy else { return }
        if model.isProxyActive {
            model.stopProxy()
        } else {
            model.installAndStartProxy()
        }
    }

    @objc private func selectStatusProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppDelegate.viewModel?.switchProfile(to: name)
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出前保存当前方案的最新规则和服务器配置。
        AppDelegate.viewModel?.saveActiveProfile()
        // Clear extension memory before app quits
        AppDelegate.viewModel?.stopProxy()

        // Give time for memory clearing to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
    
    @objc func openProxySettings() {
        openWindow(title: "代理服务器", size: NSSize(width: 880, height: 460), resizable: true) {
            ProxySettingsView(viewModel: AppDelegate.viewModel!)
        }
    }
    
    @objc func openProxyRules() {
        openWindow(title: "代理规则", size: NSSize(width: 1080, height: 520), resizable: true) {
            ProxyRulesView(viewModel: AppDelegate.viewModel!)
        }
    }
    
    @objc func openAbout() {
        openWindow(title: "关于代理桥", size: NSSize(width: 350, height: 205)) {
            AboutView()
        }
    }
    
    
    
    private func openWindow<Content: View>(
        title: String,
        size: NSSize,
        resizable: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == title }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: content())
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
            // 优先在主窗口所在屏幕居中，避开菜单栏和 Dock，并限制窗口初始尺寸。
            if resizable, let screen = AppDelegate.mainWindow?.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                let anchor = AppDelegate.mainWindow?.frame ?? visible
                window.setContentSize(NSSize(width: min(size.width, visible.width - 24),
                                             height: min(size.height, visible.height - 60)))
                let frame = window.frame
                window.setFrameOrigin(NSPoint(
                    x: max(visible.minX, min(anchor.midX - frame.width / 2, visible.maxX - frame.width)),
                    y: max(visible.minY, min(anchor.midY - frame.height / 2, visible.maxY - frame.height))
                ))
            } else {
                window.setContentSize(size)
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// grabs the main SwiftUI window so the app delegate can intercept its close
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppDelegate.mainWindow = window
            window.delegate = AppDelegate.shared
            // launched at login, keep it hidden in the menu bar
            if AppDelegate.startHidden {
                AppDelegate.startHidden = false
                window.orderOut(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

