import AppKit
import SwiftUI
import WebKit

enum ModPolicy {
    static let permissions: [String: String] = [
        "chats.list": "chats.read", "chats.read": "chats.read", "chats.create": "chats.write",
        "chats.send": "chats.write", "chats.stop": "chats.write", "chats.activate": "chats.write", "chats.append": "chats.write",
        "files.list": "files.read", "files.read": "files.read", "files.write": "files.write", "git.status": "files.read", "git.diff": "files.read",
        "team.state": "team.read", "team.send": "team.write", "team.addTask": "team.write", "team.claim": "team.write",
        "network.fetch": "network", "process.start": "process", "process.stop": "process", "process.read": "process",
        "secrets.get": "secrets", "secrets.set": "secrets"
    ]
    static func path(_ path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\\"), path.utf8.count < 1000 else { throw ModError("Нужен относительный путь проекта") }
        let parts = path.split(separator: "/")
        // Файловая система Mac не различает регистр: .GIT/config и .ENV — те же служебные файлы.
        guard !parts.map({ $0.lowercased() }).contains(where: { $0 == ".." || $0.hasPrefix(".env") || [".git", ".ssh", ".aws", "auth.json", "credentials", "id_rsa", "id_ed25519"].contains($0) || ["pem", "key", "p12"].contains(($0 as NSString).pathExtension) }) else { throw ModError("Служебные файлы и секреты недоступны через файловый API") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var target = base
        for part in parts where part != "." {
            target = target.appendingPathComponent(String(part)).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path == base.path || target.path.hasPrefix(base.path + "/") else { throw ModError("Путь выходит из проекта, включая символьные ссылки") }
        }
        return target
    }
    static func allows(_ url: URL, mod: PultMod) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return false }
        guard let domains = mod.networkDomains else { return true }
        return domains.contains { domain in
            let value = domain.lowercased()
            return value == host || (value.hasPrefix("*.") && host.hasSuffix(String(value.dropFirst())) && host != String(value.dropFirst(2)))
        }
    }
}

private final class WeakModWeb {
    weak var web: WKWebView?
    let mod: String
    init(_ web: WKWebView, mod: String) { self.web = web; self.mod = mod }
}

final class ModPlatform: ObservableObject {
    static let shared = ModPlatform()
    @Published private(set) var logs: [String: [String]] = [:]
    @Published private(set) var turns: [String: Int] = [:]
    private var webs: [UUID: WeakModWeb] = [:]
    private var backgrounds: [String: (String, WKWebView, ModWebBridge)] = [:]
    private var commands: [String: (String, WKWebView, ModWebBridge)] = [:]
    private var processes: [String: (Process, URL)] = [:]
    private var requests: [String: (Date, Int)] = [:]
    private var timer: Timer?
    private var lastChats = ""
    private var lastSettings: [String: String] = [:]
    var store = ModStore.shared
    var workspaceOverride: Workspace?
    var workspace: Workspace { workspaceOverride ?? Workspace.shared }

    func start() {
        guard timer == nil else { return }
        pulse()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pulse() }
    }
    func log(_ id: String, _ message: String) {
        logs[id, default: []].append(String(message.prefix(2000)))
        logs[id] = Array(logs[id, default: []].suffix(80))
    }
    func register(_ web: WKWebView, mod: String) -> UUID {
        let id = UUID(); webs[id] = WeakModWeb(web, mod: mod); return id
    }
    func unregister(_ id: UUID?) { if let id = id { webs[id] = nil } }
    func emit(_ event: String, _ detail: JSON = [:], permission: String? = nil, modID: String? = nil) {
        for (id, target) in webs {
            guard let web = target.web else { webs[id] = nil; continue }
            guard modID == nil || target.mod == modID,
                  let mod = store.activeMods.first(where: { $0.id == target.mod }),
                  permission == nil || mod.permissions.contains(permission!) else { continue }
            guard let data = try? JSONSerialization.data(withJSONObject: ["event": event, "detail": detail]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            web.evaluateJavaScript("window.__pultEvent && window.__pultEvent(\(json))", completionHandler: nil)
        }
    }
    private func pulse() {
        let active = store.activeMods
        let owners = Set(webs.values.map(\.mod)).union(processes.keys.compactMap { $0.split(separator: "/").first.map(String.init) })
        for id in owners where !active.contains(where: { $0.id == id }) { stop(id) }
        for id in Array(backgrounds.keys) where !active.contains(where: { $0.id == id && $0.fingerprint == backgrounds[id]?.0 }) { stop(id) }
        for mod in active {
            if let script = mod.background, backgrounds[mod.id] == nil {
                do {
                    try resources(mod)
                    let bridge = ModWebBridge(mod: mod)
                    let web = bridge.make(html: "<html><body></body></html>", script: script)
                    backgrounds[mod.id] = (mod.fingerprint, web, bridge)
                } catch { log(mod.id, error.localizedDescription) }
            }
            let settings = String(describing: store.settings(for: mod).sorted { $0.key < $1.key })
            if lastSettings[mod.id] != settings {
                lastSettings[mod.id] = settings
                emit("settings.changed", ["settings": store.settings(for: mod)], modID: mod.id)
            }
        }
        guard !active.isEmpty else { return }
        emit("app.tick", ["time": Date().timeIntervalSince1970])
        let chats = workspace.chats.map(chatSummary)
        let signature = String(describing: chats) + workspace.activeID.uuidString
        if signature != lastChats {
            lastChats = signature
            emit("chats.changed", ["chats": chats, "activeID": workspace.activeID.uuidString], permission: "chats.read")
        }
    }
    func stop(_ id: String) {
        if let (_, web, bridge) = backgrounds.removeValue(forKey: id) { bridge.dispose(web) }
        for key in Array(commands.keys) where commands[key]?.0 == id {
            if let (_, web, bridge) = commands.removeValue(forKey: key) { bridge.dispose(web) }
        }
        for key in Array(processes.keys) where key.hasPrefix(id + "/") {
            if let (process, _) = processes.removeValue(forKey: key), process.isRunning { terminate(process) }
        }
        for (key, target) in webs where target.mod == id {
            target.web?.stopLoading(); target.web?.configuration.userContentController.removeScriptMessageHandler(forName: "pult")
            webs[key] = nil
        }
    }
    func stopAll() {
        timer?.invalidate(); timer = nil
        for id in Set(backgrounds.keys).union(store.mods.map(\.id)) { stop(id) }
    }
    private func terminate(_ process: Process) {
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    @discardableResult func resources(_ mod: PultMod) throws -> URL {
        let root = store.dataDirectory(mod.id).appendingPathComponent("assets/" + mod.fingerprint, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("__pult_ready").path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, text) in mod.files ?? [:] {
                guard PultMod.validAsset(name) else { throw ModError("Неверное имя ресурса") }
                let file = try ModPolicy.path(name, root: root)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try Data().write(to: root.appendingPathComponent("__pult_ready"), options: .atomic)
        }
        return root
    }
    func run(_ script: String, mod: PultMod, input: String = "") {
        guard store.activeMods.contains(where: { $0.id == mod.id && $0.fingerprint == mod.fingerprint }) else { return }
        let token = UUID().uuidString
        let inputJSON = String(data: (try? JSONSerialization.data(withJSONObject: input, options: .fragmentsAllowed)) ?? Data("\"\"".utf8), encoding: .utf8)!
        let bridge = ModWebBridge(mod: mod)
        let source = "const input = \(inputJSON); (async()=>{\n\(script)\n})().catch(e=>pult.call('log',{message:String(e)})).finally(()=>pult.call('internal.commandFinished',{id:'\(token)'}));"
        let web = bridge.make(html: "<html><body></body></html>", script: source)
        commands[token] = (mod.id, web, bridge)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let (_, web, bridge) = self?.commands.removeValue(forKey: token) { bridge.dispose(web) }
        }
    }
    func open(_ id: String, panel: String, placement: String? = nil) throws {
        guard let mod = store.activeMods.first(where: { $0.id == id }), let view = mod.allPanels.first(where: { $0.id == panel }) else { throw ModError("Панель не найдена или мод выключен") }
        let key = id + "/" + panel
        switch placement ?? view.placement ?? "main" {
        case "main": store.mainPanelID = key
        case "left": store.leftPanelID = key
        case "right": store.rightPanelID = key
        case "sheet": store.panelID = key
        default: throw ModError("Место панели: main, left, right или sheet")
        }
    }
    func action(_ action: PultMod.Action, mod: PultMod) {
        if let panel = action.panel { do { try open(mod.id, panel: panel) } catch { log(mod.id, error.localizedDescription) } }
        if let command = action.command { _ = store.handle("/" + mod.id + "/" + command, chat: workspace.active) }
    }
    func resetTurns(_ id: String) { turns[id] = 20 }
    private func chatSummary(_ chat: Chat) -> JSON {
        ["id": chat.sessionID.uuidString, "title": chat.title, "status": chat.status.label, "cwd": chat.cwd,
         "provider": chat.target, "model": chat.model, "busy": chat.busy, "active": chat.sessionID == workspace.activeID]
    }
    private func chat(_ params: JSON) throws -> Chat {
        if let id = params["id"] as? String {
            guard let chat = workspace.chats.first(where: { $0.sessionID.uuidString == id }) else { throw ModError("Чат закрыт или не найден") }
            return chat
        }
        return workspace.active
    }
    func call(_ id: String, method: String, params: JSON, reply: @escaping (Result<Any, Error>) -> Void) {
        do {
            guard let mod = store.activeMods.first(where: { $0.id == id }) else { throw ModError("Мод выключен или его файл изменился") }
            let now = Date(), window = requests[id] ?? (Date.distantPast, 0)
            let count = now.timeIntervalSince(window.0) >= 1 ? 0 : window.1
            guard count < 80 else { throw ModError("Не более 80 вызовов API в секунду") }
            requests[id] = (count == 0 ? now : window.0, count + 1)
            if let permission = ModPolicy.permissions[method], !mod.permissions.contains(permission) { throw ModError("Нет права " + permission) }
            var result: Any = ["ok": true]
            switch method {
            case "app.info": result = ["apiVersion": 2, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "modID": id,
                                       "dataPath": store.dataDirectory(id).path, "assetsPath": try resources(mod).path, "project": workspace.active.cwd,
                                       "remainingTurns": turns[id] ?? 20]
            case "log": log(id, params["message"] as? String ?? "")
            case "ui.toast": workspace.say(String((params["text"] as? String ?? "").prefix(300)))
            case "ui.openPanel": try open(id, panel: params["panel"] as? String ?? "main", placement: params["placement"] as? String)
            case "ui.openTeam": workspace.showTeamChat = true; workspace.showTeamTasks = true; store.mainPanelID = nil
            case "ui.teamSettings": workspace.showTeamRoom = true
            case "ui.openChat": store.mainPanelID = nil
            case "ui.modSettings":
                store.mainPanelID = nil
                UserDefaults.standard.set("mods", forKey: "settingsTab")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.workspace.active.ui.showSettings = true }
            case "settings.get": result = store.settings(for: mod)
            case "settings.set":
                guard let key = params["key"] as? String, (mod.settings ?? [:])[key] != nil, let value = params["value"] as? String, value.count <= 10000 else { throw ModError("Неизвестный параметр мода") }
                store.set(value, key: key, mod: mod)
            case "storage.get":
                let values = (UserDefaults.standard.data(forKey: "mod.storage." + id).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }) ?? [:]
                result = (params["key"] as? String).flatMap { values[$0] } ?? NSNull()
            case "storage.set":
                guard let key = params["key"] as? String, !key.isEmpty, key.count < 100 else { throw ModError("Неверный ключ хранилища") }
                var values = (UserDefaults.standard.data(forKey: "mod.storage." + id).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }) ?? [:]
                let value = params["value"] ?? NSNull()
                if value is NSNull { values[key] = nil } else { values[key] = value }
                guard let bytes = try? JSONSerialization.data(withJSONObject: values), bytes.count <= 400000 else { throw ModError("Хранилище мода ограничено 400 КБ") }
                UserDefaults.standard.set(bytes, forKey: "mod.storage." + id)
            case "secrets.get", "secrets.set":
                guard let key = params["key"] as? String, key.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,79}$", options: .regularExpression) != nil else { throw ModError("Неверное имя секрета") }
                let file = store.dataDirectory(id).appendingPathComponent(".env")
                var values: [String: String] = [:]
                for line in ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: .newlines) {
                    guard let separator = line.firstIndex(of: "=") else { continue }
                    let name = String(line[..<separator]), value = String(line[line.index(after: separator)...])
                    if let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { values[name] = decoded }
                }
                if method == "secrets.get" { result = values[key] ?? NSNull() as Any }
                else {
                    guard let value = params["value"] as? String, value.utf8.count <= 32000 else { throw ModError("Секрет должен быть строкой до 32 КБ") }
                    values[key] = value
                    let text = try values.keys.sorted().map { name in name + "=" + String(data: try JSONSerialization.data(withJSONObject: values[name]!, options: .fragmentsAllowed), encoding: .utf8)! }.joined(separator: "\n") + "\n"
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try Data(text.utf8).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            case "chats.list": result = workspace.chats.map(chatSummary)
            case "chats.read":
                let c = try chat(params), limit = max(1, min(200, params["limit"] as? Int ?? 50))
                var snapshot = chatSummary(c)
                snapshot["messages"] = c.items.suffix(limit).map { ["id": $0.id, "kind": String(describing: $0.kind), "text": String($0.text.prefix(16000)), "done": $0.done] as JSON }
                result = snapshot
            case "chats.create":
                guard workspace.chats.count < 30 else { throw ModError("Открыто уже 30 чатов") }
                var directory: String?
                if let cwd = params["cwd"] as? String {
                    let url = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
                    let root = URL(fileURLWithPath: workspace.active.cwd).standardizedFileURL.resolvingSymlinksInPath()
                    guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw ModError("Новая папка чата должна принадлежать текущему проекту") }
                    directory = url.path
                }
                let c = workspace.newChat(select: params["select"] as? Bool ?? false, forceNew: true)
                if let title = params["title"] as? String { c.customTitle = String(title.prefix(160)) }
                if let directory = directory { c.cwd = directory }
                if let provider = params["provider"] as? String, ["codex", "claude"].contains(provider) { c.target = provider }
                if let model = params["model"] as? String { c.model = model }
                result = chatSummary(c)
            case "chats.send":
                let c = try chat(params)
                guard let text = params["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 200000 else { throw ModError("Нужен текст задачи до 200 КБ") }
                let left = turns[id] ?? 20
                guard left > 0, c.pendingMessages.count < 10 else { throw ModError("Предел автоходов мода или очередь чата заполнена. Дай ещё 20 ходов в настройках мода.") }
                guard !text.hasPrefix("/"), !text.hasPrefix("!") else { throw ModError("chats.send передаёт задачи модели, а не slash или shell-команды") }
                turns[id] = left - 1; c.send("Задача мода «\(mod.name)»:\n" + text)
                result = ["id": c.sessionID.uuidString, "remainingTurns": left - 1]
            case "chats.stop": try chat(params).interrupt()
            case "chats.activate": workspace.activate(try chat(params)); store.mainPanelID = nil
            case "chats.append":
                let c = try chat(params), text = String((params["text"] as? String ?? "").prefix(16000))
                _ = c.add(.note, "Мод «\(mod.name)» · " + text)
            case "files.list", "files.read", "files.write", "git.status", "git.diff":
                let c = try chat(params), root = URL(fileURLWithPath: c.cwd)
                if method.hasPrefix("git.") { result = try ProjectGit.run(method == "git.status" ? ["status", "--short"] : ["diff", "--stat"], at: root).text }
                else {
                    let file = try ModPolicy.path(params["path"] as? String ?? "", root: root)
                    if method == "files.list" {
                        result = try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil).prefix(500).compactMap { candidate -> String? in
                            (try? ModPolicy.path(candidate.lastPathComponent, root: file)) == nil ? nil : candidate.lastPathComponent
                        }
                    } else if method == "files.read" {
                        guard let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber, size.intValue <= 1000000 else { throw ModError("Файл больше 1 МБ") }
                        result = try String(contentsOf: file, encoding: .utf8)
                    } else {
                        guard let text = params["text"] as? String, text.utf8.count <= 1000000 else { throw ModError("Нужен UTF-8 текст до 1 МБ") }
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(text.utf8).write(to: file, options: .atomic)
                    }
                }
            case "team.state":
                let team = TeamRoomModel.shared
                result = ["connected": team.connected, "peers": team.peers, "identity": team.identity, "ready": team.boardReady,
                          "board": try JSONSerialization.jsonObject(with: JSONEncoder().encode(team.board)),
                          "working": team.working, "canClaim": team.canClaim, "blockReason": team.claimBlockReason ?? "",
                          "running": team.running.map { ["chat": $0.key.uuidString, "task": $0.value.uuidString] },
                          "messages": team.conversation.suffix(100).map { ["author": $0.author, "text": $0.text, "id": $0.id.uuidString] }]
            case "team.send":
                let team = TeamRoomModel.shared
                guard team.connected, team.peers > 0, let text = params["text"] as? String, text.utf8.count <= 16000 else { throw ModError("Нет прямой связи или сообщение больше 16 КБ") }
                let saved = team.draft; team.draft = "Мод «\(mod.name)»: " + text; team.send(); team.draft = saved
            case "team.addTask":
                let team = TeamRoomModel.shared
                guard team.boardReady, let title = params["title"] as? String, title.count <= 160 else { throw ModError("Доска не готова или неверное название") }
                team.addTask(title: title, detail: String((params["detail"] as? String ?? "").prefix(8000)))
            case "team.claim":
                let team = TeamRoomModel.shared
                guard team.canClaim, let ids = params["ids"] as? [String], ids.count <= 3 else { throw ModError("Можно взять до трёх свободных задач с подтверждённой доски") }
                let values = Set(ids.compactMap(UUID.init(uuidString:)))
                guard values.count == ids.count, values.allSatisfy({ id in team.board.tasks.contains { $0.id == id && $0.status == .available } }) else { throw ModError("Задачи уже заняты или не найдены") }
                let left = turns[id] ?? 20
                guard left >= values.count else { throw ModError("Предел автоходов мода") }
                turns[id] = left - values.count; team.selected = values; team.claim(workspace)
            case "process.start":
                guard let name = params["id"] as? String, name.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil,
                      let executable = params["executable"] as? String, executable.hasPrefix("/"),
                      let arguments = params["arguments"] as? [String], arguments.count <= 60 else { throw ModError("Нужны id, абсолютный executable и arguments[]") }
                let key = id + "/" + name
                if let (process, _) = processes[key], process.isRunning { result = ["pid": process.processIdentifier, "running": true]; break }
                guard processes.filter({ $0.key.hasPrefix(id + "/") && $0.value.0.isRunning }).count < 8 else { throw ModError("Не более 8 процессов одного мода") }
                let root = store.dataDirectory(id); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let output = root.appendingPathComponent("process-" + name + ".log")
                FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: output)
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: workspace.active.cwd)
                var environment = ProcessInfo.processInfo.environment
                environment["PULT_MOD_DATA"] = root.path; environment["PULT_MOD_ASSETS"] = try resources(mod).path
                if let supplied = params["environment"] as? [String: String], supplied.count <= 30 { environment.merge(supplied) { _, new in new } }
                process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
                process.terminationHandler = { [weak self] process in
                    try? handle.close()
                    DispatchQueue.main.async { self?.emit("process.exited", ["id": name, "code": process.terminationStatus], modID: id) }
                }
                try process.run(); processes[key] = (process, output)
                result = ["pid": process.processIdentifier, "running": true]
            case "process.stop", "process.read":
                guard let name = params["id"] as? String, let (process, file) = processes[id + "/" + name] else { throw ModError("Процесс этого мода не найден") }
                if method == "process.stop" { if process.isRunning { terminate(process) }; processes[id + "/" + name] = nil }
                else {
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    let size = try handle.seekToEnd(); try handle.seek(toOffset: size > 100000 ? size - 100000 : 0)
                    result = ["running": process.isRunning, "text": String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)]
                }
            case "network.fetch":
                guard let text = params["url"] as? String, let url = URL(string: text), ModPolicy.allows(url, mod: mod) else { throw ModError("Адрес не разрешён доменами мода или политикой HTTPS") }
                var request = URLRequest(url: url); request.timeoutInterval = 30
                request.httpMethod = params["method"] as? String ?? "GET"
                if let headers = params["headers"] as? [String: String] {
                    for (key, value) in headers {
                        guard !key.contains("\n"), !value.contains("\n"), !key.contains("\r"), !value.contains("\r") else { throw ModError("Неверный HTTP-заголовок") }
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
                if let body = params["body"] as? String { guard body.utf8.count <= 1000000 else { throw ModError("Запрос больше 1 МБ") }; request.httpBody = Data(body.utf8) }
                let session = URLSession(configuration: .ephemeral, delegate: ModNetworkPolicy(mod: mod), delegateQueue: nil)
                session.dataTask(with: request) { [weak self] data, response, error in
                    session.finishTasksAndInvalidate()
                    DispatchQueue.main.async {
                        guard self?.store.activeMods.contains(where: { $0.id == id && $0.fingerprint == mod.fingerprint }) == true else { reply(.failure(ModError("Мод отключён во время запроса"))); return }
                        if let error = error { reply(.failure(error)); return }
                        guard let data = data, data.count <= 8000000, let response = response as? HTTPURLResponse else { reply(.failure(ModError("Ответ больше 8 МБ или отсутствует"))); return }
                        reply(.success(["status": response.statusCode, "body": String(decoding: data, as: UTF8.self)]))
                    }
                }.resume()
                return
            case "internal.commandFinished":
                if let token = params["id"] as? String, let command = commands[token], command.0 == id {
                    DispatchQueue.main.async { [weak self] in if let (_, web, bridge) = self?.commands.removeValue(forKey: token) { bridge.dispose(web) } }
                }
            default: throw ModError("Неизвестный метод API: " + method)
            }
            reply(.success(result))
        } catch { reply(.failure(error)) }
    }
}

private final class ModNetworkPolicy: NSObject, URLSessionTaskDelegate {
    let mod: PultMod
    init(mod: PultMod) { self.mod = mod }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { ModPolicy.allows($0, mod: mod) } == true ? request : nil)
    }
}

final class ModWebBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let mod: PultMod
    var registration: UUID?
    init(mod: PultMod) { self.mod = mod }
    static let javascript = """
    (()=>{const listeners=new Map(); window.__pultEvent=({event,detail})=>{for(const fn of [...(listeners.get(event)||[])]){try{fn(detail)}catch(e){console.error(e)}}};
    window.pult=Object.freeze({apiVersion:2,call:(method,params={})=>window.webkit.messageHandlers.pult.postMessage({method,params}),
    on:(event,fn)=>{const list=listeners.get(event)||new Set();list.add(fn);listeners.set(event,list);return()=>list.delete(fn)}});
    window.addEventListener('unhandledrejection',e=>{pult.call('log',{message:String(e.reason)}).catch(()=>{})});})();
    """
    func make(html: String, script: String? = nil) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "pult")
        config.userContentController.addUserScript(WKUserScript(source: Self.javascript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let data = try? JSONSerialization.data(withJSONObject: ModPlatform.shared.store.settings(for: mod)), let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.pultSettings=" + json, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let script = script { config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)) }
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = self
        registration = ModPlatform.shared.register(view, mod: mod.id)
        var network = "'none'"
        if mod.permissions.contains("network") {
            if let domains = mod.networkDomains {
                network = domains.flatMap { domain in ["https", "http", "wss", "ws"].map { $0 + "://" + domain + ":*" } }.joined(separator: " ")
            } else { network = "https: http: wss: ws:" }
        }
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: \(network); connect-src \(network); font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'"
        view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + html, baseURL: nil)
        return view
    }
    func dispose(_ view: WKWebView) {
        ModPlatform.shared.unregister(registration); registration = nil
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "pult")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard ModPlatform.shared.store.activeMods.contains(where: { $0.id == mod.id && $0.fingerprint == mod.fingerprint }),
              message.frameInfo.isMainFrame, let body = message.body as? JSON, let method = body["method"] as? String,
              let bytes = try? JSONSerialization.data(withJSONObject: body), bytes.count <= 1000000 else { replyHandler(nil, "Неверный вызов API"); return }
        ModPlatform.shared.call(mod.id, method: method, params: body["params"] as? JSON ?? [:]) {
            switch $0 { case .success(let value): replyHandler(value, nil); case .failure(let error): replyHandler(nil, error.localizedDescription) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ModPlatform.shared.log(mod.id, "WebKit остановил процесс мода. Открой панель заново.") }
}

struct ModDockView: View {
    @ObservedObject var store = ModStore.shared
    let key: String
    let placement: String
    var body: some View {
        if let mod = store.activeMods.first(where: { key.hasPrefix($0.id + "/") }), let panel = mod.allPanels.first(where: { key == mod.id + "/" + $0.id }) {
            VStack(spacing: 0) {
                HStack {
                    Label(panel.title, systemImage: "puzzlepiece.extension").font(.headline)
                    Spacer()
                    Menu {
                        ForEach(["main", "left", "right", "sheet"], id: \.self) { target in
                            Button(["main": "Основная область", "left": "Слева", "right": "Справа", "sheet": "Отдельная панель"][target]!) {
                                close(); try? ModPlatform.shared.open(mod.id, panel: panel.id, placement: target)
                            }
                        }
                    } label: { Image(systemName: "rectangle.3.group") }.menuStyle(.borderlessButton).frame(width: 26)
                    Button("Закрыть", action: close)
                }.padding(12)
                Divider()
                ModPanel(mod: mod, settings: store.settings(for: mod), html: panel.html).id(mod.fingerprint + panel.id)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func close() {
        switch placement { case "main": store.mainPanelID = nil; case "left": store.leftPanelID = nil; case "right": store.rightPanelID = nil; default: store.panelID = nil }
    }
}

struct ModActionButtons: View {
    @ObservedObject var store = ModStore.shared
    let location: String
    var body: some View {
        ForEach(store.activeMods) { mod in
            ForEach((location == "sidebar" ? mod.sidebar : location == "toolbar" ? mod.toolbar : mod.statusbar) ?? []) { action in
                Button { ModPlatform.shared.action(action, mod: mod) } label: {
                    if location == "sidebar" { Label(action.title, systemImage: action.icon ?? "puzzlepiece.extension").font(.system(size: 12)) }
                    else { Image(systemName: action.icon ?? "puzzlepiece.extension") }
                }.buttonStyle(.plain).help(mod.name + " · " + action.title)
            }
        }
    }
}

struct ModAppCommands: Commands {
    @ObservedObject var store = ModStore.shared
    var body: some Commands {
        CommandMenu("Моды") {
            Button("Настройки модов") { _ = store.handle("/mods", chat: Workspace.shared.active) }
            ForEach(store.activeMods) { mod in
                ForEach(mod.commands, id: \.name) { command in
                    Button(mod.name + " · " + command.title) { _ = store.handle("/" + mod.id + "/" + command.name, chat: Workspace.shared.active) }
                        .modifier(ModShortcut(value: command.shortcut))
                }
            }
        }
    }
}

private struct ModShortcut: ViewModifier {
    let value: String?
    func body(content: Content) -> some View {
        if let value = value, let character = value.split(separator: "+").last, character.count == 1 {
            let parts = value.lowercased().split(separator: "+")
            let modifiers: EventModifiers = parts.reduce(into: []) { result, part in
                if part == "cmd" { result.insert(.command) }; if part == "shift" { result.insert(.shift) }
                if part == "alt" { result.insert(.option) }; if part == "ctrl" { result.insert(.control) }
            }
            content.keyboardShortcut(KeyEquivalent(Character(String(character))), modifiers: modifiers)
        } else { content }
    }
}
