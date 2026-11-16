// Сервер по SSH, Terminal, панель торгового бота, VLESS-прокси только для «Пульта».
import Foundation

enum Remote {
    static var host: String { Secrets.read("PULT_SSH_HOST") ?? "" }
    static var key: String { Secrets.read("PULT_SSH_KEY") ?? homeDir + "/.ssh/id_ed25519" }

    /// Команда на сервере; ответ (stdout) на главном потоке, nil — ошибка.
    static func run(_ cmd: String, stdin: String? = nil, timeout: TimeInterval = 45, _ done: @escaping (String?) -> Void) {
        guard !host.isEmpty else { done(nil); return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", host, cmd]
            // Зависший ssh не должен держать панель бота и опрос выкладки вечно.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            defer { killer.cancel() }
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = inp
            var result: String? = nil
            do {
                try p.run()
                if let s = stdin { inp.fileHandleForWriting.write(s.data(using: .utf8)!) }
                try? inp.fileHandleForWriting.close()
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { result = String(data: d, encoding: .utf8) }
            } catch {}
            DispatchQueue.main.async { done(result) }
        }
    }
}

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

final class BotStatus: ObservableObject {
    static let shared = BotStatus()
    @Published var data: JSON? = nil
    @Published var loading = false
    @Published var error: String? = nil
    @Published var alarm = false                 // красная точка на кнопке «Бот»
    @Published var changes: [String] = []
    @Published var workerBusy = false
    @Published var deployId: String? = UserDefaults.standard.string(forKey: "deployId")
    @Published var deployLines: [String] = []
    @Published var deployActive = false
    private var seen = Set(UserDefaults.standard.array(forKey: "seenTrades") as? [Int] ?? [])     // хранится по возрастанию id
    private var timer: Timer?

    /// Фоновая проверка: бот упал / сделка −40% и хуже / новая выкладка.
    func startWatching() {
        guard !Remote.host.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refresh(silent: true) }
        refresh(silent: true)
    }

    func refreshChanges() {
        Remote.run("python3 /usr/local/lib/coder-chat/deploy_ctl.py changes") { [weak self] out in
            guard let d = out?.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return }
            self?.changes = (j["files"] as? [String]) ?? []
            self?.workerBusy = (j["worker_busy"] as? Bool) ?? false
        }
        if let id = deployId { pollDeploy(id) }
    }

    func startDeploy() {
        deployLines = ["Запускаю…"]; deployActive = true
        Remote.run("python3 /usr/local/lib/coder-chat/deploy_ctl.py start") { [weak self] out in
            guard let self = self else { return }
            let id = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { self.deployActive = false; self.deployLines = ["Не запустилось: программист работает или уже идёт выкладка."]; return }
            self.deployId = id; UserDefaults.standard.set(id, forKey: "deployId")
            self.pollDeploy(id)
        }
    }

    private var pollFailures = 0
    func pollDeploy(_ id: String) {
        Remote.run("python3 /usr/local/lib/coder-chat/deploy_ctl.py log \(id)") { [weak self] out in
            guard let self = self else { return }
            guard let d = out?.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else {
                // Сеть моргнула: пробуем ещё, а не бросаем выкладку в состоянии «идёт».
                self.pollFailures += 1
                if self.deployActive, self.pollFailures <= 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.pollDeploy(id) } }
                else if self.deployActive {
                    self.deployActive = false
                    self.deployLines.append("Связь с сервером потеряна — результат выкладки неизвестен. Открой панель позже.")
                    notifyMac("Выкладка", "⚠️ Связь потеряна, результат неизвестен")
                }
                return
            }
            self.pollFailures = 0
            self.deployLines = (j["lines"] as? [String]) ?? []
            let wasActive = self.deployActive
            self.deployActive = (j["active"] as? Bool) ?? false
            if self.deployActive { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.pollDeploy(id) } }
            else if wasActive {
                let res = self.deployLines.last { $0.hasPrefix("RESULT") } ?? "RESULT ?"
                notifyMac("Выкладка", res.contains("deployed") ? "✅ Выложено, бот работает" : res.contains("rolled_back") ? "↩️ Не вышло — откатил" : "❌ Не выложено")
                self.refreshChanges()
            }
        }
    }

    func refresh(silent: Bool = false) {
        if !silent { loading = true; error = nil }
        Remote.run("python3 /usr/local/lib/coder-chat/bot_status.py") { [weak self] out in
            guard let self = self else { return }
            self.loading = false
            guard let out = out, let d = out.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else {
                if !silent { self.error = "Сервер не ответил" }; return
            }
            self.data = j
            let down = (j["service"] as? String) != "active"
            if down && !self.alarm { notifyMac("Торговый бот", "⛔ Служба не работает: \((j["service"] as? String) ?? "?")") }
            self.alarm = down
            let first = self.seen.isEmpty
            for r in (j["last"] as? [JSON]) ?? [] {
                guard let id = (r["id"] as? NSNumber)?.intValue, !self.seen.contains(id) else { continue }
                self.seen.insert(id)
                let p = (r["pnl_pct"] as? NSNumber)?.doubleValue ?? 0
                if !first && p <= -40 {
                    notifyMac("Торговый бот", String(format: "🔻 #%d закрыта %+.0f%% (%@)", id, p, (r["reason"] as? String) ?? ""))
                    self.alarm = true
                }
            }
            if self.seen.count > 500 { self.seen = Set(self.seen.sorted().suffix(500)) }
            UserDefaults.standard.set(self.seen.sorted(), forKey: "seenTrades")
        }
    }
}

/// VLESS только для процессов «Пульта»: локальный xray (HTTP-прокси 127.0.0.1:10809) и переменные окружения
/// для запускаемых Codex/Claude. Ссылка: ~/Documents/pult/vless.txt (600), xray: ~/Documents/pult/bin/xray.
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
        let wasRunning = xray != nil
        xray?.terminate(); xray = nil
        guard enabled else { status = "выключен"; if wasRunning { onChange?() }; return }
        guard available, let cfg = config() else { status = "нет xray или vless.txt"; return }
        let path = Proxy.dir + "/xray.json"
        FileManager.default.createFile(atPath: path, contents: cfg, attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Proxy.dir + "/bin/xray")
        p.arguments = ["run", "-c", path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let name = names.isEmpty ? "сервер" : names[min(max(selected, 0), names.count - 1)]
        do { try p.run(); xray = p; status = "включён · \(name)" } catch { status = "xray не запустился" }
        // xray мог упасть сразу (плохая ссылка, занят порт) — не показываем «включён» зря.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.xray === p else { return }
            if !p.isRunning { self.xray = nil; self.status = "xray упал при запуске — проверь ссылку в vless.txt" }
            self.onChange?()
        }
    }
    /// Вызывается после включения/выключения: чаты и Telegram переподключаются через новую сеть.
    var onChange: (() -> Void)?

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
