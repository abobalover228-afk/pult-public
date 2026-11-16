import AppKit
import SwiftUI
import WebKit
import CryptoKit

struct PultMod: Codable, Identifiable {
    struct Theme: Codable { var accent: String; var background: String? }
    struct Command: Codable {
        var name: String
        var title: String
        var prompt: String?
        var shell: String?
        var script: String?
        var shortcut: String?
    }
    struct Panel: Codable { var title: String; var html: String }
    struct DockPanel: Codable, Identifiable {
        var id: String; var title: String; var html: String
        var placement: String?
    }
    struct Action: Codable, Identifiable {
        var id: String; var title: String; var icon: String?
        var command: String?; var panel: String?
    }
    var format: Int
    var id: String
    var name: String
    var version: String
    var author: String
    var description: String?
    var permissions: [String]
    var theme: Theme?
    var commands: [Command]
    var panel: Panel?
    var settings: [String: String]?
    var panels: [DockPanel]?
    var sidebar: [Action]?
    var toolbar: [Action]?
    var statusbar: [Action]?
    var background: String?
    var files: [String: String]?
    var networkDomains: [String]?

    static let permissions: Set<String> = ["shell", "network", "chats.read", "chats.write", "files.read", "files.write", "team.read", "team.write", "process", "secrets", "background"]
    var allPanels: [DockPanel] {
        (panel.map { [DockPanel(id: "main", title: $0.title, html: $0.html, placement: "sheet")] } ?? []) + (panels ?? [])
    }
    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data) throws -> PultMod {
        guard data.count <= 2_000_000 else { throw ModError("Мод больше 2 МБ") }
        let mod = try JSONDecoder().decode(Self.self, from: data)
        func valid(_ value: String) -> Bool { value.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil }
        guard [1, 2].contains(mod.format), valid(mod.id), !mod.name.isEmpty, mod.name.count <= 100,
              !mod.version.isEmpty, !mod.author.isEmpty, mod.commands.count <= 30,
              Set(mod.permissions).isSubset(of: mod.format == 1 ? ["shell", "network"] : Self.permissions),
              Set(mod.commands.map(\.name)).count == mod.commands.count else { throw ModError("Неверный manifest .pult") }
        if let theme = mod.theme {
            guard Color.modHex(theme.accent) != nil, theme.background.map({ Color.modHex($0) != nil }) ?? true else { throw ModError("Цвет должен быть #RRGGBB") }
        }
        guard (mod.settings ?? [:]).count <= 30,
              (mod.settings ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 100 && $0.value.count <= 10_000 }) else { throw ModError("Слишком много настроек мода") }
        for command in mod.commands {
            guard valid(command.name), !command.title.isEmpty,
                  [command.prompt, command.shell, command.script].compactMap({ $0 }).count == 1,
                  command.shell == nil || mod.permissions.contains("shell"),
                  command.script == nil || mod.format == 2,
                  command.shortcut.map(Self.validShortcut) ?? true else { throw ModError("Неверная команда: " + command.name) }
        }
        guard mod.allPanels.count <= 12, Set(mod.allPanels.map(\.id)).count == mod.allPanels.count,
              mod.allPanels.allSatisfy({ valid($0.id) && !$0.title.isEmpty && ["main", "left", "right", "sheet"].contains($0.placement ?? "main") }),
              mod.background == nil || (mod.format == 2 && mod.permissions.contains("background")),
              mod.format == 2 || (mod.panels == nil && mod.sidebar == nil && mod.toolbar == nil && mod.statusbar == nil && mod.files == nil),
              (mod.files ?? [:]).count <= 60,
              (mod.files ?? [:]).keys.allSatisfy({ validAsset($0) }),
              (mod.networkDomains ?? []).count <= 30,
              (mod.networkDomains ?? []).allSatisfy({ $0.count <= 253 && $0.range(of: #"^(\*\.)?[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil }) else { throw ModError("Неверные панели, фоновый код или файлы мода") }
        for actions in [mod.sidebar, mod.toolbar, mod.statusbar].compactMap({ $0 }) {
            guard actions.count <= 20, Set(actions.map(\.id)).count == actions.count,
                  actions.allSatisfy({ action in valid(action.id) && !action.title.isEmpty &&
                      ((action.command != nil) != (action.panel != nil)) &&
                      (action.command.map { name in mod.commands.contains { $0.name == name } } ?? true) &&
                      (action.panel.map { id in mod.allPanels.contains { $0.id == id } } ?? true)
                  }) else { throw ModError("Неверная кнопка мода") }
        }
        return mod
    }
    static func validAsset(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 200 && !path.hasPrefix("/") && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".env") && $0 != ".git" && $0 != ".ssh"
        }
    }
    static func validShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 5, let key = parts.last, key.count == 1,
              key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil else { return false }
        let modifiers = parts.dropLast().map(String.init)
        return Set(modifiers).count == modifiers.count && Set(modifiers).isSubset(of: ["cmd", "alt", "ctrl", "shift"]) && !Set(modifiers).isDisjoint(with: ["cmd", "alt", "ctrl"])
    }
}

struct ModError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension Color {
    static func modHex(_ value: String) -> Color? {
        guard value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
              let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

final class ModStore: ObservableObject {
    static let shared = ModStore()
    private static let previewDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pult-sdk-preview-" + UUID().uuidString)
    private static var preview: Bool { CommandLine.arguments.contains("--mod-preview") }
    @Published private(set) var mods: [PultMod] = []
    @Published var enabled: Set<String> { didSet { defaults.set(Array(enabled).sorted(), forKey: "mods.enabled") } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "mods.theme") } }
    @Published var panelID: String?
    @Published var mainPanelID: String?
    @Published var leftPanelID: String?
    @Published var rightPanelID: String?
    @Published var status = ""
    @Published private var values: [String: [String: String]]
    private let directory: URL
    private let defaults: UserDefaults
    var activeMods: [PultMod] { mods.filter { enabled.contains($0.id) && approved($0) } }
    func approved(_ mod: PultMod) -> Bool { defaults.string(forKey: "mods.approved." + mod.id) == mod.fingerprint }
    func dataDirectory(_ id: String) -> URL { directory.appendingPathComponent("Data/" + id, isDirectory: true) }
    init(directory: URL? = nil, defaults: UserDefaults = ModStore.preferences) {
        self.directory = directory ?? (Self.preview ? Self.previewDirectory : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pult/Mods"))
        self.defaults = defaults
        values = defaults.dictionary(forKey: "mods.settings") as? [String: [String: String]] ?? [:]
        enabled = Set(defaults.stringArray(forKey: "mods.enabled") ?? [])
        themeID = defaults.string(forKey: "mods.theme") ?? ""
        reload()
        // Existing v1 installs only had prompts and individually confirmed shell commands.
        for mod in mods where mod.format == 1 && enabled.contains(mod.id) && defaults.string(forKey: "mods.approved." + mod.id) == nil {
            defaults.set(mod.fingerprint, forKey: "mods.approved." + mod.id)
        }
    }
    static var preferences: UserDefaults { preview ? UserDefaults(suiteName: "pult.mods.preview")! : .standard }
    func settings(for mod: PultMod) -> [String: String] {
        (mod.settings ?? [:]).merging(values[mod.id] ?? [:]) { _, saved in saved }
    }
    func set(_ value: String, key: String, mod: PultMod) {
        values[mod.id, default: [:]][key] = value
        defaults.set(values, forKey: "mods.settings")
    }
    func reload() {
        mods = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pult" }.compactMap { try? PultMod.decode(Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
        let active = Set(activeMods.map(\.id))
        func permitted(_ key: String?) -> Bool { key.flatMap { $0.split(separator: "/").first.map(String.init) }.map(active.contains) ?? true }
        if !permitted(mainPanelID) { mainPanelID = nil }
        if !permitted(leftPanelID) { leftPanelID = nil }
        if !permitted(rightPanelID) { rightPanelID = nil }
        if !permitted(panelID) { panelID = nil }
    }
    var theme: PultMod.Theme? { activeMods.first { $0.id == themeID }?.theme }
    var commandList: [PultCommand] {
        activeMods.flatMap { mod in mod.commands.map { PultCommand(name: mod.id + "/" + $0.name, detail: mod.name + " · " + $0.title) } }
    }
    func exportExample() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Mods/starter.pult"),
              let data = try? Data(contentsOf: source) else { status = "Пример: Examples/starter.pult в исходниках"; return }
        let picker = NSSavePanel(); picker.nameFieldStringValue = "starter.pult"
        if picker.runModal() == .OK, let url = picker.url {
            do { try data.write(to: url, options: .atomic); status = "Пример сохранён: " + url.path }
            catch { status = error.localizedDescription }
        }
    }
    func chooseFile() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { install(url) }
    }
    func installBuiltIn() {
        guard !mods.contains(where: { $0.id == "native-team" }),
              let url = Bundle.main.resourceURL?.appendingPathComponent("Mods/native-team.pult"),
              let data = try? Data(contentsOf: url), let mod = try? PultMod.decode(data) else { return }
        do { try save(mod) } catch { status = error.localizedDescription }
    }
    func install(_ url: URL) {
        do {
            guard url.pathExtension.lowercased() == "pult" else { throw ModError("Выбери файл .pult") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else { throw ModError("Мод больше 2 МБ") }
            let mod = try PultMod.decode(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "Установить «\(mod.name)» \(mod.version)?"
            alert.informativeText = "Автор: \(mod.author)\n\(mod.description ?? "")\n\nПрава: \(mod.permissions.isEmpty ? "только интерфейс и своё хранилище" : mod.permissions.joined(separator: ", "))\nКоманды: \(mod.commands.map { $0.name }.joined(separator: ", "))\nПанели: \(mod.allPanels.map { $0.title }.joined(separator: ", "))\n\nAPI открывает только перечисленные права. Process разрешает локальные программы с правами пользователя, background — работу без открытой панели. Shell отдельно показывает код перед запуском. Секреты API принадлежат только этому моду. Установка заменит его предыдущую версию."
            alert.addButton(withTitle: "Установить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try save(mod)
            status = "Установлен: " + mod.name
        } catch { status = error.localizedDescription }
    }
    func save(_ mod: PultMod) throws {
        ModPlatform.shared.stop(mod.id)
        let data = try JSONEncoder().encode(mod)
        _ = try PultMod.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent(mod.id + ".pult"), options: .atomic)
        defaults.set(mod.fingerprint, forKey: "mods.approved." + mod.id)
        enabled.insert(mod.id)
        reload()
    }
    func toggle(_ id: String, _ value: Bool) {
        if value {
            guard let mod = mods.first(where: { $0.id == id }), approved(mod) else { status = "Файл изменился. Установи мод заново и проверь его права."; return }
            enabled.insert(id)
        } else {
            enabled.remove(id)
            if panelID == id || panelID?.hasPrefix(id + "/") == true { panelID = nil }
            if mainPanelID?.hasPrefix(id + "/") == true { mainPanelID = nil }
            if leftPanelID?.hasPrefix(id + "/") == true { leftPanelID = nil }
            if rightPanelID?.hasPrefix(id + "/") == true { rightPanelID = nil }
            ModPlatform.shared.stop(id)
        }
    }
    func handle(_ text: String, chat: Chat) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = parts.first.map(String.init) else { return false }
        if name == "mods" { UserDefaults.standard.set("mods", forKey: "settingsTab"); chat.ui.showSettings = true; status = "Настройки → Моды"; return true }
        guard let mod = activeMods.first(where: { name.hasPrefix($0.id + "/") }),
              let command = mod.commands.first(where: { mod.id + "/" + $0.name == name }) else { return false }
        let input = parts.count > 1 ? String(parts[1]) : ""
        if let prompt = command.prompt {
            var expanded = prompt
            for (key, value) in settings(for: mod) { expanded = expanded.replacingOccurrences(of: "{{setting:" + key + "}}", with: value) }
            chat.send("Задача из мода «\(mod.name)»:\n" + expanded.replacingOccurrences(of: "{{input}}", with: input))
        } else if let script = command.script {
            ModPlatform.shared.run(script, mod: mod, input: input)
        } else if let shell = command.shell {
            let alert = NSAlert(); alert.messageText = "Мод «\(mod.name)» запускает код"
            alert.informativeText = "Папка: \(chat.cwd)\n\n\(shell)\n\nАргумент $1: \(input)\n\nКод получает права твоего пользователя."
            alert.addButton(withTitle: "Запустить"); alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn { run(shell, input: input, settings: settings(for: mod), chat: chat, name: name) }
        }
        return true
    }
    private func run(_ shell: String, input: String, settings: [String: String], chat: Chat, name: String) {
        let item = chat.add(.command, "Мод /" + name)
        let cwd = chat.cwd
        DispatchQueue.global().async {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("pult-mod-" + UUID().uuidString)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                defer { try? FileManager.default.removeItem(at: url) }
                let out = try FileHandle(forWritingTo: url); defer { try? out.close() }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", shell, name, input]
                var environment = ProcessInfo.processInfo.environment
                environment["PULT_MOD_SETTINGS"] = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
                process.environment = environment
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = out
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
                process.waitUntilExit(); timeout.cancel()
                let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
                let end = try reader.seekToEnd(); try reader.seek(toOffset: end > 100_000 ? end - 100_000 : 0)
                let output = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
                DispatchQueue.main.async { item.output = output; item.exitCode = Int(process.terminationStatus); item.done = true }
            } catch { DispatchQueue.main.async { item.output = error.localizedDescription; item.exitCode = 1; item.done = true } }
        }
    }
}

struct ModsSettingsView: View {
    @ObservedObject var platform = ModPlatform.shared
    @ObservedObject var store = ModStore.shared
    var body: some View {
        Section("Моды .pult") {
            HStack {
                Button("Установить из файла…") { store.chooseFile() }
                Button("Сохранить пример…") { store.exportExample() }
                Button("Пример SDK 2") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("Mods/sdk-playground.pult") { store.install(url) }
                }
            }
            Button("Перечитать файлы модов") { store.reload() }
            Text("SDK 2: панели в окне, команды и хоткеи, события, чаты, проект, процессы и своё хранилище.").font(.caption).foregroundStyle(.secondary)
            Text("Темы, команды и панели. Включённые моды и выбранная тема сохраняются автоматически.").font(.caption).foregroundStyle(.secondary)
            if !store.status.isEmpty { Text(store.status).textSelection(.enabled) }
            if store.mods.isEmpty { Text("Модов пока нет").foregroundStyle(.secondary) }
            ForEach(store.mods) { mod in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("\(mod.name) · \(mod.version)", isOn: Binding(get: { store.enabled.contains(mod.id) }, set: { store.toggle(mod.id, $0) }))
                    if !store.approved(mod) { Text("Файл изменился: API заблокирован до повторной установки").font(.caption).foregroundStyle(.orange) }
                    Text("Права: " + mod.permissions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    Text(mod.author + " · " + (mod.description ?? "")).font(.caption).foregroundStyle(.secondary)
                    Text(mod.commands.map { "/" + mod.id + "/" + $0.name }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                    ForEach((mod.settings ?? [:]).keys.sorted(), id: \.self) { key in
                        TextField(key, text: Binding(get: { store.settings(for: mod)[key] ?? "" }, set: { store.set($0, key: key, mod: mod) }))
                    }
                    HStack {
                        if mod.theme != nil { Button(store.themeID == mod.id ? "Тема выбрана" : "Применить тему") { store.themeID = mod.id } }
                        if !mod.allPanels.isEmpty { Button("Открыть панель") {
                            Workspace.shared.active.ui.showSettings = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { try? ModPlatform.shared.open(mod.id, panel: mod.allPanels[0].id) }
                        } }
                        Button("Ещё 20 автоходов") { ModPlatform.shared.resetTurns(mod.id) }
                    }.disabled(!store.enabled.contains(mod.id) || !store.approved(mod))
                    if let lines = platform.logs[mod.id], !lines.isEmpty {
                        DisclosureGroup("Журнал мода") { Text(lines.suffix(8).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }.padding(.vertical, 6)
            }
            if !store.themeID.isEmpty { Button("Стандартная тема") { store.themeID = "" } }
        }
    }
}

struct ModPanel: NSViewRepresentable {
    let mod: PultMod
    var settings: [String: String] = [:]
    var html: String? = nil
    func makeNSView(context: Context) -> WKWebView { context.coordinator.make(html: html ?? mod.panel?.html ?? "") }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> ModWebBridge { ModWebBridge(mod: mod) }
    static func dismantleNSView(_ view: WKWebView, coordinator: ModWebBridge) { coordinator.dispose(view) }
}
