// Несколько чатов одновременно: у каждого свой Codex/Claude, свой статус и своя очередь.
import AppKit
import SwiftUI
import Combine

enum ChatStatus {
    case idle, connecting, working, question, approval, error, unread

    var label: String {
        switch self {
        case .idle: return "Готов"
        case .connecting: return "Подключаю…"
        case .working: return "Работает"
        case .question: return "Ждёт твоего ответа"
        case .approval: return "Ждёт разрешения"
        case .error: return "Ошибка"
        case .unread: return "Готово — не прочитано"
        }
    }
    var color: Color {
        switch self {
        case .idle: return Color.white.opacity(0.25)
        case .connecting: return .yellow
        case .working: return Color(red: 0.35, green: 0.85, blue: 0.5)
        case .question, .approval: return accent
        case .error: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case .unread: return Color(red: 0.4, green: 0.65, blue: 1.0)
        }
    }
    var emoji: String {
        switch self {
        case .idle: return "⚪️"
        case .connecting: return "🟡"
        case .working: return "🟢"
        case .question: return "❓"
        case .approval: return "🔐"
        case .error: return "🔴"
        case .unread: return "🔵"
        }
    }
    /// Требует внимания человека.
    var needsYou: Bool { self == .question || self == .approval }
}

enum ChatEvent {
    case finished(took: TimeInterval, failed: Bool)
    case needsApproval(Item)
    case needsAnswer(Item)
}

extension Chat {
    var status: ChatStatus {
        if items.contains(where: { $0.kind == .question && $0.decision == nil }) { return .question }
        if items.contains(where: { $0.kind == .approval && $0.decision == nil && !$0.autoApproved }) { return .approval }
        if busy || nativeCLIIsRunning { return .working }
        if connecting && target == "codex" { return .connecting }
        if lastError { return .error }
        if unread { return .unread }
        return .idle
    }
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        let first = items.first { $0.kind == .user }?.text ?? ""
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Новый чат" : String(line.prefix(60))
    }
    var providerLabel: String { isAPI ? (selectedAPI?.name ?? "API") : target == "claude" ? "Claude" : account.name }
    var isEmptyDraft: Bool { items.isEmpty && ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && !busy && !nativeCLIIsRunning && pendingMessages.isEmpty }
}

/// Лимиты аккаунтов — одни на все чаты; обновляются не чаще раза в две минуты.
final class LimitsStore: ObservableObject {
    static let shared = LimitsStore()
    @Published var limits: [String: Limits] = [:]
    private var lastRefresh = Date.distantPast
    private var running = false
    private var waiters: [() -> Void] = []

    func store(_ home: String, _ rl: JSON) {
        var l = Limits()
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? JSON, let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let mins = (w["windowDurationMins"] as? NSNumber)?.doubleValue ?? 0
            let reset = (w["resetsAt"] as? NSNumber)?.doubleValue
            if mins <= 300 { l.five = used; l.fiveReset = reset } else { l.week = used; l.weekReset = reset }
        }
        limits[home] = l
    }

    /// Лимит кончился прямо сейчас: не ждём обновления, чтобы авто-переключение не вернулось сюда же.
    func markExhausted(_ home: String) {
        var l = limits[home] ?? Limits()
        l.five = 100
        limits[home] = l
    }

    func refresh(accounts: [Account], skipping: String?, force: Bool = false, done: (() -> Void)? = nil) {
        if let done = done { waiters.append(done) }
        if running { return }
        let targets = accounts.filter { $0.home != skipping }
        if targets.isEmpty || (!force && Date().timeIntervalSince(lastRefresh) < 120) { finish(); return }
        running = true; lastRefresh = Date()
        var left = targets.count
        var closed = false
        let one: () -> Void = { [weak self] in
            left -= 1
            if left <= 0, !closed { closed = true; self?.finish() }
        }
        for a in targets {
            let c = CodexClient(home: a.home)
            var reported = false
            let report: () -> Void = { if !reported { reported = true; c.onExit = {}; c.stop(); one() } }
            c.onExit = report
            c.start { [weak self] ok in
                guard ok else { report(); return }
                c.call("account/rateLimits/read", [:]) { r in
                    if let rl = ((r["result"] as? JSON)?["rateLimits"]) as? JSON { self?.store(a.home, rl) }
                    else if (r["error"] as? JSON)?["pultDead"] == nil { self?.limits[a.home] = Limits(five: 100, week: 100) }   // нет входа → считаем пустым
                    report()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { report() }      // завис — не держим остальных
        }
    }

    private func finish() {
        running = false
        let callbacks = waiters; waiters = []
        callbacks.forEach { $0() }
    }
}

final class Workspace: ObservableObject {
    static let shared = Workspace()
    @Published var chats: [Chat] = []
    @Published var activeID = UUID()
    @Published var toast: String?
    @Published var showGuide = false
    @Published var showPalette = false
    @Published var search = ""
    @Published var sidebar = UserDefaults.standard.object(forKey: "sidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebar, forKey: "sidebar") }
    }
    private var links: [UUID: AnyCancellable] = [:]
    private var toastToken = UUID()

    var active: Chat { chats.first { $0.sessionID == activeID } ?? chats[0] }
    /// Сколько чатов ждут человека — для значка в Dock.
    var waiting: Int { chats.filter { $0.status.needsYou }.count }

    init() {
        let first = Chat()
        attach(first)
        chats = [first]; activeID = first.sessionID
    }

    private func attach(_ chat: Chat) {
        links[chat.sessionID] = chat.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.chatChanged() }
        }
        chat.onEvent = { [weak self] chat, event in self?.handle(chat, event) }
    }

    private var lastBadge = -1
    private var lastSignature = ""
    private func chatChanged() {
        let signature = chats.map { "\($0.sessionID.uuidString.prefix(4))\($0.status)\($0.title.prefix(20))" }.joined()
        if signature != lastSignature { lastSignature = signature; objectWillChange.send() }
        let count = waiting
        if count != lastBadge { lastBadge = count; NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil }
    }

    // MARK: вкладки

    @discardableResult func newChat(select: Bool = true, inherit: Bool = true) -> Chat {
        if let empty = chats.first(where: { $0.isEmptyDraft }) {      // пустой уже есть — не плодим
            if select { activate(empty) }
            return empty
        }
        let source = active
        let chat = Chat(primary: false)
        if inherit {
            chat.cwd = source.cwd
            if source.target != chat.target { chat.target = source.target }
            chat.model = source.model; chat.claudeModel = source.claudeModel; chat.sandbox = source.sandbox
        }
        attach(chat)
        chats.append(chat)
        if select { activate(chat) }
        return chat
    }

    func activate(_ chat: Chat) {
        if activeID != chat.sessionID { Voice.shared.stop() }
        activeID = chat.sessionID
        if chat.unread { chat.unread = false }
        if chat.lastError { chat.lastError = false }
    }

    func activate(index: Int) { if chats.indices.contains(index) { activate(chats[index]) } }

    func cycle(_ step: Int) {
        guard let i = chats.firstIndex(where: { $0.sessionID == activeID }), chats.count > 1 else { return }
        activate(chats[(i + step + chats.count) % chats.count])
    }

    func close(_ chat: Chat) {
        if chat.busy || chat.nativeCLIIsRunning { chat.interrupt() }
        chat.shutdown()
        links[chat.sessionID] = nil
        guard chats.count > 1 else { chat.newChat(); return }
        let index = chats.firstIndex { $0 === chat } ?? 0
        chats.removeAll { $0 === chat }
        if activeID == chat.sessionID { activate(chats[min(index, chats.count - 1)]) }
    }

    /// Диалог из истории: уже открыт — переключаемся; текущий чат пуст — открываем в нём; иначе в новой вкладке.
    func open(_ thread: ThreadInfo) {
        if let existing = chats.first(where: { $0.conversationKey == thread.id }) { activate(existing); return }
        let target = active.isEmptyDraft ? active : newChat(inherit: false)
        target.open(thread)
    }

    func say(_ text: String) {
        toast = text
        let token = UUID(); toastToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in if self?.toastToken == token { self?.toast = nil } }
    }

    // MARK: события чатов → уведомления

    private func handle(_ chat: Chat, _ event: ChatEvent) {
        let appActive = NSApp?.isActive ?? true
        let visible = appActive && chat.sessionID == activeID
        switch event {
        case .finished(let took, let failed):
            if !visible { if failed { chat.lastError = true } else { chat.unread = true } }
            if !failed, chat.sessionID == activeID { Voice.shared.speak(chat.lastAnswer, for: chat) }
            let fromTelegram = TelegramBridge.shared.wants(chat)
            guard fromTelegram || (!visible && took > 20) else { return }
            let head = (failed ? "❌ Ошибка" : "✅ Готово") + " · " + chat.title
            if !appActive || fromTelegram { TelegramBridge.shared.finished(chat, took: took, failed: failed) }
            if !visible { notifyMac(head, String((chat.lastAnswer).prefix(180))) }
        case .needsApproval(let item):
            if !visible { notifyMac("🔐 Нужно разрешение · " + chat.title, String(item.text.prefix(180))); NSApp?.requestUserAttention(.criticalRequest) }
            TelegramBridge.shared.approval(chat, item, urgent: !appActive)
        case .needsAnswer(let item):
            if !visible { notifyMac("❓ Нужен ответ · " + chat.title, String(item.text.prefix(180))); NSApp?.requestUserAttention(.criticalRequest) }
            TelegramBridge.shared.question(chat, item, urgent: !appActive)
        }
    }

    /// VLESS включили/выключили: свободные чаты Codex переподключаются с новыми настройками сети.
    func networkChanged() {
        for chat in chats where chat.target == "codex" && !chat.busy && !chat.connecting { chat.reconnect() }
    }

    var anyBusy: Bool { chats.contains { $0.busy || $0.nativeCLIIsRunning } }
}
