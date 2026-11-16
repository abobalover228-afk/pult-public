// Управление Пультом из Telegram через своего бота: статусы чатов, новые задачи, ответы на вопросы, разрешения.
// Токен хранится в .env. Бот слушает только владельца, привязанного кодом из настроек.
import AppKit
import Foundation

enum Secrets {
    private static var file: URL {
        let source = Bundle.main.object(forInfoDictionaryKey: "PultSource") as? String
        return URL(fileURLWithPath: (source ?? appDataDir) + "/.env")
    }
    private static func key(_ name: String) -> String {
        name == "telegram-bot-token" ? "TELEGRAM_BOT_TOKEN" : name
    }
    static func read(_ name: String) -> String? {
        let prefix = key(name) + "="
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value
    }
    @discardableResult static func write(_ name: String, _ value: String?) -> Bool {
        let prefix = key(name) + "="
        guard key(name).range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var lines = old.components(separatedBy: .newlines).filter { !$0.hasPrefix(prefix) && !$0.isEmpty }
            if let value = value, !value.isEmpty {
                let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                lines.append(prefix + encoded)
            }
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }
}

final class TelegramBridge: ObservableObject {
    static let shared = TelegramBridge()
    @Published var status = "не подключён"
    @Published var botName = ""
    @Published var pairCode = ""
    @Published var owner: Int64 = (UserDefaults.standard.object(forKey: "tgOwner") as? NSNumber)?.int64Value ?? 0
    @Published var notifyAlways = UserDefaults.standard.bool(forKey: "tgNotifyAlways") { didSet { UserDefaults.standard.set(notifyAlways, forKey: "tgNotifyAlways") } }
    private var token = ""
    private var offset = 0
    private var generation = UUID()
    private var session = URLSession(configuration: .ephemeral)
    private var selected: UUID?                 // чат, в который идут сообщения из Telegram
    private var failures = 0

    var configured: Bool { !token.isEmpty }
    var paired: Bool { owner != 0 }
    private var workspace: Workspace { Workspace.shared }

    func start() {
        token = Secrets.read("telegram-bot-token") ?? ""
        restart()
    }

    func setToken(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Secrets.write("telegram-bot-token", clean) else { status = "Не удалось сохранить токен в .env"; return }
        offset = 0; selected = nil
        token = clean
        owner = 0; UserDefaults.standard.removeObject(forKey: "tgOwner")
        restart()
    }

    func unpair() { owner = 0; UserDefaults.standard.removeObject(forKey: "tgOwner"); restart() }

    /// Сеть изменилась (VLESS) или новый токен: пересобрать соединение и начать слушать заново.
    func restart() {
        generation = UUID(); failures = 0
        session.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 75
        if !Proxy.shared.env.isEmpty {
            config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Proxy.shared.port,
                                                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Proxy.shared.port]
        }
        session = URLSession(configuration: config)
        guard configured else { status = "не подключён"; botName = ""; return }
        status = "подключаюсь…"
        let run = generation
        api("getMe", [:]) { [weak self] r in
            guard let self = self, self.generation == run else { return }
            guard let me = r?["result"] as? JSON, let name = me["username"] as? String else {
                self.status = "токен не подошёл или нет сети"; return
            }
            self.botName = name
            if !self.paired { self.pairCode = String(format: "%06d", Int.random(in: 0...999_999)) }
            self.status = self.paired ? "работает · @\(name)" : "жду код привязки · @\(name)"
            self.api("setMyCommands", ["commands": [
                ["command": "chats", "description": "Чаты и их статусы"],
                ["command": "new", "description": "Новый чат: /new задача"],
                ["command": "status", "description": "Что сейчас происходит"],
                ["command": "last", "description": "Последний ответ"],
                ["command": "stop", "description": "Остановить текущий чат"],
                ["command": "help", "description": "Как этим пользоваться"]]]) { _ in }
            self.poll(run)
        }
    }

    // MARK: транспорт

    private func api(_ method: String, _ body: JSON, _ done: @escaping (JSON?) -> Void) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { done(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSON }
            DispatchQueue.main.async { done(json?["ok"] as? Bool == true ? json : nil) }
        }.resume()
    }

    private func poll(_ run: UUID) {
        guard generation == run else { return }
        api("getUpdates", ["timeout": 50, "offset": offset, "allowed_updates": ["message", "callback_query"]]) { [weak self] r in
            guard let self = self, self.generation == run else { return }
            guard let updates = r?["result"] as? [JSON] else {
                self.failures += 1
                if self.failures == 3 { self.status = "нет связи с Telegram — пробую снова" }
                DispatchQueue.main.asyncAfter(deadline: .now() + min(30, Double(self.failures) * 3)) { self.poll(run) }
                return
            }
            if self.failures >= 3 { self.status = self.paired ? "работает · @\(self.botName)" : "жду код привязки · @\(self.botName)" }
            self.failures = 0
            for update in updates {
                if let id = (update["update_id"] as? NSNumber)?.intValue { self.offset = max(self.offset, id + 1) }
                self.handle(update)
            }
            self.poll(run)
        }
    }

    func send(_ text: String, buttons: [[(String, String)]] = [], to chatID: Int64? = nil) {
        guard configured, let target = chatID ?? (paired ? owner : nil) else { return }
        let chunks = Self.split(text.isEmpty ? "…" : text)
        for (index, chunk) in chunks.enumerated() {
            var body: JSON = ["chat_id": target, "text": chunk, "disable_web_page_preview": true]
            if index == chunks.count - 1, !buttons.isEmpty {
                body["reply_markup"] = ["inline_keyboard": buttons.map { row in row.map { ["text": $0.0, "callback_data": $0.1] } }]
            }
            api("sendMessage", body) { _ in }
        }
    }

    static func split(_ text: String, limit: Int = 3800, maxParts: Int = 3) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty, parts.count < maxParts {
            if rest.count <= limit { parts.append(String(rest)); rest = ""; break }
            let head = rest.prefix(limit)
            let cut = head.lastIndex(of: "\n").map { rest.distance(from: rest.startIndex, to: $0) }.flatMap { $0 > limit / 2 ? $0 : nil } ?? limit
            parts.append(String(rest.prefix(cut)))
            rest = rest.dropFirst(cut)
        }
        if !rest.isEmpty, let last = parts.popLast() { parts.append(last + "\n… (дальше — в Пульте)") }
        return parts
    }

    // MARK: входящие

    private func handle(_ update: JSON) {
        if let query = update["callback_query"] as? JSON {
            let from = ((query["from"] as? JSON)?["id"] as? NSNumber)?.int64Value ?? 0
            let id = (query["id"] as? String) ?? ""
            guard paired, from == owner else { api("answerCallbackQuery", ["callback_query_id": id]) { _ in }; return }
            let note = callback((query["data"] as? String) ?? "")
            api("answerCallbackQuery", ["callback_query_id": id, "text": note]) { _ in }
            return
        }
        guard let message = update["message"] as? JSON, let chat = message["chat"] as? JSON,
              let chatID = (chat["id"] as? NSNumber)?.int64Value, chat["type"] as? String == "private" else { return }
        let text = ((message["text"] as? String) ?? (message["caption"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !paired {
            if !pairCode.isEmpty, text.replacingOccurrences(of: "/start", with: "").trimmingCharacters(in: .whitespaces) == pairCode {
                owner = chatID; UserDefaults.standard.set(NSNumber(value: chatID), forKey: "tgOwner"); pairCode = ""
                status = "работает · @\(botName)"
                send("✅ Пульт привязан. Пиши задачу — она уйдёт в текущий чат. /help — что ещё можно.")
                Workspace.shared.say("Telegram привязан")
            } else { send("Этот бот управляет Пультом. Пришли код привязки из настроек Пульта (Настройки → Telegram).", to: chatID) }
            return
        }
        guard chatID == owner else { return }
        if let photos = message["photo"] as? [JSON], let file = photos.last?["file_id"] as? String {
            download(file, name: "tg-\(UUID().uuidString.prefix(8)).jpg") { [weak self] path in self?.incoming(text, attachment: path) }
            return
        }
        if let document = message["document"] as? JSON, let file = document["file_id"] as? String {
            let name = (document["file_name"] as? String) ?? "file"
            download(file, name: "tg-\(UUID().uuidString.prefix(6))-" + name.replacingOccurrences(of: "/", with: "_")) { [weak self] path in self?.incoming(text, attachment: path) }
            return
        }
        incoming(text, attachment: nil)
    }

    private func download(_ fileID: String, name: String, _ done: @escaping (String?) -> Void) {
        api("getFile", ["file_id": fileID]) { [weak self] r in
            guard let self = self, let path = (r?["result"] as? JSON)?["file_path"] as? String,
                  let url = URL(string: "https://api.telegram.org/file/bot\(self.token)/\(path)") else { done(nil); return }
            self.session.dataTask(with: url) { data, _, _ in
                var saved: String?
                if let data = data, data.count <= 20 * 1024 * 1024 {
                    try? FileManager.default.createDirectory(atPath: attachDir, withIntermediateDirectories: true)
                    let target = attachDir + "/" + name
                    if (try? data.write(to: URL(fileURLWithPath: target))) != nil { saved = target }
                }
                DispatchQueue.main.async { done(saved) }
            }.resume()
        }
    }

    private var current: Chat {
        if let id = selected, let chat = workspace.chats.first(where: { $0.sessionID == id }) { return chat }
        return workspace.active
    }

    private func incoming(_ text: String, attachment: String?) {
        if text.hasPrefix("/"), attachment == nil, command(text) { return }
        let chat = current
        if attachment == nil, let question = chat.items.last(where: { $0.kind == .question && $0.decision == nil }) {
            answerText(chat, question, text); return
        }
        guard !text.isEmpty || attachment != nil else { return }
        deliver(text, attachment: attachment, to: chat)
    }

    private func deliver(_ text: String, attachment: String?, to chat: Chat) {
        let queued = chat.busy || chat.nativeCLIIsRunning
        if let path = attachment { chat.attachments.append(path) }
        chat.telegramBound = true
        chat.send(text)
        send((queued ? "🕓 В очередь · " : "➡️ ") + chat.title + " · " + chat.providerLabel)
    }

    private func command(_ text: String) -> Bool {
        let parts = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let name = String(parts[0].dropFirst()).split(separator: "@").first.map { $0.lowercased() } ?? ""
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch name {
        case "start", "help":
            send("""
            Пульт на связи.
            • Просто текст — задача в выбранный чат (если он занят — встанет в очередь).
            • Фото или файл — прикрепится к сообщению.
            • /chats — чаты и статусы, выбор чата кнопкой.
            • /new задача — новый чат.
            • /status — что сейчас происходит и лимиты.
            • /last — последний ответ выбранного чата.
            • /stop — остановить выбранный чат.
            Когда агенту нужно разрешение или ответ на вопрос — пришлю кнопки.
            """)
        case "chats": sendChats()
        case "status":
            let lines = workspace.chats.map { "\($0.status.emoji) \($0.title) — \($0.status.label.lowercased()) · \($0.providerLabel)" }
            let chat = workspace.active
            let limits = chat.accounts.map { "\($0.name): " + (chat.remaining($0).map { "\(Int($0))%" } ?? "?") }.joined(separator: " · ")
            send(lines.joined(separator: "\n") + "\n\nОсталось лимитов: " + limits)
        case "last":
            let chat = current
            send("💬 \(chat.title)\n\n" + (chat.lastAnswer.isEmpty ? "Ответа пока нет." : chat.lastAnswer))
        case "stop":
            let chat = current
            if chat.busy || chat.nativeCLIIsRunning { chat.interrupt(); send("⏹ Останавливаю · " + chat.title) } else { send("Сейчас ничего не выполняется.") }
        case "new":
            let chat = workspace.newChat(select: false)
            selected = chat.sessionID
            if argument.isEmpty { send("🆕 Новый чат выбран. Пиши задачу.") } else { deliver(argument, attachment: nil, to: chat) }
        default:
            return false                                   // остальные /команды уходят в чат как есть
        }
        return true
    }

    private func sendChats() {
        let chats = workspace.chats
        let lines = chats.enumerated().map { i, c in "\(i + 1). \(c.status.emoji) \(c.title) — \(c.status.label.lowercased())" + (c.sessionID == current.sessionID ? "  ← сюда пишешь" : "") }
        let buttons = chats.enumerated().map { i, c in [("\(i + 1). " + String(c.title.prefix(28)), "sel:" + c.sessionID.uuidString)] }
        send("Чаты:\n" + lines.joined(separator: "\n"), buttons: buttons + [[("🆕 Новый чат", "new:")]])
    }

    private func find(_ itemID: String) -> (Chat, Item)? {
        for chat in workspace.chats { if let item = chat.items.last(where: { $0.id == itemID }) { return (chat, item) } }
        return nil
    }

    /// Короткие ключи для кнопок: callback_data ограничен 64 байтами, а id элементов бывают длинными.
    private var keys: [String: String] = [:]
    private func key(_ itemID: String) -> String {
        if let existing = keys.first(where: { $0.value == itemID })?.key { return existing }
        let k = String(UUID().uuidString.prefix(8)); keys[k] = itemID
        return k
    }

    private func callback(_ data: String) -> String {
        let parts = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "sel":
            guard parts.count > 1, let chat = workspace.chats.first(where: { $0.sessionID.uuidString == parts[1] }) else { return "Чат уже закрыт" }
            selected = chat.sessionID
            send("✏️ Теперь пишешь в «\(chat.title)» · \(chat.status.label.lowercased())")
            return "Выбран"
        case "new":
            let chat = workspace.newChat(select: false); selected = chat.sessionID
            send("🆕 Новый чат выбран. Пиши задачу.")
            return "Создан"
        case "ap":
            guard parts.count > 2, let id = keys[parts[1]], let (chat, item) = find(id), item.decision == nil else { return "Уже неактуально" }
            let choice = parts[2] == "y" ? "accept" : parts[2] == "s" ? "acceptForSession" : "decline"
            chat.answer(item, choice)
            return item.decision == "expired" ? "Запрос устарел" : choice == "decline" ? "Отклонено" : "Разрешено"
        case "q":
            guard parts.count > 3, let id = keys[parts[1]], let (chat, item) = find(id), item.decision == nil,
                  let qi = Int(parts[2]), let oi = Int(parts[3]) else { return "Уже неактуально" }
            let questions = (item.payload["questions"] as? [JSON]) ?? []
            guard questions.indices.contains(qi), let qid = questions[qi]["id"] as? String,
                  let options = questions[qi]["options"] as? [JSON], options.indices.contains(oi), let label = options[oi]["label"] as? String else { return "?" }
            item.questionAnswers[qid] = label
            finishQuestion(chat, item)
            return label
        default: return ""
        }
    }

    private func answerText(_ chat: Chat, _ item: Item, _ text: String) {
        let questions = (item.payload["questions"] as? [JSON]) ?? []
        guard let open = questions.first(where: { q in (q["id"] as? String).map { (item.questionAnswers[$0] ?? "").isEmpty } ?? false }),
              let qid = open["id"] as? String else { return }
        item.questionAnswers[qid] = text
        finishQuestion(chat, item)
    }

    private func finishQuestion(_ chat: Chat, _ item: Item) {
        let questions = (item.payload["questions"] as? [JSON]) ?? []
        let left = questions.filter { q in (q["id"] as? String).map { (item.questionAnswers[$0] ?? "").isEmpty } ?? false }
        if left.isEmpty { chat.submitQuestion(item); send(item.decision == "answered" ? "✅ Ответ отправлен · " + chat.title : "Вопрос уже неактуален.") }
        else { send("Принял. Осталось вопросов: \(left.count).") }
    }

    // MARK: исходящие

    func wants(_ chat: Chat) -> Bool { configured && paired && chat.telegramBound }

    func finished(_ chat: Chat, took: TimeInterval, failed: Bool) {
        let bound = chat.telegramBound
        let head = (failed ? "❌ Ошибка" : "✅ Готово") + " · \(chat.title) · \(chat.providerLabel)" + (took >= 60 ? " · \(Int(took / 60)) мин" : "")
        var body = chat.lastAnswer
        if failed, let error = chat.items.last(where: { $0.kind == .error })?.text { body = error }
        if configured && paired {
            guard bound || notifyAlways || took > 60 else { return }
            send(head + "\n\n" + body, buttons: workspace.chats.count > 1 ? [[("Писать в этот чат", "sel:" + chat.sessionID.uuidString)]] : [])
        } else if chat.notifyTelegram, took > 60 {             // прежний способ — общий бот на сервере
            Remote.run("python3 /usr/local/lib/coder-chat/notify_owner.py", stdin: htmlEscape(head + "\n\n" + String(body.prefix(600)))) { _ in }
        }
    }

    func approval(_ chat: Chat, _ item: Item, urgent: Bool) {
        guard configured, paired, urgent || chat.telegramBound else { return }
        let k = key(item.id)
        send("🔐 Нужно разрешение · \(chat.title)\n\n" + String(item.text.prefix(1500)),
             buttons: [[("✅ Да", "ap:\(k):y"), ("✅ До конца сессии", "ap:\(k):s")], [("❌ Нет", "ap:\(k):n")]])
    }

    func question(_ chat: Chat, _ item: Item, urgent: Bool) {
        guard configured, paired, urgent || chat.telegramBound else { return }
        let k = key(item.id)
        let questions = (item.payload["questions"] as? [JSON]) ?? []
        selected = chat.sessionID
        for (qi, question) in questions.enumerated() {
            let options = (question["options"] as? [JSON]) ?? []
            let lines = options.compactMap { o -> String? in
                guard let label = o["label"] as? String else { return nil }
                return "• " + label + ((o["description"] as? String).map { $0.isEmpty ? "" : " — " + $0 } ?? "")
            }
            let buttons = options.enumerated().compactMap { oi, o -> [(String, String)]? in
                (o["label"] as? String).map { [(String($0.prefix(40)), "q:\(k):\(qi):\(oi)")] }
            }
            send("❓ \(chat.title)\n\n" + ((question["question"] as? String) ?? "Вопрос") + (lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")) + "\n\nВыбери кнопкой или ответь текстом.",
                 buttons: buttons)
        }
    }
}
