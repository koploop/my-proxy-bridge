import AppKit
import CryptoKit

/// 通过用户授权的书签访问外部目录，保存可随应用重装保留的方案快照。
enum ProfileDirectory {
    private static let containerModeKey = "useICloudProfileContainer"

    // 系统按签名权限解析默认容器，容器目录无需通过文件选择器授权。
    private static func containerFolder() throws -> URL {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw NSError(domain: "ProfileDirectory", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法访问 iCloud 容器。请确认已登录 iCloud、启用 iCloud Drive，并使用带容器权限的签名版本。"
            ])
        }
        return root.appendingPathComponent("Documents/ProxyBridge", isDirectory: true)
    }

    static func useContainer() throws {
        let folder = try containerFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try loadOrMigrate(folder)
        UserDefaults.standard.set(true, forKey: containerModeKey)
    }

    private static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/proxyBridge", isDirectory: true)
    }

    private static let bookmarkKey = "profileDirectoryBookmark"

    private static func isProfileKey(_ key: String) -> Bool {
        ["profiles", "activeProfile", "proxyConfigs", "proxyRules", "trafficLoggingEnabled",
         "dnsEnabled", "runAtStartup", "closeToMenuBar"].contains(key) || key.hasPrefix("profile.")
    }

    // 由系统面板授权 iCloud Drive 文件夹，配置同步交给 Finder。
    static var iCloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func authorize(inICloud: Bool = false) throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = inICloud ? "选择 iCloud Drive 配置目录" : "选择配置目录"
        panel.message = inICloud ? "请在 iCloud Drive 中选择或新建代理桥文件夹。" : "请选择或新建 ~/.config/proxyBridge。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = inICloud ? iCloudDriveURL : defaultFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: .withSecurityScope)
        try loadOrMigrate(folder)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(false, forKey: containerModeKey)
        return true
    }

    private static func loadOrMigrate(_ folder: URL) throws {
        let file = folder.appendingPathComponent("profiles.plist")
        let index = folder.appendingPathComponent(".proxybridge-index.plist")
        let metadata = (try? read(index)) ?? [:]
        let previousNames = metadata["profiles"] as? [String] ?? []
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        let fields = ["proxyConfigs", "proxyRules", "trafficLoggingEnabled", "dnsEnabled", "runAtStartup", "closeToMenuBar"]
        var found: [String: [String: Any]] = [:]
        // 文件决定哪些方案存在，旧索引仅用于排序、定位旧文件和恢复当前方案。
        for candidate in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let attributes = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  candidate.lastPathComponent.lowercased() != "profiles.plist" else { continue }
            let stem = candidate.deletingPathExtension().lastPathComponent
            let name = previousNames.first {
                legacyProfileFile($0, in: folder).lastPathComponent == candidate.lastPathComponent
            } ?? stem
            guard validProfileName(name) || previousNames.contains(name) else { continue }
            do {
                var profile: [String: Any]
                switch candidate.pathExtension.lowercased() {
                case "plist":
                    profile = try read(candidate)
                case "ppx", "pbprofile":
                    // 同名原生文件优先，避免每次扫描都用导入文件覆盖已编辑的方案。
                    if FileManager.default.fileExists(atPath: profileFile(name, in: folder).path) { continue }
                    let data = try Data(contentsOf: candidate)
                    let native = candidate.pathExtension.lowercased() == "ppx"
                        ? try ProxifierProfile.importData(data, name: name) : data
                    guard let decoded = try JSONSerialization.jsonObject(with: native) as? [String: Any] else { continue }
                    profile = decoded
                    if let configs = decoded["proxyConfigs"] as? [[String: Any]] {
                        profile["proxyConfigs"] = try JSONSerialization.data(withJSONObject: configs)
                    }
                default: continue
                }
                var values: [String: Any] = [:]
                for field in fields {
                    let suffix = "." + field
                    values[field] = profile[field] ?? profile["profile.\(name).\(field)"]
                        ?? profile.first { $0.key.hasPrefix("profile.") && $0.key.hasSuffix(suffix) }?.value
                }
                guard values["proxyConfigs"] is Data || values["proxyRules"] is [[String: Any]] else { continue }
                if found.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
                found[name] = values
            } catch {
                NSLog("无法读取方案 %@：%@", candidate.lastPathComponent, error.localizedDescription)
            }
        }
        if !found.isEmpty || FileManager.default.fileExists(atPath: index.path) {
            let names = previousNames.filter { found[$0] != nil }
                + found.keys.filter { !previousNames.contains($0) }.sorted()
            let preferred = metadata["activeProfile"] as? String
            let active = names.first { $0 == preferred } ?? names.first
            var snapshot: [String: Any] = ["profiles": names]
            snapshot["activeProfile"] = active
            for (name, values) in found {
                for (field, value) in values {
                    snapshot["profile.\(name).\(field)"] = value
                    if name == active { snapshot[field] = value }
                }
            }
            apply(snapshot)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            try write(to: folder)
            return
        }
        guard let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              snapshot["profiles"] is [String] else { throw CocoaError(.fileReadCorruptFile) }
        apply(snapshot)
        // 保留旧文件作为迁移备份。索引写入成功后，下次启动读取独立文件。
        try write(to: folder)
    }

    private static func apply(_ snapshot: [String: Any]) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where isProfileKey(key) && snapshot[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in snapshot where isProfileKey(key) {
            defaults.set(value, forKey: key)
        }
    }

    static func restore() {
        access { try loadOrMigrate($0) }
    }

    static func save() {
        access { try write(to: $0) }
    }

    private static func access(_ operation: (URL) throws -> Void) {
        do {
            try accessDirectory(operation)
        } catch {
            NSLog("无法访问代理桥配置目录：%@", error.localizedDescription)
        }
    }

    private static func accessDirectory(_ operation: (URL) throws -> Void) throws {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: containerModeKey) {
            try operation(containerFolder())
            return
        }
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            // 无自选目录时使用默认位置。沙盒构建仍可通过选择器授权该目录。
            try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try operation(defaultFolder)
            return
        }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try operation(folder)
        if stale { defaults.set(try folder.bookmarkData(options: .withSecurityScope), forKey: bookmarkKey) }
    }

    static func manage() throws -> Bool {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: containerModeKey), defaults.data(forKey: bookmarkKey) == nil {
            do {
                try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try loadOrMigrate(defaultFolder)
            } catch {
                // 无法直接访问默认目录时，交给界面打开授权选择器。
                return false
            }
        }
        try accessDirectory { folder in
            guard NSWorkspace.shared.open(folder) else { throw CocoaError(.fileReadUnknown) }
        }
        return true
    }

    static func validProfileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 240
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil
            && name.caseInsensitiveCompare("profiles") != .orderedSame
    }

    private static func profileFile(_ name: String, in folder: URL) -> URL {
        // 旧方案可能包含不可作为文件名使用的字符，继续保留其安全路径。
        guard validProfileName(name) else { return legacyProfileFile(name, in: folder) }
        return folder.appendingPathComponent(name + ".plist")
    }

    private static func legacyProfileFile(_ name: String, in folder: URL) -> URL {
        // 转义路径字符，并用摘要区分大小写不同或截断后重名的方案。
        let readable = String(name.map { $0 == "/" || $0 == ":" ? "_" : $0 }.prefix(36))
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("方案-\(readable)-\(digest).plist")
    }

    private static func read(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return values
    }

    private static func write(to folder: URL) throws {
        let snapshot = UserDefaults.standard.dictionaryRepresentation().filter { isProfileKey($0.key) }
        guard let names = snapshot["profiles"] as? [String], !names.isEmpty else { return }
        let active = snapshot["activeProfile"] as? String
        let fields = ["proxyConfigs", "proxyRules", "trafficLoggingEnabled", "dnsEnabled", "runAtStartup", "closeToMenuBar"]
        let index = folder.appendingPathComponent(".proxybridge-index.plist")
        let previousNames = FileManager.default.fileExists(atPath: index.path) ? (try read(index)["profiles"] as? [String] ?? []) : []
        for name in names {
            var profile: [String: Any] = [:]
            for field in fields {
                let key = "profile.\(name).\(field)"
                profile[key] = snapshot[name == active ? field : key]
            }
            let rulesKey = "profile.\(name).proxyRules"
            if profile[rulesKey] == nil { profile[rulesKey] = [[String: Any]]() }
            try write(profile, to: profileFile(name, in: folder))
        }
        // 索引只记录方案顺序及当前方案，实际配置由各自的文件保存。
        var metadata: [String: Any] = ["profiles": names]
        metadata["activeProfile"] = active
        try write(metadata, to: index)
        for name in previousNames where !names.contains(name) {
            for file in Set([profileFile(name, in: folder), legacyProfileFile(name, in: folder)]) {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        }
    }

    private static func write(_ snapshot: [String: Any], to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        // 配置可能包含认证信息，先写入私有临时文件，再原子替换。
        let temporary = folder.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, file.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
