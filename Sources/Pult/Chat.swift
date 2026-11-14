// Модель чата: диалог Codex, поток ответа, команды, разрешения, авто-переключение аккаунтов.
import AppKit
import Foundation

enum Kind { case user, agent, command, file, thinking, note, error, approval, question }

final class Item: ObservableObject, Identifiable {
    let id: String
    let kind: Kind
    @Published var text: String
    @Published var output = ""
    @Published var done = false
    @Published var exitCode: Int? = nil
    @Published var decision: String? = nil       // для разрешений
    @Published var expanded = false
    @Published var hover = false
    var rpcId: Any? = nil
    var legacy = false                           // старый формат ответа (approved/denied)
    @Published var autoApproved = false
    var rpcKind = "exec"                         // exec / patch / elicitation / permissions
    var claude = false                           // строка от Claude, а не от Codex
    var images: [String] = []                    // вложенные картинки (для истории)
    @Published var questionAnswers: [String: String] = [:]
    weak var questionClient: CodexClient?
    var payload: JSON = [:]
    init(_ id: String, _ kind: Kind, _ text: String) { self.id = id; self.kind = kind; self.text = text }
}

struct ThreadInfo: Identifiable, Hashable {
    let id: String
    let path: String
    let title: String
    let date: Date
    let account: String
    let cwd: String
}

/// Название и папка диалога из начала его файла (кэш по пути+времени изменения).
private var titleCache: [String: (Date, String, String)] = [:]
private let titleLock = NSLock()
func threadTitle(_ path: String, _ mtime: Date) -> (String, String) {
    titleLock.lock(); defer { titleLock.unlock() }
    if let c = titleCache[path], c.0 == mtime { return (c.1, c.2) }
    var title = "", cwd = ""
    if let h = FileHandle(forReadingAtPath: path) {
        let data = h.readData(ofLength: 400_000); try? h.close()
        for line in data.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSON, let p = o["payload"] as? JSON else { continue }
            if o["type"] as? String == "session_meta" { cwd = (p["cwd"] as? String) ?? cwd }
            if p["type"] as? String == "item_completed", let it = p["item"] as? JSON, it["type"] as? String == "UserMessage" {
                title = ((it["content"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
            } else if p["type"] as? String == "user_message" { title = (p["message"] as? String) ?? "" }
            if !title.isEmpty { break }
        }
    }
    title = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    if title.isEmpty { title = "(без текста)" }
    titleCache[path] = (mtime, title, cwd)
    return (title, cwd)
}

struct Limits { var five: Double?; var week: Double?; var fiveReset: Double?; var weekReset: Double? }

final class Chat: ObservableObject {
    @Published var items: [Item] = []
    @Published var busy = false
    @Published var connecting = false
    @Published var accounts = loadAccounts()
    @Published var current = 0
    @Published var limits: [String: Limits] = [:]          // по CODEX_HOME
    @Published var model = "gpt-6.1-sol"
    @Published var claudeModel = ""
    @Published var showCommandSettings = false
    @Published var claudeUsage = "Пока нет завершённых ходов."
    @Published var codexInputTokens: Int? = nil
    @Published var codexOutputTokens: Int? = nil
    @Published var codexCachedTokens: Int? = nil
    @Published var claudeInputTokens: Int? = nil
    @Published var claudeOutputTokens: Int? = nil
    @Published var claudeCachedTokens: Int? = nil
    @Published var cwd = UserDefaults.standard.string(forKey: "workingDirectory") ?? homeDir {
        didSet { UserDefaults.standard.set(cwd, forKey: "workingDirectory") }
    }
    @Published var sandbox = "workspace-write"
    @Published var turnStarted: Date? = nil
    @Published var notifyTelegram = true
    @Published var autoApprove = UserDefaults.standard.object(forKey: "autoApprove") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoApprove, forKey: "autoApprove") }
    }
    @Published var target = "codex"                     // кому пишем: codex / claude
    @Published var pendingMessages: [QueuedMessage] = []
    @Published var queuePaused = false
    var queueContext = UUID()
    @Published var attachments: [String] = []           // пути картинок к следующему сообщению
    private var claudeProc: Process?
    private var claudeItems: [String: Item] = [:]
    private var claudeText: Item?
    var autoSwitch = true

    private var client: CodexClient?
    @Published private(set) var threadId: String?
    @Published var threads: [ThreadInfo] = []
    @Published var showSidebar = UserDefaults.standard.object(forKey: "sidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "sidebar") }
    }
    private var threadLoaded = false
    private var turnId: String?
    private var index: [String: Item] = [:]
    private var queuedPrompt: String?
    private var triedThisTurn: Set<Int> = []

    var account: Account { accounts[min(current, accounts.count - 1)] }

    init(connectImmediately: Bool = true) { if connectImmediately { connect(bestAccount()); loadThreads() } }

    // MARK: список диалогов

    /// Диалоги всех аккаунтов (у одного диалога может быть копия в нескольких — берём свежую).
    func loadThreads() {
        let accs = accounts
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var best: [String: (path: String, date: Date, account: String)] = [:]
            for a in accs {
                guard let e = fm.enumerator(atPath: a.home + "/sessions") else { continue }
                for case let rel as String in e where rel.hasSuffix(".jsonl") && (rel as NSString).lastPathComponent.hasPrefix("rollout-") {
                    let path = a.home + "/sessions/" + rel
                    let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                    guard name.count > 36 else { continue }
                    let tid = String(name.suffix(36))
                    let m = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    if best[tid] == nil || m > best[tid]!.date { best[tid] = (path, m, a.name) }
                }
            }
            let list = best.sorted { $0.value.date > $1.value.date }.prefix(200).map { tid, v -> ThreadInfo in
                let (title, cwd) = threadTitle(v.path, v.date)
                return ThreadInfo(id: tid, path: v.path, title: title, date: v.date, account: v.account, cwd: cwd)
            }
            DispatchQueue.main.async { self.threads = Array(list) }
        }
    }

    /// Открыть прошлый диалог на текущем аккаунте и показать историю.
    func open(_ t: ThreadInfo) {
        guard let c = client, t.id != threadId else { return }
        queueContext = UUID()
        codexInputTokens = nil; codexOutputTokens = nil; codexCachedTokens = nil
        if busy { interrupt() }
        items = []; index = [:]; threadId = t.id; threadLoaded = false
        if !t.cwd.isEmpty, FileManager.default.fileExists(atPath: t.cwd) { cwd = t.cwd }
        let path = localRollout(t.id, in: account.home, homes: accounts.map(\.home)) ?? t.path
        c.call("thread/resume", ["threadId": t.id, "path": path, "cwd": cwd, "approvalPolicy": "on-request",
                                 "sandbox": sandbox, "model": model]) { [weak self] r in
            dbg("resume reply keys=\(Array(r.keys)) err=\(String(describing: r["error"]).prefix(300))")
            guard let self = self, self.threadId == t.id else { return }
            guard let th = (r["result"] as? JSON)?["thread"] as? JSON else {
                self.add(.error, "Не удалось открыть диалог: " + (((r["error"] as? JSON)?["message"] as? String) ?? "?")); self.dumpAutotest(); return
            }
            self.threadLoaded = true
            for turn in (th["turns"] as? [JSON]) ?? [] {
                for it in (turn["items"] as? [JSON]) ?? [] { self.addHistory(it) }
            }
            if self.items.isEmpty { self.add(.note, "История пуста — пиши, диалог продолжится.") }
            else { self.add(.note, "— продолжаем здесь на «\(self.account.name)» —") }
            if let f = ProcessInfo.processInfo.environment["PULT_AUTOFOLLOW"] { self.send(f) } else { self.dumpAutotest() }
        }
    }

    private func addHistory(_ it: JSON) {
        let id = (it["id"] as? String) ?? UUID().uuidString
        switch it["type"] as? String {
        case "userMessage":
            let t = ((it["content"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !t.isEmpty { add(.user, t, id: id).done = true }
        case "agentMessage":
            if let t = it["text"] as? String, !t.isEmpty { add(.agent, t, id: id).done = true }
        case "commandExecution":
            let i = add(.command, cleanCommand((it["command"] as? String) ?? ""), id: id)
            i.output = String(((it["aggregatedOutput"] as? String) ?? "").suffix(6000))
            i.exitCode = (it["exitCode"] as? NSNumber)?.intValue; i.done = true
        case "fileChange":
            let paths = ((it["changes"] as? [JSON]) ?? []).compactMap { $0["path"] as? String }
            add(.file, paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), id: id).done = true
        case "mcpToolCall":
            let i = add(.command, "\((it["server"] as? String) ?? "mcp").\((it["tool"] as? String) ?? "")", id: id)
            i.legacy = true; i.done = true
        default: break
        }
    }

    // MARK: аккаунты

    func remaining(_ a: Account) -> Double? {
        guard let l = limits[a.home] else { return nil }
        let vals = [l.five, l.week].compactMap { $0 }.map { 100 - $0 }
        return vals.min()
    }

    func bestAccount(excluding: Set<Int> = []) -> Int {
        let idx = accounts.indices.filter { !excluding.contains($0) }
        return idx.max { (remaining(accounts[$0]) ?? 50) < (remaining(accounts[$1]) ?? 50) } ?? 0
    }

    /// Обновить лимиты всех аккаунтов (короткие app-server без запуска модели).
    private var pendingLimits = 0
    private var pickedInitial = false

    func refreshAllLimits() {
        pendingLimits = accounts.count
        for a in accounts where a.home != account.home {
            let c = CodexClient(home: a.home)
            c.start { [weak self] ok in
                guard ok else { c.stop(); return }
                c.call("account/rateLimits/read", [:]) { r in
                    if let rl = ((r["result"] as? JSON)?["rateLimits"]) as? JSON { self?.storeLimits(a.home, rl) }
                    else { self?.limits[a.home] = Limits(five: 100, week: 100) }   // нет входа → считаем пустым
                    c.stop()
                    self?.limitArrived()
                }
            }
        }
        client?.call("account/rateLimits/read", [:]) { [weak self] r in
            guard let self = self else { return }
            if let rl = ((r["result"] as? JSON)?["rateLimits"]) as? JSON { self.storeLimits(self.account.home, rl) }
            self.limitArrived()
        }
    }

    /// Первый запуск: когда известны лимиты всех аккаунтов и диалога ещё нет — перейти на самый свободный.
    private func limitArrived() {
        pendingLimits -= 1
        dbg("limitArrived pending=\(pendingLimits) picked=\(pickedInitial)")
        guard pendingLimits <= 0, !pickedInitial else { return }
        pickedInitial = true
        var best = bestAccount()
        if let f = ProcessInfo.processInfo.environment["PULT_ACCOUNT"].flatMap(Int.init), accounts.indices.contains(f) { best = f }
        let forced = ProcessInfo.processInfo.environment["PULT_ACCOUNT"] != nil
        if autoSwitch, threadId == nil, !busy, best != current, forced || (remaining(accounts[best]) ?? 0) > (remaining(account) ?? 0) {
            connect(best) { [weak self] in self?.autotest() }
        } else { autotest() }
    }

    /// PULT_AUTOTEST="текст": отправить и записать диалог в Application Support/PultPublic/autotest.log (самопроверка).
    private func autotest() {
        if ProcessInfo.processInfo.environment["PULT_AUTOOPEN"] == "1" {      // открыть последний диалог
            func tryOpen(_ n: Int) {
                dbg("tryOpen threads=\(threads.count) client=\(client != nil)")
                if let t = threads.first { dbg("open \(t.id) \(t.path)"); open(t) } else if n > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryOpen(n - 1) } }
            }
            tryOpen(20); return
        }
        guard let t = ProcessInfo.processInfo.environment["PULT_AUTOTEST"], !t.isEmpty else { return }
        if let tg = ProcessInfo.processInfo.environment["PULT_TARGET"] { target = tg }
        if let img = ProcessInfo.processInfo.environment["PULT_ATTACH"] { attachments = [img] }
        send(t)
    }
    func dumpAutotest() {
        guard ProcessInfo.processInfo.environment["PULT_AUTOTEST"] != nil else { return }
        let lines = ["account=\(account.name) thread=\(threadId ?? "-")"] + items.map { "[\($0.kind)] \($0.text) \($0.output.isEmpty ? "" : "⎿ " + String($0.output.suffix(200)))" }
        try? lines.joined(separator: "\n").write(toFile: appDataDir + "/autotest.log", atomically: true, encoding: .utf8)
    }

    func storeLimits(_ home: String, _ rl: JSON) {
        var l = Limits()
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? JSON, let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let mins = (w["windowDurationMins"] as? NSNumber)?.doubleValue ?? 0
            let reset = (w["resetsAt"] as? NSNumber)?.doubleValue
            if mins <= 300 { l.five = used; l.fiveReset = reset } else { l.week = used; l.weekReset = reset }
        }
        limits[home] = l
    }

    func connect(_ idx: Int, then: (() -> Void)? = nil) {
        client?.stop()
        current = idx
        threadLoaded = false
        connecting = true
        let c = CodexClient(home: account.home, extraEnv: Proxy.shared.env)
        client = c
        c.onNotification = { [weak self, weak c] m, p in
            guard let self = self, c === self.client else { return }
            self.notification(m, p)
        }
        c.onServerRequest = { [weak self, weak c] id, m, p in
            guard let self = self, c === self.client else { return }
            self.serverRequest(id, m, p)
        }
        c.onExit = { [weak self, weak c] in
            guard let self = self, c === self.client else { return }
            self.busy = false; self.connecting = false
            self.add(.error, "Codex (\(self.account.name)) завершился. Выбери аккаунт заново.")
        }
        c.start { [weak self] ok in
            guard let self = self, c === self.client else { return }
            self.connecting = false
            if !ok { self.add(.error, "Не удалось запустить Codex для \(self.account.name)."); return }
            c.call("account/read", ["refreshToken": false]) { r in
                if ((r["result"] as? JSON)?["account"]) is NSNull || (r["result"] as? JSON)?["account"] == nil {
                    self.add(.note, "У «\(self.account.name)» нет входа — нажми «Войти» в меню аккаунтов.")
                }
            }
            self.refreshAllLimits()
            then?()
            self.drainQueue()
        }
    }

    func switchTo(_ idx: Int, prompt: String? = nil) {
        guard idx != current || client == nil else { return }
        let from = account.name
        connect(idx) { [weak self] in
            guard let self = self else { return }
            if self.threadId != nil { self.add(.note, "⇄ \(from) → \(self.account.name): тот же диалог продолжается здесь.") }
            if let p = prompt { self.send(p, echo: false) }
        }
    }

    // MARK: диалог

    func newChat() {
        queueContext = UUID()
        codexInputTokens = nil; codexOutputTokens = nil; codexCachedTokens = nil
        claudeInputTokens = nil; claudeOutputTokens = nil; claudeCachedTokens = nil
        if busy { interrupt() }
        items = []; index = [:]; threadId = nil; threadLoaded = false
        loadThreads()
    }

    func send(_ text: String, echo: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if handleSlash(t) { return }
        guard !t.isEmpty || !attachments.isEmpty else { return }
        if busy || (target == "claude" && claudeProc?.isRunning == true) || (connecting && target == "codex") {
            pendingMessages.append(QueuedMessage(text: t, images: attachments, provider: target, directory: cwd, context: queueContext))
            attachments = []
            return
        }
        if target == "claude" { sendClaude(t, echo: echo); return }
        let imgs = attachments
        guard !t.isEmpty || !imgs.isEmpty, let c = client else { return }
        attachments = []
        var input: [JSON] = []
        if !t.isEmpty { input.append(["type": "text", "text": t, "text_elements": []]) }
        for p in imgs { input.append(["type": "localImage", "path": p]) }
        if echo { add(.user, t.isEmpty ? "(картинка)" : t).images = imgs }
        busy = true
        turnStarted = Date()
        triedThisTurn = [current]
        withThread { [weak self] tid in
            guard let self = self, let tid = tid else { self?.busy = false; return }
            self.client?.call("turn/start", ["threadId": tid, "model": self.model, "input": input]) { r in
                if let e = r["error"] as? JSON { self.busy = false; self.add(.error, (e["message"] as? String) ?? "turn/start: ошибка") }
            }
        }
    }

    private func withThread(_ cb: @escaping (String?) -> Void) {
        guard let c = client else { cb(nil); return }
        let common: JSON = ["cwd": cwd, "approvalPolicy": "on-request", "sandbox": sandbox, "model": model]
        if let tid = threadId, threadLoaded { cb(tid); return }
        if let tid = threadId {
            var p = common; p["threadId"] = tid
            if let path = localRollout(tid, in: account.home, homes: accounts.map(\.home)) { p["path"] = path }
            c.call("thread/resume", p) { [weak self] r in
                if r["error"] != nil { self?.add(.error, "Не удалось продолжить диалог на этом аккаунте"); cb(nil); return }
                self?.threadLoaded = true; cb(tid)
            }
            return
        }
        c.call("thread/start", common) { [weak self] r in
            guard let th = (r["result"] as? JSON)?["thread"] as? JSON, let tid = th["id"] as? String else {
                self?.add(.error, "Не удалось создать диалог"); cb(nil); return
            }
            self?.threadId = tid; self?.threadLoaded = true; cb(tid)
        }
    }

    func resumeQueue() { queuePaused = false; drainQueue() }

    func drainQueue() {
        guard !busy, !queuePaused, !connecting, !pendingMessages.isEmpty,
              !items.contains(where: { $0.kind == .question && $0.decision == nil }),
              claudeProc?.isRunning != true else { return }
        let next = pendingMessages[0]
        guard next.provider == target, next.directory == cwd, next.context == queueContext else { return }
        if next.provider == "codex", client == nil { return }
        pendingMessages.removeFirst()
        let savedAttachments = attachments
        attachments = next.images
        send(next.text)
        attachments = savedAttachments
    }

    func interrupt() {
        queuePaused = true
        if let p = claudeProc, p.isRunning { p.terminate(); return }
        guard let tid = threadId, let turn = turnId else { return }
        client?.call("turn/interrupt", ["threadId": tid, "turnId": turn])
    }

    // MARK: события

    @discardableResult
    func add(_ k: Kind, _ text: String, id: String = UUID().uuidString) -> Item {
        let it = Item(id, k, text)
        items.append(it); index[id] = it
        return it
    }

    private func notification(_ m: String, _ p: JSON) {
        let item = p["item"] as? JSON
        let itemId = (p["itemId"] as? String) ?? (item?["id"] as? String) ?? ""
        switch m {
        case "thread/tokenUsage/updated":
            if let id = p["threadId"] as? String, id != threadId { return }
            if let total = (p["tokenUsage"] as? JSON)?["total"] as? JSON {
                codexInputTokens = (total["inputTokens"] as? NSNumber)?.intValue
                codexOutputTokens = (total["outputTokens"] as? NSNumber)?.intValue
                codexCachedTokens = (total["cachedInputTokens"] as? NSNumber)?.intValue
            }
        case "turn/started":
            turnId = (p["turn"] as? JSON)?["id"] as? String
            busy = true
        case "item/started":
            guard let it = item, let type = it["type"] as? String else { return }
            switch type {
            case "agentMessage": add(.agent, (it["text"] as? String) ?? "", id: itemId)
            case "commandExecution": add(.command, cleanCommand((it["command"] as? String) ?? ""), id: itemId)
            case "fileChange":
                let paths = ((it["changes"] as? [JSON]) ?? []).compactMap { $0["path"] as? String }
                add(.file, paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), id: itemId)
            case "reasoning": add(.thinking, "", id: itemId)
            case "mcpToolCall":
                add(.command, "\((it["server"] as? String) ?? "mcp").\((it["tool"] as? String) ?? "")", id: itemId).legacy = true
            default: break
            }
        case "item/agentMessage/delta":
            index[itemId]?.text += (p["delta"] as? String) ?? ""
        case "item/reasoning/summaryTextDelta":
            index[itemId]?.text += (p["delta"] as? String) ?? ""
        case "item/commandExecution/outputDelta":
            if let i = index[itemId] { i.output = String((i.output + ((p["delta"] as? String) ?? "")).suffix(6000)) }
        case "item/completed":
            guard let it = item, let i = index[itemId] else { return }
            i.done = true
            if let t = it["text"] as? String, i.kind == .agent { i.text = t }
            if i.kind == .command, it["type"] as? String == "mcpToolCall" {
                i.exitCode = (it["status"] as? String) == "failed" ? 1 : 0
                let content = ((it["result"] as? JSON)?["content"] as? [JSON]) ?? []
                i.output = String(content.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(3000))
            } else if i.kind == .command {
                i.exitCode = (it["exitCode"] as? NSNumber)?.intValue
                if let out = it["aggregatedOutput"] as? String, !out.isEmpty { i.output = String(out.suffix(6000)) }
            }
            if i.kind == .thinking, i.text.isEmpty {
                i.text = ((it["summary"] as? [String]) ?? []).joined(separator: " ")
                if i.text.isEmpty { items.removeAll { $0 === i } }
            }
        case "account/rateLimits/updated":
            if let rl = p["rateLimits"] as? JSON { storeLimits(account.home, rl) }
        case "turn/completed":
            turnCompleted(p["turn"] as? JSON ?? [:])
        case "error":
            if let e = p["error"] as? JSON, let msg = e["message"] as? String, p["willRetry"] as? Bool != true { add(.error, msg) }
        default: break
        }
    }

    private func turnCompleted(_ turn: JSON) {
        busy = false
        defer { dumpAutotest(); loadThreads() }
        let err = turn["error"] as? JSON
        let info = err?["codexErrorInfo"] as? String
        let took = Date().timeIntervalSince(turnStarted ?? Date())
        if info == "usageLimitExceeded" && autoSwitch {
            triedThisTurn.insert(current)
            let next = bestAccount(excluding: triedThisTurn)
            if !triedThisTurn.contains(next), (remaining(accounts[next]) ?? 1) > 0 {
                add(.note, "⚡ Лимит «\(account.name)» кончился → \(accounts[next].name)")
                switchTo(next, prompt: "Лимит прошлого аккаунта кончился, тебя переключили на другой аккаунт с этим же диалогом. Продолжай ровно с того места, где остановился.")
                return
            }
            add(.error, "Лимиты кончились на всех аккаунтах. Диалог сохранён.")
            return
        }
        if let e = err, let msg = e["message"] as? String, turn["status"] as? String != "interrupted" { add(.error, msg) }
        if turn["status"] as? String == "interrupted" { add(.note, "Прервано.") }
        if err != nil || turn["status"] as? String == "interrupted" { queuePaused = true }
        else { DispatchQueue.main.async { [weak self] in self?.drainQueue() } }
        if took > 60 { notifyDone(took, failed: err != nil) }
        // Заранее: если осталось меньше 5% — следующий ход пойдёт на другом аккаунте.
        if autoSwitch, let r = remaining(account), r < 5 {
            let next = bestAccount(excluding: [current])
            if (remaining(accounts[next]) ?? 0) > r {
                add(.note, "У «\(account.name)» осталось \(Int(r))% → заранее переключаю на «\(accounts[next].name)».")
                switchTo(next)
            }
        }
    }

    private func notifyDone(_ took: TimeInterval, failed: Bool) {
        guard notifyTelegram, !(NSApp?.isActive ?? true) else { return }
        let last = items.last { $0.kind == .agent }?.text ?? ""
        let head = failed ? "❌ Codex остановился с ошибкой" : "✅ Codex закончил"
        let text = "\(head) · \(Int(took / 60)) мин · \(account.name)\n\n" + String(last.prefix(600))
        notifyMac("Пульт", text)
    }

    private func serverRequest(_ id: Any, _ m: String, _ p: JSON) {
        switch m {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let cmd = (p["command"] as? String) ?? ((p["command"] as? [String])?.joined(separator: " ")) ?? "команда"
            let it = add(.approval, "Выполнить: " + cmd + ((p["reason"] as? String).map { "\n\($0)" } ?? ""))
            it.rpcId = id; it.legacy = m == "execCommandApproval"
            if !autoApprove { attention() }
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let it = add(.approval, "Изменить файлы" + ((p["reason"] as? String).map { ": \($0)" } ?? ""))
            it.rpcId = id; it.legacy = m == "applyPatchApproval"
        case "mcpServer/elicitation/request":
            let server = (p["serverName"] as? String) ?? "MCP"
            let it = add(.approval, "\(server): " + ((p["message"] as? String) ?? "запрос разрешения"))
            it.rpcId = id; it.rpcKind = "elicitation"; it.payload = p
            if !autoApprove || Self.mcpConfirmationContent(p) == nil { attention() }
        case "item/permissions/requestApproval":
            let perms = (p["permissions"] as? JSON) ?? [:]
            var what: [String] = []
            if !(perms["network"] is NSNull), perms["network"] != nil { what.append("сеть") }
            if !(perms["fileSystem"] is NSNull), perms["fileSystem"] != nil { what.append("файлы вне песочницы") }
            let it = add(.approval, "Доп. права: " + (what.isEmpty ? "?" : what.joined(separator: ", ")) + ((p["reason"] as? String).map { "\n\($0)" } ?? ""))
            it.rpcId = id; it.rpcKind = "permissions"; it.payload = perms
            if !autoApprove { attention() }
        case "item/tool/requestUserInput":
            presentQuestion(id: id, params: p)
        default:
            add(.note, "Codex прислал запрос \(m) — Пульт его пока не умеет, отклонил.")
            client?.reject(id, "Пульт не поддерживает \(m)")
        }
        approvePendingIfEnabled()
    }

    func toggleAutoApprove() {
        autoApprove.toggle()
        approvePendingIfEnabled()
    }

    private func approvePendingIfEnabled() {
        guard autoApprove else { return }
        for it in items where it.kind == .approval && it.decision == nil {
            if it.rpcKind == "elicitation", Self.mcpConfirmationContent(it.payload) == nil { continue }
            it.autoApproved = true
            answer(it, "accept")
        }
    }

    static func mcpConfirmationContent(_ params: JSON) -> JSON? {
        if params["mode"] as? String == "url" { return nil }
        let schema = params["requestedSchema"] as? JSON ?? [:]
        let properties = schema["properties"] as? [String: JSON] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        var content: JSON = [:]
        for (name, property) in properties {
            if let value = property["default"] { content[name] = value }
            else if required.contains(name), property["type"] as? String == "boolean" { content[name] = true }
            else if required.contains(name) { return nil }
        }
        if !required.isSubset(of: Set(content.keys)) { return nil }
        return content
    }

    private func attention() { if !(NSApp?.isActive ?? true) { NSApp.requestUserAttention(.criticalRequest) } }

    @discardableResult func presentQuestion(id: Any, params: JSON) -> Item {
        let item = add(.question, "Нужен твой ответ")
        item.rpcId = id; item.rpcKind = "question"; item.payload = params; item.questionClient = client
        attention()
        return item
    }

    func submitQuestion(_ item: Item) {
        guard item.kind == .question, item.decision == nil, let id = item.rpcId,
              let response = QuestionPayload.response(item.payload, answers: item.questionAnswers) else { return }
        guard let client = client, item.questionClient === client else { add(.error, "Нет связи с исходной сессией Codex. Ответ ещё не отправлен."); return }
        client.respond(id, result: response)
        item.decision = "answered"
        item.questionAnswers = [:]
    }

    func answer(_ it: Item, _ choice: String) {     // accept / acceptForSession / decline
        guard let id = it.rpcId, it.decision == nil else { return }
        it.decision = choice
        if it.rpcKind == "elicitation" {
            client?.respond(id, result: ["action": choice == "decline" ? "decline" : "accept", "content": choice == "decline" ? NSNull() : (Self.mcpConfirmationContent(it.payload) ?? [:]), "_meta": NSNull()])
            return
        }
        if it.rpcKind == "permissions" {
            if choice == "decline" { client?.respond(id, result: ["permissions": [String: Any](), "scope": "turn"]); return }
            var granted: JSON = [:]
            for k in ["network", "fileSystem"] where !(it.payload[k] is NSNull) && it.payload[k] != nil { granted[k] = it.payload[k] }
            client?.respond(id, result: ["permissions": granted, "scope": choice == "acceptForSession" ? "session" : "turn"])
            return
        }
        if it.legacy {
            let map: [String: Any] = ["accept": "approved", "acceptForSession": "approved_for_session",
                                      "decline": ["denied": ["rejection": "Отклонено пользователем"]]]
            client?.respond(id, result: ["decision": map[choice] ?? "abort"])
        } else {
            client?.respond(id, result: ["decision": choice])
        }
    }

    // MARK: Claude

    /// Экспорт диалога и открытие Claude Code с задачей разобраться.
    func askClaude() {
        let dir = appDataDir + "/handoff"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/codex-\(Int(Date().timeIntervalSince1970)).md"
        var md = "# Диалог Codex (\(account.name), \(model))\nРабочая папка: \(cwd)\n\n"
        for i in items {
            switch i.kind {
            case .user: md += "## Пользователь\n\(i.text)\n\n"
            case .agent: md += "## Codex\n\(i.text)\n\n"
            case .command: md += "### $ \(i.text)\n```\n\(String(i.output.suffix(1500)))\n```\nexit: \(i.exitCode.map(String.init) ?? "?")\n\n"
            case .file: md += "### Правка файлов: \(i.text)\n\n"
            case .error: md += "### Ошибка\n\(i.text)\n\n"
            case .note, .thinking, .approval, .question: md += "_\(i.text)_\n\n"
            }
        }
        try? md.write(toFile: file, atomically: true, encoding: .utf8)
        let prompt = "Новый диалог Codex: \(file) — он не справился с задачей. Прочитай, разберись, в чём на самом деле проблема, и реши её сам в этом проекте. Коротко объясни, что было не так."
        target = "claude"
        add(.note, "✳ Передал диалог Claude — дальше пишешь ему (переключатель у поля ввода).")
        sendClaude(prompt, echo: false)
    }

    /// Открыть тот же разговор с Claude в Terminal (полноценный Claude Code).
    func claudeInTerminal() {
        let sid = claudeSession()
        Terminal.run("cd \(shq(cwd)) && claude " + (sid.resume ? "--resume " : "--session-id ") + sid.id)
    }

    private func claudeSession() -> (id: String, resume: Bool) {
        let key = "claudeSession:" + cwd
        if let sid = UserDefaults.standard.string(forKey: key), claudeSessionExists(sid) { return (sid, true) }
        let sid = UUID().uuidString.lowercased()
        UserDefaults.standard.set(sid, forKey: key)
        return (sid, false)
    }

    /// Claude Code прямо в ленте: claude -p … --output-format stream-json, один разговор на проект.
    func sendClaude(_ text: String, echo: Bool = true) {
        var t = text
        let imgs = attachments; attachments = []
        if !imgs.isEmpty { t += "\n\nКартинки: " + imgs.joined(separator: ", ") }
        guard !t.isEmpty, claudeProc?.isRunning != true else { return }
        if echo { let u = add(.user, text.isEmpty ? "(картинка)" : text); u.claude = true; u.images = imgs }
        let sid = claudeSession()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudeBin)
        p.arguments = ["-p", t, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--permission-mode", "auto", sid.resume ? "--resume" : "--session-id", sid.id]
        if !claudeModel.isEmpty { p.arguments? += ["--model", claudeModel] }
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = homeDir + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env.merge(Proxy.shared.env) { _, n in n }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        var buf = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            buf.append(d)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl); buf.removeSubrange(buf.startIndex...nl)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? JSON { DispatchQueue.main.async { self?.claudeEvent(o) } }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.busy, proc.terminationStatus != 0 { self.add(.error, "Claude завершился с кодом \(proc.terminationStatus)") }
                self.busy = false; self.claudeText = nil; self.claudeProc = nil
                if proc.terminationStatus != 0 { self.queuePaused = true }
                self.loadThreads()
                self.drainQueue()
            }
        }
        busy = true; turnStarted = Date(); claudeText = nil
        do { try p.run(); claudeProc = p } catch { busy = false; add(.error, "Не удалось запустить claude") }
    }

    private func claudeEvent(_ o: JSON) {
        switch o["type"] as? String {
        case "stream_event":
            let ev = (o["event"] as? JSON) ?? [:]
            if ev["type"] as? String == "content_block_start", let b = ev["content_block"] as? JSON {
                if b["type"] as? String == "text" { let i = add(.agent, ""); i.claude = true; claudeText = i }
                if b["type"] as? String == "tool_use", let id = b["id"] as? String {
                    let i = add(.command, (b["name"] as? String) ?? "tool", id: id); i.claude = true; claudeItems[id] = i; claudeText = nil
                }
            }
            if ev["type"] as? String == "content_block_delta", let d = ev["delta"] as? JSON, d["type"] as? String == "text_delta" {
                if claudeText == nil { let i = add(.agent, ""); i.claude = true; claudeText = i }
                claudeText?.text += (d["text"] as? String) ?? ""
            }
        case "assistant":   // полные блоки: подставить аргументы инструментов
            for b in (((o["message"] as? JSON)?["content"]) as? [JSON]) ?? [] where b["type"] as? String == "tool_use" {
                guard let id = b["id"] as? String, let i = claudeItems[id] else { continue }
                let inp = (b["input"] as? JSON) ?? [:]
                let arg = (inp["command"] as? String) ?? (inp["file_path"] as? String) ?? (inp["pattern"] as? String) ?? (inp["url"] as? String) ?? ""
                i.text = ((b["name"] as? String) ?? "tool") + (arg.isEmpty ? "" : ": " + arg)
            }
        case "user":
            for b in (((o["message"] as? JSON)?["content"]) as? [JSON]) ?? [] where b["type"] as? String == "tool_result" {
                guard let id = b["tool_use_id"] as? String, let i = claudeItems[id] else { continue }
                let c = b["content"]
                let text = (c as? String) ?? ((c as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                i.output = String(text.suffix(6000)); i.exitCode = (b["is_error"] as? Bool == true) ? 1 : 0; i.done = true
            }
        case "result":
            if let usage = o["usage"] as? JSON {
                claudeInputTokens = (usage["input_tokens"] as? NSNumber)?.intValue
                claudeOutputTokens = (usage["output_tokens"] as? NSNumber)?.intValue
                claudeCachedTokens = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue
                claudeUsage = usage.keys.sorted().compactMap { key in (usage[key] as? NSNumber).map { "\(key): \($0)" } }.joined(separator: "\n")
            }
            busy = false; claudeText = nil
            defer { dumpAutotest() }
            if o["is_error"] as? Bool == true { queuePaused = true; add(.error, (o["result"] as? String) ?? "Claude: ошибка") }
        default: break
        }
    }

    /// Весь диалог текстом — для «Скопировать весь диалог».
    func transcript() -> String {
        items.compactMap { i -> String? in
            switch i.kind {
            case .user: return "> " + i.text
            case .agent: return (i.claude ? "✳ " : "") + i.text
            case .command: return "$ " + i.text + (i.output.isEmpty ? "" : "\n" + String(i.output.suffix(2000)))
            case .error: return "Ошибка: " + i.text
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    func resetClaude() { UserDefaults.standard.removeObject(forKey: "claudeSession:" + cwd) }
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// «/bin/zsh -lc 'ls x'» → «ls x»: показываем саму команду, как Claude Code.
func cleanCommand(_ c: String) -> String {
    for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where c.hasPrefix(prefix) {
        var rest = String(c.dropFirst(prefix.count))
        if rest.count >= 2, let f = rest.first, f == rest.last, f == "'" || f == "\"" { rest = String(rest.dropFirst().dropLast()) }
        return rest
    }
    return c
}

/// Есть ли уже такой разговор Claude Code (~/.claude/projects/*/<id>.jsonl).
func claudeSessionExists(_ id: String) -> Bool {
    let base = homeDir + "/.claude/projects"
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
    return dirs.contains { FileManager.default.fileExists(atPath: "\(base)/\($0)/\(id).jsonl") }
}

func dbg(_ s: String) {
    guard ProcessInfo.processInfo.environment["PULT_AUTOTEST"] != nil else { return }
    let line = "\(Date()) \(s)\n"
    let path = appDataDir + "/debug.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

/// Свежая копия диалога в папке нужного аккаунта: app-server ищет диалоги только у себя.
func localRollout(_ tid: String, in home: String, homes: [String]) -> String? {
    guard let src = findRollout(tid, in: homes) else { return nil }
    let fm = FileManager.default
    guard let r = src.range(of: "/sessions/") else { return src }
    let dst = home + "/sessions/" + src[r.upperBound...]
    if src == dst { return src }
    try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: dst)
    do { try fm.copyItem(atPath: src, toPath: dst) } catch { return nil }
    return dst
}

extension Chat {
    @discardableResult func handleSlash(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let command = parts.first.map(String.init)?.lowercased() ?? "help"
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let claude = target == "claude"
        let available = PultCommand.list(for: target)
        // Absolute paths can start a normal prompt; only known commands are intercepted.
        if !available.contains(where: { $0.name == command }) {
            if command.contains("/") { return false }
            add(.error, "Команда /\(command) пока не поддерживается в чате Пульта. /help — доступные команды.")
            return true
        }
        let needsIdle = ["compact", "model", "cd", "fork", "archive", "review", "init"]
        if busy && needsIdle.contains(command) {
            add(.note, "Сначала дождись ответа или прерви его через /stop.")
            return true
        }
        switch command {
        case "help":
            add(.note, available.map { "/\($0.name) — \($0.detail)" }.joined(separator: "\n"))
        case "new", "clear":
            if claude { resetClaude() }
            newChat()
        case "stop": interrupt()
        case "config", "permissions": showCommandSettings = true
        case "model":
            if argument.isEmpty { showCommandSettings = true }
            else {
                if claude { claudeModel = argument } else { model = argument }
                add(.note, "Модель: " + argument)
            }
        case "status", "context":
            add(.note, "Провайдер: \(claude ? "Claude Code" : "Codex")\nМодель: \(claude ? (claudeModel.isEmpty ? "по умолчанию CLI" : claudeModel) : model)\nПапка: \(cwd)\nСессия: \(claude ? (UserDefaults.standard.string(forKey: "claudeSession:" + cwd) ?? "новая") : (threadId ?? "новая"))\nСостояние: \(busy ? "работает" : "готов")")
        case "cost": add(.note, claudeUsage)
        case "usage":
            if claude { add(.note, "Последний ход:\n" + claudeUsage + "\nКвоты подписки Claude недоступны через режим print.") }
            else { slashRPC("account/rateLimits/read") }
        case "copy":
            if let item = items.last(where: { $0.kind == .agent && !$0.text.isEmpty }) { copyText(item.text); add(.note, "Ответ скопирован.") }
            else { add(.note, "Пока нет ответа для копирования.") }
        case "export":
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Диалог.md"
            if panel.runModal() == .OK, let url = panel.url {
                do { try transcript().write(to: url, atomically: true, encoding: .utf8); add(.note, "Диалог сохранён.") }
                catch { add(.error, error.localizedDescription) }
            }
        case "pwd": add(.note, cwd)
        case "cd":
            if argument.isEmpty { add(.note, "Рабочая папка: \(cwd)\nИспользование: /cd путь") }
            else {
                let expanded = (argument as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    cwd = url.path; newChat(); add(.note, "Рабочая папка: " + cwd)
                } else { add(.error, "Папка не найдена: " + url.path) }
            }
        case "resume":
            showSidebar = true; loadThreads()
            if !argument.isEmpty {
                if let thread = threads.first(where: { $0.id == argument }) { open(thread) }
                else { add(.note, "Диалог не найден в списке. Выбери его слева или обнови список.") }
            } else { add(.note, "Выбери разговор в списке слева.") }
        case "compact":
            if claude { sendClaude(text) }
            else if let tid = threadId { slashRPC("thread/compact/start", ["threadId": tid], success: "Сжатие контекста запущено.") }
            else { add(.note, "Пока нет контекста для сжатия.") }
        case "diff": runInlineCLI("/usr/bin/git", ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"])
        case "init":
            let prompt = "Изучи этот проект и создай или актуализируй \(claude ? "CLAUDE.md" : "AGENTS.md") с краткими инструкциями по разработке, сборке и проверке."
            if claude { sendClaude(prompt) } else { send(prompt) }
        case "skills":
            if claude { listClaudeFiles("skills") } else { slashRPC("skills/list", ["cwds": [cwd]]) }
        case "mcp":
            if claude { runInlineCLI(claudeBin, ["mcp", "list"]) }
            else { slashRPC("mcpServerStatus/list", ["limit": 100]) }
        case "plugins", "plugin":
            if claude { runInlineCLI(claudeBin, ["plugin", "list"]) }
            else { slashRPC("plugin/list", ["cwds": [cwd]]) }
        case "apps": slashRPC("apps/list", ["limit": 100])
        case "agents": listClaudeFiles("agents")
        case "memory":
            let url = URL(fileURLWithPath: cwd).appendingPathComponent("CLAUDE.md")
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            else { add(.note, "В проекте нет CLAUDE.md. /init — создать инструкции.") }
        case "doctor", "version":
            runInlineCLI(claude ? claudeBin : codexBin, [command == "version" ? "--version" : "doctor"])
        case "rename":
            guard let tid = threadId else { add(.note, "Сначала начни разговор."); return true }
            if argument.isEmpty { add(.note, "Использование: /rename новое название") }
            else { slashRPC("thread/name/set", ["threadId": tid, "name": argument], success: "Разговор переименован.") }
        case "archive":
            if let tid = threadId {
                client?.call("thread/archive", ["threadId": tid]) { [weak self] response in
                    guard let self = self else { return }
                    if let error = response["error"] as? JSON { self.add(.error, error["message"] as? String ?? "Ошибка архивации") }
                    else { self.newChat(); self.add(.note, "Разговор архивирован.") }
                }
            } else { add(.note, "Пока нет разговора для архивации.") }
        case "unarchive":
            if argument.isEmpty { add(.note, "Использование: /unarchive ID") }
            else { slashRPC("thread/unarchive", ["threadId": argument], success: "Разговор восстановлен."); loadThreads() }
        case "fork":
            guard let tid = threadId else { add(.note, "Сначала начни разговор."); return true }
            client?.call("thread/fork", ["threadId": tid, "cwd": cwd, "model": model]) { [weak self] response in
                guard let self = self else { return }
                if let thread = (response["result"] as? JSON)?["thread"] as? JSON, let id = thread["id"] as? String {
                    self.threadId = id; self.threadLoaded = true; self.add(.note, "Создана ветка разговора."); self.loadThreads()
                } else { self.add(.error, (response["error"] as? JSON)?["message"] as? String ?? "Не удалось создать ветку") }
            }
        case "review":
            withThread { [weak self] tid in
                guard let self = self, let tid = tid else { return }
                let reviewTarget: JSON = argument.isEmpty ? ["type": "uncommittedChanges"] : ["type": "custom", "instructions": argument]
                self.busy = true; self.turnStarted = Date()
                self.client?.call("review/start", ["threadId": tid, "target": reviewTarget, "delivery": "inline"]) { response in
                    if let error = response["error"] as? JSON { self.busy = false; self.add(.error, error["message"] as? String ?? "Не удалось запустить review") }
                }
            }
        default: add(.note, "Эта команда недоступна через API текущего провайдера.")
        }
        return true
    }

    private func slashRPC(_ method: String, _ params: JSON = [:], success: String? = nil) {
        guard let client = client else { add(.error, "Codex ещё не подключён."); return }
        client.call(method, params) { [weak self] response in
            guard let self = self else { return }
            if let error = response["error"] as? JSON { self.add(.error, error["message"] as? String ?? "Команда завершилась ошибкой") }
            else if let message = success { self.add(.note, message) }
            else if let value = response["result"], let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) {
                self.add(.note, String(text.prefix(20000)))
            }
        }
    }

    private func listClaudeFiles(_ folder: String) {
        var entries: [String] = []
        for base in [homeDir + "/.claude/", cwd + "/.claude/"] {
            let root = base + folder
            for file in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !file.hasPrefix(".") { entries.append(root + "/" + file) }
        }
        add(.note, entries.isEmpty ? "Нет локальных \(folder) в ~/.claude и .claude проекта." : entries.sorted().joined(separator: "\n"))
    }

    private func runInlineCLI(_ executable: String, _ arguments: [String]) {
        let item = add(.command, ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "))
        let directory = cwd, accountHome = account.home
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = accountHome
        environment["PATH"] = homeDir + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment.merge(Proxy.shared.env) { _, new in new }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory); process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let text = String(decoding: data.suffix(20000), as: UTF8.self)
                DispatchQueue.main.async { item.output = text.isEmpty ? "Готово." : text; item.exitCode = Int(process.terminationStatus); item.done = true }
            } catch {
                DispatchQueue.main.async { item.output = error.localizedDescription; item.exitCode = 1; item.done = true }
            }
        }
    }
}
