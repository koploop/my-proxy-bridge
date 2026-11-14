import Foundation

/// 在 Proxifier XML 与代理桥的配置方案之间转换，规则顺序和代理引用一并保留。
enum ProxifierProfile {
    struct FormatError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func importData(_ data: Data, name: String) throws -> Data {
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard document.dtd == nil, let root = document.rootElement(), root.name == "ProxifierProfile" else {
            throw FormatError("请选择有效的 Proxifier XML 配置文件。")
        }

        var configs: [[String: Any]] = []
        var proxyIDs = Set<String>()
        for proxy in root.elements(forName: "ProxyList").first?.elements(forName: "Proxy") ?? [] {
            let id = proxy.attribute(forName: "id")?.stringValue ?? ""
            let host = value("Address", in: proxy)
            guard proxy.attribute(forName: "type")?.stringValue?.uppercased() == "SOCKS5",
                  !id.isEmpty, proxyIDs.insert(id).inserted, !host.isEmpty,
                  let port = Int(value("Port", in: proxy)), (1...65535).contains(port) else {
                throw FormatError("PPX 中有无效或非 SOCKS5 的代理服务器。")
            }

            var config: [String: Any] = ["id": id, "type": "socks5", "host": host, "port": port,
                                         "name": value("Name", in: proxy)]
            if let auth = proxy.elements(forName: "Authentication").first,
               auth.attribute(forName: "enabled")?.stringValue?.lowercased() != "false" {
                let username = auth.elements(forName: "Username").first?.stringValue ?? ""
                let password = auth.elements(forName: "Password").first
                guard let password, password.attribute(forName: "encoding") == nil,
                      !username.isEmpty else {
                    throw FormatError("PPX 中含无法读取的代理认证信息。")
                }
                config["username"] = username
                config["password"] = password.stringValue ?? ""
            }
            configs.append(config)
        }

        var rules: [[String: Any]] = []
        for rule in root.elements(forName: "RuleList").first?.elements(forName: "Rule") ?? [] {
            let action = rule.elements(forName: "Action").first
            let target = action?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mappedAction: String
            switch action?.attribute(forName: "type")?.stringValue?.lowercased() {
            case "direct": mappedAction = "DIRECT"
            case "block": mappedAction = "BLOCK"
            case "proxy" where proxyIDs.contains(target): mappedAction = target
            default: throw FormatError("PPX 中有代理链、不支持的规则动作或缺失的代理引用。")
            }
            // PPX 的 Default 行没有匹配条件，作为列表末尾的兜底规则保留。
            rules.append(["name": value("Name", in: rule), "localId": UUID().uuidString,
                          "processNames": value("Applications", in: rule),
                          "targetHosts": value("Targets", in: rule),
                          "targetPorts": value("Ports", in: rule), "protocol": "TCP",
                          "action": mappedAction,
                          "enabled": rule.attribute(forName: "enabled")?.stringValue?.lowercased() != "false"])
        }
        return try JSONSerialization.data(withJSONObject: ["name": name, "proxyConfigs": configs, "proxyRules": rules])
    }

    static func exportData(_ data: Data) throws -> Data {
        guard let profile = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError("无法读取当前配置方案。")
        }
        let root = XMLElement(name: "ProxifierProfile")
        for (key, value) in ["version": "101", "platform": "MacOSX", "product_id": "2", "product_minver": "200"] {
            root.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }

        let proxyList = XMLElement(name: "ProxyList")
        root.addChild(proxyList)
        var proxyIDs: [String: String] = [:]
        for (index, config) in (profile["proxyConfigs"] as? [[String: Any]] ?? []).enumerated() {
            guard let id = config["id"] as? String, let host = config["host"] as? String,
                  let port = config["port"] as? Int, config["type"] as? String == "socks5" else {
                throw FormatError("PPX 导出只支持 SOCKS5 代理服务器。")
            }
            // Proxifier 的规则引用数字 ID，导出时按服务器顺序重建映射。
            let proxyID = String(index + 100)
            proxyIDs[id] = proxyID
            let proxy = XMLElement(name: "Proxy")
            proxy.addAttribute(XMLNode.attribute(withName: "id", stringValue: proxyID) as! XMLNode)
            proxy.addAttribute(XMLNode.attribute(withName: "type", stringValue: "SOCKS5") as! XMLNode)
            proxy.addChild(XMLElement(name: "Address", stringValue: host))
            proxy.addChild(XMLElement(name: "Port", stringValue: String(port)))
            proxy.addChild(XMLElement(name: "Options", stringValue: "0"))
            if let username = config["username"] as? String, let password = config["password"] as? String {
                let auth = XMLElement(name: "Authentication")
                auth.addAttribute(XMLNode.attribute(withName: "enabled", stringValue: "true") as! XMLNode)
                auth.addChild(XMLElement(name: "Username", stringValue: username))
                auth.addChild(XMLElement(name: "Password", stringValue: password))
                proxy.addChild(auth)
            }
            proxyList.addChild(proxy)
        }

        root.addChild(XMLElement(name: "ChainList"))
        let ruleList = XMLElement(name: "RuleList")
        root.addChild(ruleList)
        var hasDefault = false
        let rules = profile["proxyRules"] as? [[String: Any]] ?? []
        for (index, config) in rules.enumerated() {
            let rule = XMLElement(name: "Rule")
            let enabled = config["enabled"] as? Bool ?? true
            let ruleProtocol = config["protocol"] as? String ?? "TCP"
            guard ruleProtocol == "TCP" else {
                throw FormatError("PPX 导出支持 TCP 规则。包含 UDP 的方案请导出为代理桥格式。")
            }
            rule.addAttribute(XMLNode.attribute(withName: "enabled", stringValue: String(enabled)) as! XMLNode)
            var isCatchAll = true
            for (key, tag) in [("processNames", "Applications"), ("targetHosts", "Targets"), ("targetPorts", "Ports")] {
                if let condition = config[key] as? String, !condition.isEmpty, condition != "*" {
                    rule.addChild(XMLElement(name: tag, stringValue: condition))
                    isCatchAll = false
                }
            }
            let isDefault = enabled && isCatchAll && index == rules.count - 1
            hasDefault = hasDefault || isDefault
            let name = config["name"] as? String ?? ""
            rule.insertChild(XMLElement(name: "Name", stringValue: isDefault ? "Default" : (name.isEmpty || name == "Default" ? "规则 \(index + 1)" : name)), at: 0)
            let action = XMLElement(name: "Action")
            switch config["action"] as? String {
            case "DIRECT": action.addAttribute(XMLNode.attribute(withName: "type", stringValue: "Direct") as! XMLNode)
            case "BLOCK": action.addAttribute(XMLNode.attribute(withName: "type", stringValue: "Block") as! XMLNode)
            case let id? where proxyIDs[id] != nil:
                action.addAttribute(XMLNode.attribute(withName: "type", stringValue: "Proxy") as! XMLNode)
                action.stringValue = proxyIDs[id]
            default: throw FormatError("存在引用无效代理服务器的规则。")
            }
            rule.addChild(action)
            ruleList.addChild(rule)
        }
        if !hasDefault {
            let rule = XMLElement(name: "Rule")
            rule.addAttribute(XMLNode.attribute(withName: "enabled", stringValue: "true") as! XMLNode)
            rule.addChild(XMLElement(name: "Name", stringValue: "Default"))
            let action = XMLElement(name: "Action")
            action.addAttribute(XMLNode.attribute(withName: "type", stringValue: "Direct") as! XMLNode)
            rule.addChild(action)
            ruleList.addChild(rule)
        }
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func value(_ name: String, in element: XMLElement) -> String {
        element.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
