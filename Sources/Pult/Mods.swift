import AppKit
import SwiftUI
import WebKit

struct PultMod: Codable, Identifiable {
    struct Theme: Codable { var accent: String; var background: String? }
    struct Command: Codable {
        var name: String
        var title: String
        var prompt: String?
        var shell: String?
    }
    struct Panel: Codable { var title: String; var html: String }
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

    static func decode(_ data: Data) throws -> PultMod {
        guard data.count <= 2_000_000 else { throw ModError("Мод больше 2 МБ") }
        let mod = try JSONDecoder().decode(Self.self, from: data)
        func valid(_ value: String) -> Bool { value.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil }
        guard mod.format == 1, valid(mod.id), !mod.name.isEmpty, mod.name.count <= 100,
              !mod.version.isEmpty, !mod.author.isEmpty, mod.commands.count <= 30,
              Set(mod.permissions).isSubset(of: ["shell", "network"]),
              Set(mod.commands.map(\.name)).count == mod.commands.count else { throw ModError("Неверный manifest .pult") }
        if let theme = mod.theme {
            guard Color.modHex(theme.accent) != nil, theme.background.map({ Color.modHex($0) != nil }) ?? true else { throw ModError("Цвет должен быть #RRGGBB") }
        }
        guard (mod.settings ?? [:]).count <= 30,
              (mod.settings ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 100 && $0.value.count <= 10_000 }) else { throw ModError("Слишком много настроек мода") }
        for command in mod.commands {
            guard valid(command.name), !command.title.isEmpty,
                  (command.prompt != nil) != (command.shell != nil),
                  command.shell == nil || mod.permissions.contains("shell") else { throw ModError("Неверная команда: " + command.name) }
        }
        return mod
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
    @Published private(set) var mods: [PultMod] = []
    @Published var enabled: Set<String> { didSet { defaults.set(Array(enabled).sorted(), forKey: "mods.enabled") } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "mods.theme") } }
    @Published var panelID: String?
    @Published var status = ""
    @Published private var values: [String: [String: String]]
    private let directory: URL
    private let defaults: UserDefaults
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pult/Mods")
        self.defaults = defaults
        values = defaults.dictionary(forKey: "mods.settings") as? [String: [String: String]] ?? [:]
        enabled = Set(defaults.stringArray(forKey: "mods.enabled") ?? [])
        themeID = defaults.string(forKey: "mods.theme") ?? ""
        reload()
    }
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
    }
    var theme: PultMod.Theme? { mods.first { $0.id == themeID && enabled.contains($0.id) }?.theme }
    var commandList: [PultCommand] {
        mods.filter { enabled.contains($0.id) }.flatMap { mod in mod.commands.map { PultCommand(name: mod.id + "/" + $0.name, detail: mod.name + " · " + $0.title) } }
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
    func install(_ url: URL) {
        do {
            guard url.pathExtension.lowercased() == "pult" else { throw ModError("Выбери файл .pult") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else { throw ModError("Мод больше 2 МБ") }
            let mod = try PultMod.decode(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "Установить «\(mod.name)» \(mod.version)?"
            alert.informativeText = "Автор: \(mod.author)\n\(mod.description ?? "")\n\nПрава: \(mod.permissions.isEmpty ? "без доступа к системе" : mod.permissions.joined(separator: ", "))\nКоманды: \(mod.commands.map { $0.name }.joined(separator: ", "))\n\nShell запрашивает подтверждение при каждом запуске. Панель не получает доступ к чатам, файлам и токенам. Установка заменит предыдущую версию этого мода."
            alert.addButton(withTitle: "Установить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try save(mod)
            status = "Установлен: " + mod.name
        } catch { status = error.localizedDescription }
    }
    func save(_ mod: PultMod) throws {
        let data = try JSONEncoder().encode(mod)
        _ = try PultMod.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent(mod.id + ".pult"), options: .atomic)
        enabled.insert(mod.id)
        reload()
    }
    func toggle(_ id: String, _ value: Bool) {
        if value { enabled.insert(id) } else { enabled.remove(id); if panelID == id { panelID = nil } }
    }
    func handle(_ text: String, chat: Chat) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = parts.first.map(String.init) else { return false }
        if name == "mods" { UserDefaults.standard.set("mods", forKey: "settingsTab"); chat.ui.showSettings = true; status = "Настройки → Моды"; return true }
        guard let mod = mods.first(where: { enabled.contains($0.id) && name.hasPrefix($0.id + "/") }),
              let command = mod.commands.first(where: { mod.id + "/" + $0.name == name }) else { return false }
        let input = parts.count > 1 ? String(parts[1]) : ""
        if let prompt = command.prompt {
            var expanded = prompt
            for (key, value) in settings(for: mod) { expanded = expanded.replacingOccurrences(of: "{{setting:" + key + "}}", with: value) }
            chat.send("Задача из мода «\(mod.name)»:\n" + expanded.replacingOccurrences(of: "{{input}}", with: input))
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
    @ObservedObject var store = ModStore.shared
    var body: some View {
        Section("Моды .pult") {
            HStack {
                Button("Установить из файла…") { store.chooseFile() }
                Button("Сохранить пример…") { store.exportExample() }
            }
            Text("Темы, команды и панели. Включённые моды и выбранная тема сохраняются автоматически.").font(.caption).foregroundStyle(.secondary)
            if !store.status.isEmpty { Text(store.status).textSelection(.enabled) }
            if store.mods.isEmpty { Text("Модов пока нет").foregroundStyle(.secondary) }
            ForEach(store.mods) { mod in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("\(mod.name) · \(mod.version)", isOn: Binding(get: { store.enabled.contains(mod.id) }, set: { store.toggle(mod.id, $0) }))
                    Text(mod.author + " · " + (mod.description ?? "")).font(.caption).foregroundStyle(.secondary)
                    Text(mod.commands.map { "/" + mod.id + "/" + $0.name }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                    ForEach((mod.settings ?? [:]).keys.sorted(), id: \.self) { key in
                        TextField(key, text: Binding(get: { store.settings(for: mod)[key] ?? "" }, set: { store.set($0, key: key, mod: mod) }))
                    }
                    HStack {
                        if mod.theme != nil { Button(store.themeID == mod.id ? "Тема выбрана" : "Применить тему") { store.themeID = mod.id } }
                        if mod.panel != nil { Button("Открыть панель") { store.panelID = mod.id } }
                    }.disabled(!store.enabled.contains(mod.id))
                }.padding(.vertical, 6)
            }
            if !store.themeID.isEmpty { Button("Стандартная тема") { store.themeID = "" } }
        }
    }
}

struct ModPanel: NSViewRepresentable {
    let mod: PultMod
    var settings: [String: String] = [:]
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        if let data = try? JSONEncoder().encode(settings), let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.pultSettings = " + json + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        let network = mod.permissions.contains("network") ? "https: http: wss: ws:" : "'none'"
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: \(network); connect-src \(network); font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'"
        view.navigationDelegate = context.coordinator
        view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + (mod.panel?.html ?? ""), baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Navigation { Navigation() }
    final class Navigation: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
