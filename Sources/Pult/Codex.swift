// Клиент Codex app-server (JSON-RPC построчно через stdio). Один процесс = один аккаунт (CODEX_HOME).
import Foundation

let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
let appDataDir = homeDir + "/Library/Application Support/PultPublic"
let helperDir = Bundle.main.resourceURL!.appendingPathComponent("helpers").path + "/"
func executable(_ name: String) -> String {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in [homeDir + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + paths {
        let path = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return "/usr/local/bin/" + name
}
let codexBin = executable("codex")
let claudeBin = executable("claude")

typealias JSON = [String: Any]

final class CodexClient {
    var requestTransport: ((JSON) -> Void)?
    let home: String
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextId = 100
    private var pending: [Int: (JSON) -> Void] = [:]      // только с главного потока
    var onNotification: (String, JSON) -> Void = { _, _ in }
    var onServerRequest: (Any, String, JSON) -> Void = { _, _, _ in }
    var onExit: () -> Void = {}

    init(home: String, extraEnv: [String: String] = [:]) {
        self.home = home
        proc.executableURL = URL(fileURLWithPath: codexBin)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        env.merge(extraEnv) { _, new in new }
        proc.environment = env
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
    }

    func start(_ ready: @escaping (Bool) -> Void) {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        proc.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onExit() } }
        do { try proc.run() } catch { ready(false); return }
        call("initialize", ["clientInfo": ["name": "pult", "title": "Пульт", "version": "1.0"],
                            "capabilities": ["experimentalApi": true]]) { [weak self] r in
            self?.notify("initialized", [:])
            ready(r["error"] == nil)
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
            DispatchQueue.main.async { self.handle(o) }
        }
    }

    func handle(_ o: JSON) {
        let params = (o["params"] as? JSON) ?? [:]
        if let m = o["method"] as? String {
            if let id = o["id"] { onServerRequest(id, m, params) } else { onNotification(m, params) }
        } else if let id = o["id"] as? Int, let cb = pending.removeValue(forKey: id) {
            cb(o)
        }
    }

    private func write(_ o: JSON) {
        if let transport = requestTransport { transport(o); return }
        guard proc.isRunning, var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        input.fileHandleForWriting.write(d)
    }

    func call(_ method: String, _ params: JSON, _ cb: @escaping (JSON) -> Void = { _ in }) {
        nextId += 1
        pending[nextId] = cb
        write(["id": nextId, "method": method, "params": params])
    }
    func notify(_ method: String, _ params: JSON) { write(["method": method, "params": params]) }
    func respond(_ id: Any, result: JSON) { write(["id": id, "result": result]) }
    func reject(_ id: Any, _ message: String) { write(["id": id, "error": ["code": -32000, "message": message]]) }
    func stop() { if proc.isRunning { proc.terminate() } }
}

/// Аккаунты Codex на Mac: ~/.codex-accounts.json [{name, home}].
struct Account: Identifiable, Hashable {
    let name: String
    let home: String
    var id: String { home }
}

func loadAccounts() -> [Account] {
    let path = homeDir + "/.codex-accounts.json"
    guard let d = FileManager.default.contents(atPath: path),
          let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: String]] else {
        return [Account(name: "Codex", home: homeDir + "/.codex")]
    }
    let values = rows.compactMap { r -> Account? in
        guard let n = r["name"], let h = r["home"] else { return nil }
        return Account(name: n, home: (h as NSString).expandingTildeInPath)
    }
    return values.isEmpty ? [Account(name: "Codex", home: homeDir + "/.codex")] : values
}

/// Файл диалога (rollout) по id — чтобы другой аккаунт продолжил тот же разговор.
func findRollout(_ threadId: String, in homes: [String]) -> String? {
    let fm = FileManager.default
    var best: (String, Date)? = nil
    for h in homes {
        guard let e = fm.enumerator(atPath: h + "/sessions") else { continue }
        for case let rel as String in e where rel.hasSuffix(threadId + ".jsonl") {
            let p = h + "/sessions/" + rel
            let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || m > best!.1 { best = (p, m) }
        }
    }
    return best?.0
}
