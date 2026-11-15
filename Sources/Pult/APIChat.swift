import Foundation

extension Chat {
    var isAPI: Bool { target.hasPrefix("api:") }
    var selectedAPI: APIConnection? { apiConnectionStore.connection(target: target) }
    var connectionTitle: String { isAPI ? (selectedAPI?.name ?? "API-подключение удалено") : target == "claude" ? "Claude CLI" : account.name }
    func chooseAPI(_ connection: APIConnection) {
        guard !busy, !nativeCLIIsRunning else { return }
        if target != connection.target { apiConversationID = nil }
        apiGeneration = UUID(); target = connection.target
        codexInputTokens = nil; codexOutputTokens = nil; codexCachedTokens = nil
        connecting = false
    }
    func chooseCodex(_ index: Int) {
        guard !busy, !nativeCLIIsRunning else { return }
        target = "codex"; switchTo(index)
    }
    func apiConfigurationDidChange() {
        guard isAPI else { return }
        if busy { interrupt() }
        queuePaused = true; queueContext = UUID(); apiConversationID = nil
    }
    func sendAPI(_ text: String, echo: Bool) {
        guard let connection = selectedAPI else { if echo { add(.user, text).images = attachments }; add(.error, "API-подключение не найдено. Выбери другое или добавь его в меню аккаунтов."); return }
        let images = attachments
        var didEcho = false
        do {
            guard let key = try apiConnectionStore.vault.read(connection.id), !key.isEmpty else { throw APIProblem(message: "Ключ API отсутствует в Keychain. Измени подключение и сохрани ключ.") }
            var messages = APIStoredMessage.capture(items)
            messages.append(APIStoredMessage(role: "user", text: text, images: images))
            var wire = try messages.map { try $0.wire() }
            if !effectiveRules.isEmpty { wire.insert(["role":"system","content":effectiveRules],at:0) }
            let transport = makeAPIClient()
            if echo { add(.user, text.isEmpty ? "(картинка)" : text).images = images; didEcho = true }
            attachments = []; busy = true; turnStarted = Date()
            let token = UUID(); apiGeneration = token
            apiClient = transport
            let context = queueContext
            transport.send(connection: connection, key: key, messages: wire) { [weak self] result in
                guard let self, self.apiGeneration == token, self.queueContext == context, self.target == connection.target else { return }
                self.busy = false; self.apiClient = nil
                switch result {
                case .success(let response):
                    self.add(.agent, response.text)
                    self.codexInputTokens = response.inputTokens; self.codexOutputTokens = response.outputTokens; self.codexCachedTokens = nil
                case .failure(let error):
                    self.add(.error, error.message); self.queuePaused = true
                }
                do {
                    let oldKey=self.conversationKey
                    let id = self.apiConversationID ?? UUID(); self.apiConversationID = id
                    self.preferences.copyOverride(from:oldKey,to:self.conversationKey)
                    try APIHistory.save(APIConversation(id: id, connectionID: connection.id, connectionName: connection.name, directory: self.cwd, date: Date(), messages: APIStoredMessage.capture(self.items)))
                } catch { self.add(.error, "Ответ показан, но API-историю не удалось сохранить на диск.") }
                self.loadThreads(); self.drainQueue()
            }
        } catch {
            if echo && !didEcho { add(.user, text.isEmpty ? "(картинка)" : text).images = images }
            add(.error, (error as? APIProblem)?.message ?? "Не удалось подготовить запрос API."); queuePaused = true
        }
    }
    func openAPI(_ thread: ThreadInfo) {
        guard !busy, !nativeCLIIsRunning else { add(.note, "Сначала останови текущий ответ."); return }
        do {
            let value = try JSONDecoder().decode(APIConversation.self, from: Data(contentsOf: URL(fileURLWithPath: thread.path)))
            guard let connection = apiConnectionStore.connections.first(where: { $0.id == value.connectionID }) else {
                add(.error, "Подключение этой API-истории удалено. История сохранена на диске."); return
            }
            newChat(); chooseAPI(connection); apiConversationID = value.id; cwd = value.directory
            for message in value.messages { add(message.role == "user" ? .user : .agent, message.text).images = message.images }
        } catch { add(.error, "Не удалось прочитать API-историю.") }
    }
    func handleAPISlash(_ text: String) -> Bool {
        if handleFast(text) { return true }
        guard isAPI, text.hasPrefix("/"), !text.dropFirst().contains("/") else { return false }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "/help": add(.note, "API: текст, изображения (если модель поддерживает), локальная история, очередь и Суперпромпт. /new, /clear, /stop, /usage. Инструменты, MCP, CLI-команды и автоматические вопросы инструментов доступны в Codex/Claude CLI.")
        case "/new", "/clear": newChat()
        case "/stop": interrupt()
        case "/usage": add(.note, "Лимиты API неизвестны. Смотри квоты и расходы в кабинете своего API-провайдера.")
        default: add(.error, "Эта slash-команда относится к CLI. Для API доступна /help.")
        }
        return true
    }
}

protocol APIChatTransport: AnyObject {
    func send(connection: APIConnection, key: String, messages: [JSON], completion: @escaping (Result<APIResult, APIProblem>) -> Void)
    func cancel()
}
extension CompatibleAPIClient: APIChatTransport {}

final class APICoachTransport: PromptCoachTransport {
    var onNotification: (String, JSON) -> Void = { _, _ in }
    var onServerRequest: (Any, String, JSON) -> Void = { _, _, _ in }
    var onExit: () -> Void = {}
    private let connection: APIConnection
    private let vault: APIKeyVault
    private var messages: [JSON] = []
    private var client: APIChatTransport?
    private var active = true
    private let makeClient: () -> APIChatTransport
    init(connection: APIConnection, vault: APIKeyVault = KeychainVault(), makeClient: @escaping () -> APIChatTransport = { CompatibleAPIClient() }) { self.connection = connection; self.vault = vault; self.makeClient = makeClient }
    func start(_ ready: @escaping (Bool) -> Void) { ready(true) }
    func call(_ method: String, _ params: JSON, _ cb: @escaping (JSON) -> Void) {
        if method == "thread/start" {
            messages = [["role": "system", "content": params["baseInstructions"] as? String ?? ""]]
            cb(["result": ["thread": ["id": "coach-api"]]]); return
        }
        guard method == "turn/start" else { cb(["error": ["message": "Метод недоступен для API."]]); return }
        do {
            guard let key = try vault.read(connection.id) else { throw APIProblem(message: "API-ключ отсутствует в Keychain.") }
            let input = params["input"] as? [JSON] ?? []
            let text = input.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let images = input.compactMap { $0["type"] as? String == "localImage" ? $0["path"] as? String : nil }
            let schema = String(data: try JSONSerialization.data(withJSONObject: PromptCoachReply.schema), encoding: .utf8)!
            messages.append(try APIStoredMessage(role: "user", text: text + "\nВерни только JSON по схеме, без Markdown:\n" + schema, images: images).wire())
            let client = makeClient(); self.client = client
            cb(["result": [:]])
            client.send(connection: connection, key: key, messages: messages) { [weak self] result in
                guard let self, self.active else { return }
                switch result {
                case .success(let response):
                    self.messages.append(["role": "assistant", "content": response.text])
                    self.onNotification("item/completed", ["threadId": "coach-api", "item": ["type": "agentMessage", "id": UUID().uuidString, "text": response.text]])
                    self.onNotification("turn/completed", ["threadId": "coach-api", "turn": ["status": "completed"]])
                case .failure(let error): self.onNotification("error", ["threadId": "coach-api", "error": ["message": error.message]])
                }
            }
        } catch { cb(["error": ["message": (error as? APIProblem)?.message ?? "Не удалось подготовить API-запрос редактора."]]) }
    }
    func reject(_ id: Any, _ message: String) {}
    func stop() { active = false; client?.cancel(); client = nil }
}
