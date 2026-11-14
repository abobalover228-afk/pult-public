import AppKit
import SwiftUI

struct PultCommand: Identifiable {
    let name: String
    let detail: String
    var id: String { name }
    static let common: [PultCommand] = [
        .init(name: "help", detail: "Список команд"),
        .init(name: "new", detail: "Новый разговор"),
        .init(name: "clear", detail: "Очистить контекст, начать заново"),
        .init(name: "model", detail: "Выбрать модель"),
        .init(name: "compact", detail: "Сжать контекст текущего разговора"),
        .init(name: "status", detail: "Состояние текущей сессии"),
        .init(name: "usage", detail: "Лимиты аккаунта"),
        .init(name: "config", detail: "Настройки Пульта"),
        .init(name: "permissions", detail: "Настройки разрешений"),
        .init(name: "resume", detail: "Открыть сохранённый разговор"),
        .init(name: "copy", detail: "Скопировать последний ответ"),
        .init(name: "export", detail: "Сохранить диалог в Markdown"),
        .init(name: "cd", detail: "Сменить папку: /cd путь"),
        .init(name: "pwd", detail: "Показать рабочую папку"),
        .init(name: "diff", detail: "Показать изменения Git"),
        .init(name: "init", detail: "Создать инструкции проекта"),
        .init(name: "skills", detail: "Навыки текущего проекта"),
        .init(name: "mcp", detail: "Список MCP-серверов"),
        .init(name: "plugins", detail: "Установленные плагины"),
        .init(name: "doctor", detail: "Диагностика CLI"),
        .init(name: "version", detail: "Версия выбранного CLI"),
        .init(name: "stop", detail: "Прервать текущий ответ")
    ]
    static let codex: [PultCommand] = [
        .init(name: "rename", detail: "Переименовать разговор: /rename название"),
        .init(name: "fork", detail: "Создать ветку текущего разговора"),
        .init(name: "archive", detail: "Архивировать разговор"),
        .init(name: "unarchive", detail: "Восстановить разговор: /unarchive ID"),
        .init(name: "apps", detail: "Подключённые приложения"),
        .init(name: "review", detail: "Проверить изменения")
    ]
    static let claude: [PultCommand] = [
        .init(name: "cost", detail: "Расход токенов последнего хода"),
        .init(name: "memory", detail: "Открыть CLAUDE.md"),
        .init(name: "agents", detail: "Список агентов Claude Code"),
        .init(name: "plugin", detail: "Установленные плагины"),
        .init(name: "context", detail: "Информация о контексте")
    ]
    static func matches(_ draft: String, provider: String) -> [PultCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        return list(for: provider).filter { query.isEmpty || $0.name.hasPrefix(query) }
    }
    static func list(for provider: String) -> [PultCommand] {
        let all = common + (provider == "claude" ? claude : codex) + IntegratedCommandCatalog.entries(provider)
        var seen = Set<String>()
        return all.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }
}

struct SlashSuggestions: View {
    @ObservedObject var chat: Chat
    @ObservedObject var ui: UIState
    var matches: [PultCommand] {
        chat.matchingCommands(ui.draft)
    }
    var body: some View {
        if !matches.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        Button { ui.draft = "/" + command.name + " " } label: {
                            HStack(spacing: 12) {
                                Text("/" + command.name).font(mono).frame(width: 120, alignment: .leading)
                                Text(command.detail).font(monoSmall).foregroundColor(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(index == min(ui.slashSelection, matches.count - 1) ? accent.opacity(0.2) : Color.clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(6)
            }
            .frame(maxHeight: 210)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.1, green: 0.1, blue: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }
}
