import Foundation
enum Terminal {
    static func run(_ cmd: String) {
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to do script \"\(esc)\"", "-e", "tell application \"Terminal\" to activate"]
        try? p.run()
    }
}

func notifyMac(_ title: String, _ text: String) {
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(text))\" with title \"\(esc(title))\" sound name \"Submarine\""]
    try? p.run()
}

final class Proxy: ObservableObject {
    static let shared = Proxy()
    static let dir = appDataDir
    let port = 10809
    @Published var enabled = UserDefaults.standard.bool(forKey: "vless") { didSet { UserDefaults.standard.set(enabled, forKey: "vless"); apply() } }
    @Published var status = "выключен"
    @Published var selected = UserDefaults.standard.integer(forKey: "vlessIndex") { didSet { UserDefaults.standard.set(selected, forKey: "vlessIndex"); if enabled { apply() } } }
    private var xray: Process?

    /// Ссылки из vless.txt; наружу — только названия после «#».
    var links: [String] {
        guard let raw = try? String(contentsOfFile: Proxy.dir + "/vless.txt", encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("vless://") }
    }
    var names: [String] {
        links.enumerated().map { i, l in l.components(separatedBy: "#").dropFirst().first?.removingPercentEncoding ?? "сервер \(i + 1)" }
    }

    var available: Bool {
        FileManager.default.isExecutableFile(atPath: Proxy.dir + "/bin/xray") &&
        FileManager.default.fileExists(atPath: Proxy.dir + "/vless.txt")
    }
    var env: [String: String] {
        guard enabled, xray?.isRunning == true else { return [:] }
        let u = "http://127.0.0.1:\(port)"
        return ["HTTPS_PROXY": u, "HTTP_PROXY": u, "https_proxy": u, "http_proxy": u, "NO_PROXY": "127.0.0.1,localhost"]
    }

    func apply() {
        xray?.terminate(); xray = nil
        guard enabled else { status = "выключен"; return }
        guard available, let cfg = config() else { status = "нет xray или vless.txt"; return }
        let path = Proxy.dir + "/xray.json"
        FileManager.default.createFile(atPath: path, contents: cfg, attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Proxy.dir + "/bin/xray")
        p.arguments = ["run", "-c", path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); xray = p; status = "включён · \(names[min(max(selected, 0), names.count - 1)])" } catch { status = "xray не запустился" }
    }

    /// vless://uuid@host:port?type=tcp&security=reality&pbk=…&sni=…&sid=…&fp=…&flow=…#name → конфиг xray.
    func config() -> Data? {
        let all = links
        guard !all.isEmpty else { return nil }
        let line = all[min(max(selected, 0), all.count - 1)]
        guard let u = URLComponents(string: line.components(separatedBy: "#")[0]),
              let id = u.user, let host = u.host else { return nil }
        var q: [String: String] = [:]
        for i in u.queryItems ?? [] { q[i.name] = i.value ?? "" }
        let security = q["security"] ?? "none"
        var stream: JSON = ["network": q["type"] ?? "tcp", "security": security]
        if security == "reality" {
            stream["realitySettings"] = ["serverName": q["sni"] ?? "", "publicKey": q["pbk"] ?? "",
                                         "shortId": q["sid"] ?? "", "fingerprint": q["fp"] ?? "chrome", "spiderX": q["spx"] ?? ""]
        } else if security == "tls" {
            stream["tlsSettings"] = ["serverName": q["sni"] ?? host, "fingerprint": q["fp"] ?? "chrome"]
        }
        if q["type"] == "ws" { stream["wsSettings"] = ["path": q["path"] ?? "/", "headers": ["Host": q["host"] ?? host]] }
        if q["type"] == "grpc" { stream["grpcSettings"] = ["serviceName": q["serviceName"] ?? ""] }
        var user: JSON = ["id": id, "encryption": q["encryption"] ?? "none"]
        if let f = q["flow"], !f.isEmpty { user["flow"] = f }
        let cfg: JSON = [
            "log": ["loglevel": "warning"],
            "inbounds": [["listen": "127.0.0.1", "port": port, "protocol": "http"]],
            "outbounds": [["protocol": "vless", "settings": ["vnext": [["address": host, "port": u.port ?? 443, "users": [user]]]],
                           "streamSettings": stream]],
        ]
        return try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted)
    }

    func stop() { xray?.terminate() }
}
