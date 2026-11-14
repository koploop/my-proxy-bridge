import SwiftUI
import Combine
import Darwin

struct ProxyCheckerView: View {
    let config: ProxyBridgeViewModel.ProxyConfig
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ProxyCheckerModel

    init(config: ProxyBridgeViewModel.ProxyConfig) {
        self.config = config
        _model = StateObject(wrappedValue: ProxyCheckerModel(config: config))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("目标主机").fontWeight(.medium)
                TextField("www.google.com", text: $model.targetHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Text("目标端口").fontWeight(.medium)
                TextField("80", text: $model.targetPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer()
                Button("重新测试") { model.run() }
                    .disabled(model.isRunning)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                Text(model.log)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .controlSize(.small)
        .frame(width: 640, height: 400)
        .onAppear { model.run() }
    }
}

final class ProxyCheckerModel: ObservableObject {
    @Published var log = ""
    @Published var targetHost: String
    @Published var targetPort: String
    @Published var isRunning = false

    private let config: ProxyBridgeViewModel.ProxyConfig

    init(config: ProxyBridgeViewModel.ProxyConfig) {
        self.config = config
        // 测试窗口允许临时改写目标，只有代理配置表单负责持久化。
        targetHost = config.testHost
        targetPort = String(config.testPort)
    }

    static func isValidTestHost(_ host: String) -> Bool {
        var address = in6_addr()
        if inet_pton(AF_INET6, host, &address) == 1 { return true }
        // SOCKS5 域名字段只有一个长度字节，拒绝 URL、空格和超长地址。
        let domainPattern = #"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?$"#
        return host.utf8.count <= 255 && host.range(of: domainPattern, options: .regularExpression) != nil
    }

    func run() {
        guard !isRunning else { return }
        let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTestHost(host),
              let port = Int(targetPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            log = "请输入有效的测试地址和端口（1–65535）。"
            return
        }
        isRunning = true
        log = ""
        DispatchQueue.global().async {
            self.performTests(targetHost: host, targetPort: port)
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func line(_ text: String) {
        DispatchQueue.main.async { self.log += text + "\n" }
    }

    private func performTests(targetHost: String, targetPort: Int) {
        let proxyHost = config.host
        let proxyPort = config.port
        let isSocks5 = config.type.lowercased() == "socks5"
        let hasAuth = config.username != nil && config.password != nil

        line("代理：\(proxyHost):\(proxyPort)")
        line("协议：\(config.type.uppercased())")
        line("认证：\(hasAuth ? "启用" : "关闭")")
        line("目标：\(targetHost):\(targetPort)")
        line("")

        // Test 1 - reach the proxy
        line("测试 1：连接代理服务器")
        guard let (fd1, ms1) = openConnection(host: proxyHost, port: proxyPort) else {
            line("  无法连接代理服务器")
            line("  测试 1 失败")
            line("")
            line("测试结束，无法访问代理服务器。")
            return
        }
        line(String(format: "  连接成功（%.0f 毫秒）", ms1))
        line("  测试 1 通过")
        line("")

        // Test 2 - go through the proxy to the target
        line("测试 2：通过代理连接目标")
        var connected = false
        if isSocks5 {
            if socks5Handshake(fd1, hasAuth: hasAuth) {
                let (ok, reason) = socks5Connect(fd1, host: targetHost, port: targetPort)
                connected = ok
                if !ok { line("  SOCKS5 CONNECT 失败： \(reason)") }
            } else {
                line("  SOCKS5 握手或认证失败")
            }
        } else {
            let (ok, firstLine) = httpConnect(fd1, host: targetHost, port: targetPort)
            connected = ok
            if !ok { line("  HTTP CONNECT failed: \(firstLine)") }
        }

        if connected {
            // 测试目标可以是任意 TCP 服务，代理确认建立连接即通过。
            line("  已连接到 \(targetHost):\(targetPort)（通过代理）")
            line("  测试 2 通过")
        } else {
            line("  测试 2 失败")
        }
        Darwin.close(fd1)
        line("")

        // Test 3 - latency (fresh connect to the proxy)
        line("测试 3：代理延迟")
        if let (fd3, ms3) = openConnection(host: proxyHost, port: proxyPort) {
            line(String(format: "  延迟 %.0f 毫秒", ms3))
            line("  测试 3 通过")
            Darwin.close(fd3)
        } else {
            line("  无法测量延迟")
            line("  测试 3 失败")
        }
        line("")

        // Test 4 - SOCKS5 UDP ASSOCIATE support
        if isSocks5 {
            line("测试 4：SOCKS5 UDP 转发能力")
            if let (fd4, _) = openConnection(host: proxyHost, port: proxyPort) {
                if socks5Handshake(fd4, hasAuth: hasAuth) {
                    let (granted, info) = socks5UDPAssociate(fd4)
                    if granted {
                        line("  UDP ASSOCIATE 已接受，中继地址： \(info)")
                        line("  该代理支持 UDP 转发")
                    } else {
                        line("  UDP ASSOCIATE 请求被拒绝： \(info)")
                        line("  该代理未接受 UDP 转发请求")
                    }
                } else {
                    line("  握手失败")
                }
                Darwin.close(fd4)
            } else {
                line("  无法连接代理服务器")
            }
            line("")
        }

        line("测试结束。")
    }

    // MARK: - sockets

    // connects to host:port (v4/v6/hostname), returns the fd and connect time in ms
    private func openConnection(host: String, port: Int, timeout: Int = 5) -> (Int32, Double)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }

        let start = Date()
        var candidate = result
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return (fd, Date().timeIntervalSince(start) * 1000)
                }
                Darwin.close(fd)
            }
            candidate = addr.pointee.ai_next
        }
        return nil
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { raw -> Bool in
            var sent = 0
            let base = raw.baseAddress!
            while sent < bytes.count {
                let n = send(fd, base + sent, bytes.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func recvBytes(_ fd: Int32, _ maxLen: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLen)
        let n = recv(fd, &buf, maxLen, 0)
        return n > 0 ? Array(buf[0..<n]) : []
    }

    // reads exactly n bytes, nil on timeout/close
    private func recvExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8]()
        while out.count < n {
            var buf = [UInt8](repeating: 0, count: n - out.count)
            let r = recv(fd, &buf, n - out.count, 0)
            if r <= 0 { return nil }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    // MARK: - SOCKS5

    private func socks5Handshake(_ fd: Int32, hasAuth: Bool) -> Bool {
        let greeting: [UInt8] = hasAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
        guard sendAll(fd, greeting), let resp = recvExact(fd, 2), resp[0] == 0x05 else { return false }

        if resp[1] == 0x00 { return true }
        if resp[1] == 0x02 {
            let user = Array((config.username ?? "").utf8)
            let pass = Array((config.password ?? "").utf8)
            guard user.count <= 255, pass.count <= 255 else { return false }
            var req: [UInt8] = [0x01, UInt8(user.count)]
            req += user
            req.append(UInt8(pass.count))
            req += pass
            guard sendAll(fd, req), let ar = recvExact(fd, 2), ar[1] == 0x00 else { return false }
            return true
        }
        return false
    }

    private func socks5Connect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        var req: [UInt8] = [0x05, 0x01, 0x00]
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        // SOCKS5 对 IPv4、IPv6 和域名使用不同的地址类型和字节布局。
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            req.append(0x01)
            req.append(contentsOf: withUnsafeBytes(of: &ipv4) { Array($0) })
        } else if inet_pton(AF_INET6, host, &ipv6) == 1 {
            req.append(0x04)
            req.append(contentsOf: withUnsafeBytes(of: &ipv6) { Array($0) })
        } else {
            req += [0x03, UInt8(host.utf8.count)]
            req.append(contentsOf: host.utf8)
        }
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        return (consumeBoundAddress(fd, atyp: head[3]) != nil, "")
    }

    private func socks5UDPAssociate(_ fd: Int32) -> (Bool, String) {
        let req: [UInt8] = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        guard let relay = consumeBoundAddress(fd, atyp: head[3]) else { return (false, "bad reply") }
        return (true, relay)
    }

    // reads the bound address + port that follows a SOCKS5 reply header, returns "host:port"
    private func consumeBoundAddress(_ fd: Int32, atyp: UInt8) -> String? {
        var host = ""
        switch atyp {
        case 0x01:
            guard let a = recvExact(fd, 4) else { return nil }
            host = "\(a[0]).\(a[1]).\(a[2]).\(a[3])"
        case 0x04:
            guard let a = recvExact(fd, 16) else { return nil }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%x", (UInt16(a[i]) << 8) | UInt16(a[i + 1])))
            }
            host = parts.joined(separator: ":")
        case 0x03:
            guard let l = recvExact(fd, 1)?.first, let d = recvExact(fd, Int(l)) else { return nil }
            host = String(bytes: d, encoding: .utf8) ?? "?"
        default:
            return nil
        }
        guard let p = recvExact(fd, 2) else { return nil }
        return "\(host):\((Int(p[0]) << 8) | Int(p[1]))"
    }

    // MARK: - HTTP CONNECT

    private func httpConnect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        let target = host.contains(":") ? "[\(host)]" : host
        var req = "CONNECT \(target):\(port) HTTP/1.1\r\nHost: \(target):\(port)\r\n"
        if let u = config.username, let p = config.password {
            let cred = Data("\(u):\(p)".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(cred)\r\n"
        }
        req += "\r\n"
        guard sendAll(fd, Array(req.utf8)) else { return (false, "write failed") }
        let response = String(bytes: recvBytes(fd, 1024), encoding: .utf8) ?? ""
        let firstLine = response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? "no response"
        return (response.contains(" 200"), firstLine)
    }

    private func hex(_ b: UInt8) -> String { String(format: "%02x", b) }

    private func socksReason(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "general failure"
        case 0x02: return "not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "unknown"
        }
    }
}
