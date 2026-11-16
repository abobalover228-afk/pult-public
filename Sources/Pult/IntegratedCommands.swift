import AppKit
import SwiftUI

struct PendingNativeAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let perform: () -> Void
}
struct ModelChoice: Identifiable {
    let id: String
    let name: String
    let description: String
    var efforts: [String] = []
    var defaultEffort: String? = nil
}

/// Модели Codex с сервера — один список на все чаты, загружается при подключении.
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published var codex: [ModelChoice] = []
    @Published var loading = false
    static let claude: [ModelChoice] = [
        ModelChoice(id: "", name: "По умолчанию", description: "Как настроено в Claude Code"),
        ModelChoice(id: "opus", name: "Opus", description: "Текущая Opus из установленного Claude Code"),
        ModelChoice(id: "sonnet", name: "Sonnet", description: "Текущая Sonnet из установленного Claude Code"),
        ModelChoice(id: "haiku", name: "Haiku", description: "Текущая Haiku из установленного Claude Code")
    ]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    func load(_ client: CodexClient?, force: Bool = false) {
        guard let client = client, client.alive, !loading, force || codex.isEmpty else { return }
        loading = true
        func page(_ cursor: String?, _ collected: [ModelChoice]) {
            var params: JSON = ["limit": 100]
            if let cursor = cursor { params["cursor"] = cursor }
            client.call("model/list", params) { [weak self] response in
                guard let self = self else { return }
                guard let result = response["result"] as? JSON else { self.loading = false; return }
                let rows = ((result["data"] as? [JSON]) ?? []).compactMap { row -> ModelChoice? in
                    guard let name = row["model"] as? String ?? row["id"] as? String, row["hidden"] as? Bool != true else { return nil }
                    let efforts = ((row["supportedReasoningEfforts"] as? [JSON]) ?? []).compactMap { $0["reasoningEffort"] as? String }
                    return ModelChoice(id: name, name: row["displayName"] as? String ?? name, description: row["description"] as? String ?? "",
                                       efforts: efforts, defaultEffort: row["defaultReasoningEffort"] as? String)
                }
                let all = collected + rows
                if let next = result["nextCursor"] as? String, next != cursor { page(next, all); return }
                self.codex = all; self.loading = false
            }
        }
        page(nil, [])
    }
}
enum CommandWords {
    // Deliberately no shell expansion: CLI arguments cannot execute $(...), pipes or redirects.
    static func parse(_ input: String) throws -> [String] {
        var result: [String] = [], word = "", quote: Character?, escaping = false, started = false
        for character in input {
            if escaping { word.append(character); escaping = false; started = true; continue }
            if character == "\\", quote != "'" { escaping = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
                started = true; continue
            }
            if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil, !escaping else { throw NSError(domain: "CommandWords", code: 1, userInfo: [NSLocalizedDescriptionKey: "Закрой кавычку или убери последний обратный слеш."]) }
        if started { result.append(word) }
        return result
    }
}

enum IntegratedCommandCatalog {
    static func entries(_ provider: String) -> [PultCommand] {
        let common: [(String,String)] = [
            ("effort", "Глубина размышлений: /effort low|medium|high|max"),
            ("hooks", "Хуки проекта"), ("recap", "Краткий итог разговора"),
            ("focus", "Показывать только сообщения и важные запросы"),
            ("raw", "Развернуть вывод инструментов"), ("queue", "Очередь: status|pause|resume|clear"),
            ("cli", "Подкоманды установленного CLI в ленте: /cli --help"),
            ("login", "Вход в аккаунт"), ("logout", "Выход из аккаунта"),
            ("release-notes", "Версия установленного CLI"), ("restart", "Переподключить провайдера")
        ]
        let codex: [(String,String)] = [
            ("goal", "Цель разговора: /goal текст или clear"),
            ("experimental", "Функции: list или имя on|off"),
            ("debug-config", "Прочитать действующие настройки Codex"),
            ("memories", "Открыть папку памяти Codex"),
            ("warnings", "Ошибки текущего разговора"),
            ("rollout", "Путь к файлу текущего разговора"),
            ("delete", "Удалить разговор с отдельным подтверждением"),
            ("worktree", "Создать Git worktree: /worktree путь"),
            ("mention", "Добавить файл: /mention путь"),
            ("ps", "Список локальных процессов Codex и Claude"),
            ("features", "Флаги Codex"), ("config-set", "Изменить настройку: /config-set ключ JSON"),
            ("import", "Найти конфигурацию других агентов")
        ]
        let claude: [(String,String)] = [
            ("plan", "Включить или выключить планирование Claude"),
            ("branch", "Ветка текущего разговора Claude"),
            ("rename", "Название разговора Claude"),
            ("reload-skills", "Перечитать локальные навыки"),
            ("reload-plugins", "Перечитать установленные плагины"),
            ("run", "Навык Claude: запустить приложение"),
            ("verify", "Навык Claude: проверить результат"),
            ("simplify", "Навык Claude: упростить код"),
            ("code-review", "Навык Claude: проверить код"),
            ("security-review", "Навык Claude: проверить безопасность"),
            ("debug", "Навык Claude: диагностика"),
            ("batch", "Навык Claude: пакетная задача"),
            ("deep-research", "Навык Claude: исследование"),
            ("design", "Навык Claude: дизайн"), ("slides", "Навык Claude: презентация"),
            ("dataviz", "Навык Claude: визуализация"),
            ("workflow-authoring", "Навык Claude: сценарии"),
            ("plugin-authoring", "Навык Claude: разработка плагина"),
            ("update-config", "Навык Claude: изменить настройки"),
            ("skill-doctor", "Диагностика навыков Claude")
        ]
        let shellCommands = (executableSubcommands[provider] ?? []).sorted().map { PultCommand(name: $0, detail: "Подкоманда " + provider + ": /cli " + $0 + " --help") }
        return (common + (provider == "claude" ? claude : codex)).map { PultCommand(name: $0.0, detail: $0.1) } + shellCommands
    }
    static let executableSubcommands: [String: Set<String>] = [
        "codex": Set(["agents", "exec", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "resume", "queue", "archive", "delete", "migrate-rollouts", "migrate-nfs-db", "unarchive", "fork", "cloud", "exec-server", "features", "help"]),
        "claude": Set(["agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin", "purge", "respawn", "rm", "setup-token", "stop", "ultrareview", "update"])
    ]
    static let claudeSkills = Set(["run", "verify", "simplify", "code-review", "security-review", "debug", "batch", "deep-research", "design", "slides", "dataviz", "workflow-authoring", "plugin-authoring", "update-config", "skill-doctor"])
}

extension Chat {
    var commandList: [PultCommand] {
        if isAPI { return [PultCommand(name: "fast", detail: "Fast: недоступен для произвольного API"), PultCommand(name: "help", detail: "Возможности API"), PultCommand(name: "new", detail: "Новый диалог"), PultCommand(name: "stop", detail: "Остановить запрос"), PultCommand(name: "usage", detail: "Лимиты неизвестны")] }
        var seen = Set<String>()
        let dynamic = target == "claude" ? claudeCommands : []
        return (PultCommand.list(for: target) + dynamic + ModStore.shared.commandList).filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }
    func matchingCommands(_ input: String) -> [PultCommand] {
        guard input.hasPrefix("/"), !input.contains(where: { $0.isWhitespace }) else { return [] }
        let prefix = String(input.dropFirst()).lowercased()
        return commandList.filter { $0.name.hasPrefix(prefix) }
    }
    func showModelPicker() {
        ModelCatalog.shared.load(client)
        showModelChoices = true                    // окно выбора модели у поля ввода
    }

    @discardableResult func handleIntegratedCommand(_ command: String, argument: String) -> Bool {
        let claude = target == "claude"
        let mutable = Set(["effort", "plan", "restart", "goal", "config-set", "experimental", "worktree", "branch", "delete", "login", "logout", "cli"])
        if busy && (mutable.contains(command) || (claude && (IntegratedCommandCatalog.claudeSkills.contains(command) || claudeCommands.contains { $0.name == command }))) {
            add(.note, "Дождись ответа или останови его через /stop."); return true
        }
        if claude && (IntegratedCommandCatalog.claudeSkills.contains(command) || claudeCommands.contains(where: { $0.name == command })) {
            sendClaude("/" + command + (argument.isEmpty ? "" : " " + argument)); return true
        }
        switch command {
        case "effort":
            let levels = claude ? ["low","medium","high","xhigh","max","auto"] : ["none","minimal","low","medium","high","xhigh","max","auto"]
            guard levels.contains(argument) else { add(.note, "Глубина: \(claude ? (claudeEffort ?? "auto") : (reasoningEffort ?? "auto"))\n/effort " + levels.joined(separator: "|")); return true }
            if claude { claudeEffort = argument == "auto" ? nil : argument } else { reasoningEffort = argument == "auto" ? nil : argument }
            add(.note, "Глубина размышлений: " + argument)
        case "plan" where claude:
            claudePermissionMode = claudePermissionMode == "plan" ? "auto" : "plan"
            add(.note, "Режим Claude: " + claudePermissionMode)
            if !argument.isEmpty { sendClaude(argument) }
        case "focus": focusedConversation.toggle()
        case "raw": expandedTools.toggle()
        case "queue":
            switch argument {
            case "pause": queuePaused = true; add(.note, "Очередь приостановлена.")
            case "resume": resumeQueue()
            case "clear": pendingMessages.removeAll(); add(.note, "Очередь очищена.")
            default: add(.note, "Очередь: \(pendingMessages.count), \(queuePaused ? "пауза" : "готова")\n" + pendingMessages.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n") + "\n/queue pause|resume|clear")
            }
        case "recap":
            let prompt = "Кратко подведи итог текущего разговора: цель, сделано, что осталось. Не выполняй новых действий."
            if busy { add(.note, "Дождись ответа.") } else if claude { sendClaude(prompt) } else { send(prompt) }
        case "hooks":
            if claude { readLocalText(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/settings.json"), label: "Настройки хуков проекта") }
            else { slashRPC("hooks/list", ["cwds": [cwd]]) }
        case "goal" where !claude:
            guard let id = threadId else { add(.note, "Сначала начни разговор."); return true }
            if argument.isEmpty { slashRPC("thread/goal/get", ["threadId": id]) }
            else if ["clear","off","stop"].contains(argument) { slashRPC("thread/goal/clear", ["threadId": id], success: "Цель очищена.") }
            else { slashRPC("thread/goal/set", ["threadId": id, "objective": argument, "origin": "user"], success: "Цель сохранена.") }
        case "experimental" where !claude:
            let words = argument.split(separator: " ").map(String.init)
            if words.count == 2, ["on","off"].contains(words[1]) { slashRPC("experimentalFeature/enablement/set", ["enablement": [words[0]: words[1] == "on"]]) }
            else { slashRPC("experimentalFeature/list", ["limit": 100]) }
        case "debug-config" where !claude: slashRPC("config/read", ["cwd": cwd, "includeLayers": true])
        case "config-set" where !claude:
            let parts = argument.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let data = String(parts[1]).data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { add(.note, "Использование: /config-set ключ JSON\nНапример: /config-set model_reasoning_effort \"high\""); return true }
            let key = String(parts[0])
            pendingNativeAction = PendingNativeAction(title: "Изменить конфигурацию Codex?", message: "Ключ: " + key) { [weak self] in self?.slashRPC("config/value/write", ["keyPath": key, "value": value, "mergeStrategy": "replace"], success: "Настройка сохранена. Для параметров запуска переподключи Codex через /restart.") }
        case "warnings": add(.note, items.filter { $0.kind == .error }.map(\.text).joined(separator: "\n").isEmpty ? "Ошибок в этом разговоре нет." : items.filter { $0.kind == .error }.map(\.text).joined(separator: "\n"))
        case "rollout":
            if let id = threadId, let path = localRollout(id, in: account.home, homes: accounts.map(\.home)) { add(.note, path) }
            else { add(.note, "Файл текущего разговора пока не найден.") }
        case "memories":
            let url = URL(fileURLWithPath: account.home).appendingPathComponent("memories", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { add(.note, "Папка памяти пока не создана.") }
        case "mention":
            guard !argument.isEmpty else { add(.note, "Использование: /mention путь"); return true }
            let url = resolveCommandPath(argument)
            guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024, let content = String(data: data, encoding: .utf8) else { add(.error, "Нужен читаемый текстовый файл до 1 МБ."); return true }
            if busy { add(.note, "Дождись ответа перед добавлением файла.") }
            else { send("Файл \(url.path):\n```\n\(content)\n```") }
        case "worktree":
            guard !argument.isEmpty else { add(.note, "Использование: /worktree путь\nСоздаст отдельную рабочую копию Git."); return true }
            let path = resolveCommandPath(argument).path
            runInlineCLI("/usr/bin/git", ["worktree", "add", "--detach", path])
        case "delete":
            guard let id = threadId else { add(.note, "Сначала начни разговор."); return true }
            pendingNativeAction = PendingNativeAction(title: "Удалить текущий разговор?", message: "Это удаление сохранённой истории Codex. ID: " + id) { [weak self] in
                self?.client?.call("thread/delete", ["threadId": id]) { response in
                    guard let self = self else { return }
                    if let error = response["error"] as? JSON { self.add(.error, error["message"] as? String ?? "Не удалось удалить") }
                    else { self.newChat(); self.add(.note, "Разговор удалён.") }
                }
            }
        case "restart":
            if claude { add(.note, "Claude запускается заново на каждом ходе, сохраняя разговор.") }
            else { connect(current) { [weak self] in self?.add(.note, "Codex переподключён. Разговор сохранён.") } }
        case "login":
            if claude { runInlineCLI(claudeBin, ["auth", "login"]) }
            else { slashRPC("account/login/start", ["type": "chatgpt"]) }
        case "logout":
            pendingNativeAction = PendingNativeAction(title: "Выйти из аккаунта?", message: "Для дальнейшей работы потребуется повторный вход.") { [weak self] in
                guard let self = self else { return }
                if claude { self.runInlineCLI(claudeBin, ["auth", "logout"]) }
                else { self.slashRPC("account/logout", [:], success: "Выполнен выход из аккаунта.") }
            }
        case "ps": runInlineCLI("/bin/ps", ["-axo", "pid,etime,comm"])
        case "features": runInlineCLI(codexBin, ["features", "list"])
        case "release-notes":
            add(.note, "Установленная версия показана ниже. Журнал изменений: " + (claude ? "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md" : "https://github.com/openai/codex/releases"))
            runInlineCLI(claude ? claudeBin : codexBin, ["--version"])
        case "import" where !claude: slashRPC("externalAgentConfig/detect", ["cwds": [cwd], "includeHome": true])
        case "branch" where claude:
            guard let id = UserDefaults.standard.string(forKey: "claudeSession:" + cwd) else { add(.note, "Сначала начни разговор Claude."); return true }
            // A fork must get a fresh ID while resuming the original session.
            claudeForkFrom = id
            let newID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(newID, forKey: "claudeSession:" + cwd)
            add(.note, "Следующий ход продолжит копию разговора Claude.")
        case "rename" where claude:
            guard !argument.isEmpty else { add(.note, "Использование: /rename название"); return true }
            sendClaude("/rename " + argument)
        case "reload-skills": listClaudeFiles("skills")
        case "reload-plugins": runInlineCLI(claudeBin, ["plugin", "list"])
        case "cli":
            do {
                let args = try CommandWords.parse(argument.isEmpty ? "--help" : argument)
                pendingNativeAction = PendingNativeAction(title: "Выполнить команду CLI?", message: (claude ? "claude " : "codex ") + args.joined(separator: " ")) { [weak self] in
                    self?.runInlineCLI(claude ? claudeBin : codexBin, args)
                }
            } catch { add(.error, error.localizedDescription) }
        default:
            let reserved = Set(["help", "new", "clear", "model", "compact", "status", "usage", "config", "permissions", "resume", "copy", "export", "cd", "pwd", "diff", "init", "skills", "mcp", "plugins", "plugin", "doctor", "version", "stop", "rename", "fork", "archive", "unarchive", "apps", "review", "agents", "memory", "context", "cost"])
            guard !reserved.contains(command), IntegratedCommandCatalog.executableSubcommands[target]?.contains(command) == true else { return false }
            do {
                let args = [command] + (try CommandWords.parse(argument.isEmpty ? "--help" : argument))
                pendingNativeAction = PendingNativeAction(title: "Выполнить подкоманду CLI?", message: (claude ? "claude " : "codex ") + args.joined(separator: " ")) { [weak self] in
                    self?.runInlineCLI(claude ? claudeBin : codexBin, args)
                }
            } catch { add(.error, error.localizedDescription) }
        }
        return true
    }

    func handleMCP(_ argument: String) {
        do {
            let args = try CommandWords.parse(argument)
            if target == "claude" { runInlineCLI(claudeBin, ["mcp"] + (args.isEmpty ? ["list"] : args)); return }
            if args.isEmpty || args == ["list"] || args == ["verbose"] { slashRPC("mcpServerStatus/list", ["limit": 100]); return }
            if args.first == "login", args.count == 2 { slashRPC("mcpServer/oauth/login", ["name": args[1]]); return }
            if args == ["reload"] { slashRPC("config/mcpServer/reload"); return }
            pendingNativeAction = PendingNativeAction(title: "Изменить MCP?", message: "codex mcp " + args.joined(separator: " ")) { [weak self] in self?.runInlineCLI(codexBin, ["mcp"] + args) }
        } catch { add(.error, error.localizedDescription) }
    }
    func handlePlugins(_ argument: String) {
        do {
            let args = try CommandWords.parse(argument)
            if target == "claude" { runInlineCLI(claudeBin, ["plugin"] + (args.isEmpty ? ["list"] : args)); return }
            let verb = args.first ?? "list"
            if ["list", "search", "find"].contains(verb) { listPlugins(args.dropFirst().joined(separator: " ").lowercased()); return }
            if args.count == 2, ["install","add"].contains(verb) { installPlugin(args[1]); return }
            if args.count == 2, ["remove","uninstall"].contains(verb) {
                pendingNativeAction = PendingNativeAction(title: "Удалить плагин?", message: args[1]) { [weak self] in self?.slashRPC("plugin/uninstall", ["pluginId": args[1]], success: "Плагин \(args[1]) удалён. /new — чтобы разговор его не видел.") }; return
            }
            runInlineCLI(codexBin, ["plugin"] + args)
        } catch { add(.error, error.localizedDescription) }
    }
    /// Каталог: (id, маркетплейс, путь маркетплейса, плагин).
    func pluginCatalog(_ done: @escaping ([(id: String, market: String, path: String?, plugin: JSON)]) -> Void) {
        guard let client = client else { add(.error, "Codex ещё не подключён."); return }
        client.call("plugin/list", ["cwds": [cwd]]) { [weak self] response in
            if let error = response["error"] as? JSON { self?.add(.error, error["message"] as? String ?? "Не удалось получить плагины"); return }
            let markets = (response["result"] as? JSON)?["marketplaces"] as? [JSON] ?? []
            done(markets.flatMap { m in (m["plugins"] as? [JSON] ?? []).map { (id: $0["id"] as? String ?? "", market: m["name"] as? String ?? "", path: m["path"] as? String, plugin: $0) } })
        }
    }
    func listPlugins(_ query: String) {
        pluginCatalog { [weak self] all in
            func line(_ p: JSON) -> String {
                let ui = p["interface"] as? JSON
                let title = ui?["displayName"] as? String ?? p["name"] as? String ?? ""
                return "• \(title) — `\(p["id"] as? String ?? "")`" + ((ui?["shortDescription"] as? String).map { " — " + $0 } ?? "")
            }
            let match = all.filter { item in
                query.isEmpty || ([item.id, (item.plugin["interface"] as? JSON)?["displayName"] as? String ?? "", (item.plugin["interface"] as? JSON)?["shortDescription"] as? String ?? ""] + (item.plugin["keywords"] as? [String] ?? [])).joined(separator: " ").lowercased().contains(query)
            }
            let installed = match.filter { $0.plugin["installed"] as? Bool == true }
            let available = match.filter { $0.plugin["installed"] as? Bool != true && !$0.id.hasPrefix("app-") }
            var text = "**Установлены (\(installed.count))**\n" + installed.map { line($0.plugin) + ($0.plugin["enabled"] as? Bool == false ? " (выключен)" : "") }.joined(separator: "\n")
            text += "\n\n**Можно поставить (\(available.count))**\n" + available.prefix(query.isEmpty ? 25 : 60).map { line($0.plugin) }.joined(separator: "\n")
            if available.count > (query.isEmpty ? 25 : 60) { text += "\n… ещё \(available.count - (query.isEmpty ? 25 : 60)). Уточни: /plugins search слово" }
            text += "\n\nПоставить: `/plugins install имя@маркетплейс` · удалить: `/plugins remove имя@маркетплейс` · свой маркетплейс: `/plugins marketplace add <git-url|путь>`"
            self?.add(.note, text)
        }
    }
    func installPlugin(_ wanted: String) {
        pluginCatalog { [weak self] all in
            guard let self = self else { return }
            let hits = all.filter { $0.id == wanted || $0.plugin["name"] as? String == wanted }
            guard hits.count == 1, let hit = hits.first else {
                self.add(.error, hits.isEmpty ? "Плагин \(wanted) не найден. /plugins search \(wanted)" : "Уточни маркетплейс: " + hits.map(\.id).joined(separator: ", ")); return
            }
            var params: JSON = ["pluginName": hit.plugin["name"] as? String ?? wanted, "installAttemptId": UUID().uuidString]
            if let path = hit.path { params["marketplacePath"] = path } else { params["remoteMarketplaceName"] = hit.market }
            self.client?.call("plugin/install", params) { [weak self] response in
                if let error = response["error"] as? JSON { self?.add(.error, "Установка \(hit.id): " + (error["message"] as? String ?? "ошибка")); return }
                let auth = ((response["result"] as? JSON)?["appsNeedingAuth"] as? [JSON] ?? []).map { "\($0["name"] ?? "") \($0["installUrl"] ?? "")" }
                self?.add(.note, "Плагин \(hit.id) установлен. /new — новый разговор его подхватит." + (auth.isEmpty ? "" : "\nНужен вход: " + auth.joined(separator: "; ")))
            }
        }
    }
    func handleSkills(_ argument: String) {
        if target == "claude" { listClaudeFiles("skills"); return }
        do {
            let args = try CommandWords.parse(argument)
            if args.count == 2, ["enable","disable"].contains(args[0]) { slashRPC("skills/config/write", ["path": resolveCommandPath(args[1]).path, "enabled": args[0] == "enable"]) }
            else { slashRPC("skills/list", ["cwds": [cwd], "forceReload": true]) }
        } catch { add(.error, error.localizedDescription) }
    }
    func resolveCommandPath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
    }
    func readLocalText(_ url: URL, label: String) {
        guard let data = try? Data(contentsOf: url), data.count < 1024 * 1024, let text = String(data: data, encoding: .utf8) else { add(.note, "Файл не найден или больше 1 МБ: " + url.path); return }
        add(.note, label + "\n" + text)
    }
}

struct ClaudeConversation: Identifiable {
    let id: String
    let title: String
    let modified: Date
    let directory: String
}
struct ClaudeConversationsView: View {
    @ObservedObject var chat: Chat
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Разговоры Claude").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.claudeConversations) { conversation in
                        Button { chat.selectClaudeConversation(conversation) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title).lineLimit(2)
                                Text(conversation.directory).font(.caption).foregroundColor(.secondary)
                                Text(conversation.modified, style: .date).font(.caption).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if chat.claudeConversations.isEmpty { Text("Сохранённых разговоров пока нет.").foregroundColor(.secondary) }
                }
            }
            Button("Закрыть") { chat.showClaudeConversations = false }
        }.padding(20).frame(width: 550, height: 470)
    }
}
extension Chat {
    func showClaudeResume(_ id: String) {
        guard !busy else { add(.note, "Сначала дождись ответа."); return }
        let root = URL(fileURLWithPath: homeDir).appendingPathComponent(".claude/projects", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
            var candidates: [(URL,Date)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if values?.isRegularFile == true { candidates.append((url,values?.contentModificationDate ?? .distantPast)) }
            }
            let conversations = candidates.sorted { $0.1 > $1.1 }.prefix(200).map { url, date -> ClaudeConversation in
                let session = url.deletingPathExtension().lastPathComponent
                var title = session, directory = ""
                if let file = try? FileHandle(forReadingFrom: url) {
                    defer { try? file.close() }
                    let data = (try? file.read(upToCount: 256000)) ?? Data()
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else { continue }
                        if let path = row["cwd"] as? String { directory = path }
                        if row["type"] as? String == "user", let message = row["message"] as? JSON {
                            if let text = message["content"] as? String { title = String(text.prefix(160)); break }
                            if let content = message["content"] as? [JSON], let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String { title = String(text.prefix(160)); break }
                        }
                    }
                }
                return ClaudeConversation(id: session, title: title, modified: date, directory: directory)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.claudeConversations = conversations
                if !id.isEmpty {
                    if let conversation = conversations.first(where: { $0.id == id }) { self.selectClaudeConversation(conversation) }
                    else { self.add(.error, "Разговор Claude не найден среди последних 200 сессий.") }
                } else { self.showClaudeConversations = true }
            }
        }
    }
    func selectClaudeConversation(_ conversation: ClaudeConversation) {
        guard !busy else { return }
        newChat()
        if !conversation.directory.isEmpty, FileManager.default.fileExists(atPath: conversation.directory) { cwd = conversation.directory }
        UserDefaults.standard.set(conversation.id, forKey: "claudeSession:" + cwd)
        claudeForkFrom = nil; showClaudeConversations = false
        add(.note, "Продолжен разговор Claude: " + conversation.title + "\nИстория восстановится в контексте следующего хода.")
    }
}
