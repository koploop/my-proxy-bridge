import Foundation
import NetworkExtension

struct RuleManager {

    // fallback rule channel: the provider IPC used by sendProviderMessage can be
    // rejected for development-signed host apps on some macOS builds, so the saved
    // rule list is also mirrored into the shared app group container and the
    // extension loads it from there when the tunnel starts. UserDefaults suites
    // don't resolve reliably across the app/system-extension boundary, so the
    // mirror is a plain JSON file in the container (same idea as the DNSMapStore
    // file mirror, which worked). the suite write is kept as a harmless extra.
    static let sharedContainerSuiteName = "group.com.commonuse.magic"
    static let sharedContainerRulesKey = "proxyRules"
    static let sharedRulesFileName = "proxybridge-rules.json"

    static func sharedRulesFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerSuiteName)?
            .appendingPathComponent(sharedRulesFileName)
    }

    static func sharedContainerDefaults() -> UserDefaults? {
        UserDefaults(suiteName: sharedContainerSuiteName)
    }

    static func mirrorSavedRulesToSharedContainer() {
        writeSharedRules(savedRulesPayload())
    }

    static func savedRulesPayload() -> [[String: Any]] {
        normalizedPayload(UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? [])
    }

    private static func writeSharedRules(_ payload: [[String: Any]]) {
        if let url = sharedRulesFileURL(),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
        sharedContainerDefaults()?.set(payload, forKey: sharedContainerRulesKey)
    }

    static func normalizedPayload(_ rules: [[String: Any]]) -> [[String: Any]] {
        rules.map { rule in
            [
                "processNames": rule["processNames"] as? String ?? "",
                "targetHosts": rule["targetHosts"] as? String ?? "",
                "targetPorts": rule["targetPorts"] as? String ?? "",
                "ruleProtocol": rule["protocol"] as? String ?? "BOTH",
                "ruleAction": rule["action"] as? String ?? "DIRECT",
                "enabled": rule["enabled"] as? Bool ?? true
            ]
        }
    }

    static func addRule(
        session: NETunnelProviderSession,
        processNames: String,
        targetHosts: String,
        targetPorts: String,
        protocol: String,
        action: String,
        enabled: Bool = true,
        completion: @escaping (Bool, String, UInt32?) -> Void
    ) {
        sendMessage(
            session: session,
            action: "addRule",
            params: [
                "processNames": processNames,
                "targetHosts": targetHosts,
                "targetPorts": targetPorts,
                "ruleProtocol": `protocol`,
                "ruleAction": action,
                "enabled": enabled
            ]
        ) { success, result in
            if success, let result = result, result["status"] as? String == "ok" {
                let ruleId = (result["ruleId"] as? NSNumber).map { UInt32($0.intValue) }
                completion(true, "Rule added successfully", ruleId)
            } else {
                completion(false, result?["message"] as? String ?? "Unknown error", nil)
            }
        }
    }
    
    static func clearRules(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, String) -> Void
    ) {
        sendMessage(session: session, action: "clearRules", params: [:]) { success, result in
            let message = success
                ? "Cleared \(result?["cleared"] as? Int ?? 0) rule(s)"
                : (result?["message"] as? String ?? "Unknown error")
            completion(success, message)
        }
    }
    
    private static func sendMessage(
        session: NETunnelProviderSession,
        action: String,
        params: [String: Any],
        completion: @escaping (Bool, [String: Any]?) -> Void
    ) {
        var message = params
        message["action"] = action
        
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(false, nil)
            return
        }
        
        try? session.sendProviderMessage(data) { response in
            guard let responseData = response,
                  let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let status = result["status"] as? String else {
                completion(false, nil)
                return
            }
            
            completion(status == "ok", result)
        }
    }
    
    static func resyncRules(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        applyRulesFromUserDefaults(session: session, completion: completion)
    }

    static func loadRulesFromUserDefaults(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        applyRulesFromUserDefaults(session: session, completion: completion)
    }

    // the whole saved list goes to the extension in one message and replaces the
    // running list atomically, so there is no moment where rules are missing
    private static func applyRulesFromUserDefaults(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        let rules = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        applyRules(session: session, rules: rules, completion: completion)
    }

    // replaces the extension's rule list with these rules (as saved by the app). also used
    // by the command line, which has its rules in memory instead of in the preferences
    static func applyRules(
        session: NETunnelProviderSession,
        rules: [[String: Any]],
        completion: @escaping (Bool, Int) -> Void
    ) {
        let payload = normalizedPayload(rules)
        // keep the shared container copy in sync so a tunnel started later loads
        // the same list even if the IPC delivery below never reaches the extension
        writeSharedRules(payload)

        sendMessage(session: session, action: "setRules", params: ["rules": payload]) { success, result in
            if success {
                let count = result?["count"] as? Int ?? payload.count
                DispatchQueue.main.async { completion(true, count) }
                return
            }
            // an extension that predates setRules answers nothing, fall back to
            // clear + add one by one (leaves a short gap while it runs)
            clearRules(session: session) { _, _ in
                guard !rules.isEmpty else {
                    DispatchQueue.main.async { completion(true, 0) }
                    return
                }
                addRulesInOrder(session: session, rules: rules, index: 0, added: 0, completion: completion)
            }
        }
    }

    private static func addRulesInOrder(
        session: NETunnelProviderSession,
        rules: [[String: Any]],
        index: Int,
        added: Int,
        completion: @escaping (Bool, Int) -> Void
    ) {
        guard index < rules.count else {
            DispatchQueue.main.async { completion(true, added) }
            return
        }
        let rule = rules[index]
        addRule(
            session: session,
            processNames: rule["processNames"] as? String ?? "",
            targetHosts: rule["targetHosts"] as? String ?? "",
            targetPorts: rule["targetPorts"] as? String ?? "",
            protocol: rule["protocol"] as? String ?? "BOTH",
            action: rule["action"] as? String ?? "DIRECT",
            enabled: rule["enabled"] as? Bool ?? true
        ) { success, _, _ in
            addRulesInOrder(
                session: session,
                rules: rules,
                index: index + 1,
                added: added + (success ? 1 : 0),
                completion: completion
            )
        }
    }
}
