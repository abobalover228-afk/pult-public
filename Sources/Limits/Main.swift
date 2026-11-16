// Лимиты — виджет на рабочем столе: Claude Code + три аккаунта Codex.
// Claude: ~/.claude/limits-cache.json (пишет строка состояния Claude Code).
// Codex: встроенный read-only helper.
import AppKit
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let python = "/usr/bin/env"
let limitsScript = Bundle.main.resourceURL!.appendingPathComponent("helpers/limits.py").path
let claudeCache = home + "/.claude/limits-cache.json"
let minsk = TimeZone.current

struct Window: Identifiable {
    let id = UUID()
    let name: String
    let left: Double?      // осталось, %
    let resets: Double?    // unix
}

struct Account: Identifiable {
    let id = UUID()
    let name: String
    let note: String?
    let windows: [Window]
    var home: String? = nil      // CODEX_HOME для аккаунтов Mac
    var loggedIn = true
}

var openAccountsWindow: () -> Void = {}

/// Запустить команду в новом окне Terminal.
func inTerminal(_ cmd: String) {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"Terminal\" to do script \"\(esc)\"", "-e", "tell application \"Terminal\" to activate"]
    try? p.run()
}
func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
let widgetDir = Bundle.main.resourceURL!.appendingPathComponent("helpers").path + "/"


func windowName(minutes: Double?) -> String {
    guard let m = minutes else { return "окно" }
    if m == 300 { return "5 часов" }
    if m == 10080 { return "неделя" }
    if m.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(m / 1440)) дн." }
    return "\(Int(m / 60)) ч"
}

func resetText(_ ts: Double?) -> String {
    guard let ts = ts else { return "" }
    let left = ts - Date().timeIntervalSince1970
    if left <= 0 { return "сброшен" }
    let f = DateFormatter()
    f.timeZone = minsk
    f.locale = Locale(identifier: "ru_RU")
    let sameDay = Calendar.current.dateComponents(in: minsk, from: Date()).day ==
        Calendar.current.dateComponents(in: minsk, from: Date(timeIntervalSince1970: ts)).day && left < 86400
    f.dateFormat = sameDay ? "HH:mm" : "d MMM HH:mm"
    let h = Int(left) / 3600, m = Int(left) % 3600 / 60
    let rest = h >= 24 ? "\(h / 24) д \(h % 24) ч" : (h > 0 ? "\(h) ч \(m) мин" : "\(m) мин")
    return "\(f.string(from: Date(timeIntervalSince1970: ts))) · через \(rest)"
}

func parseCodex(_ name: String, _ d: [String: Any]?, home: String? = nil) -> Account {
    guard let d = d else { return Account(name: name, note: "нет данных", windows: [], home: home) }
    if d["available"] as? Bool != true {
        let err = (d["error"] as? String) ?? "нет данных"
        let noLogin = err.contains("Нет входа")
        return Account(name: name, note: noLogin ? "нет входа" : (err.contains("Сервер") ? "сервер недоступен" : "неизвестно"),
                       windows: [], home: home, loggedIn: !noLogin)
    }
    var ws: [Window] = []
    for bucket in (d["limits"] as? [[String: Any]]) ?? [] {
        for w in (bucket["windows"] as? [[String: Any]]) ?? [] {
            ws.append(Window(name: windowName(minutes: w["minutes"] as? Double),
                             left: w["remaining_percent"] as? Double,
                             resets: w["resets_at"] as? Double))
        }
    }
    let plan = (d["plan"] as? String).map { $0.capitalized }
    return Account(name: name, note: ws.isEmpty ? "окна не предоставлены" : plan, windows: ws, home: home)
}

func readClaude() -> Account {
    let snapshot = ClaudeCacheSnapshot.parse(FileManager.default.contents(atPath: claudeCache))
    return Account(name: "Claude", note: snapshot.message,
                   windows: snapshot.fresh ? snapshot.windows.map { Window(name: $0.0, left: $0.1, resets: $0.2) } : [])
}
func openClaudeUsage() {
    inTerminal("export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; cd \"$HOME\"; claude /usage")
}

struct WidgetAPIConnection: Decodable { let id: UUID; let name: String; let model: String }
func readAPIConnections() -> [WidgetAPIConnection] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PultConnections/connections.json")
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([WidgetAPIConnection].self, from: data)) ?? []
}
func openAPIManager(_ id: UUID? = nil) {
    let value = id.map { "pult://api?id=" + $0.uuidString } ?? "pult://connections"
    NSWorkspace.shared.open(URL(string: value)!)
}

final class Model: ObservableObject {
    @Published var apiConnections = readAPIConnections()
    @Published var claude = readClaude()
    @Published var codex: [Account] = {
        let path = home + "/.codex-accounts.json"
        let rows = (FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: String]]) ?? []
        let accounts = rows.compactMap { row -> Account? in
            guard let name = row["name"], let directory = row["home"] else { return nil }
            return Account(name: name, note: "загружаю…", windows: [], home: directory)
        }
        return accounts.isEmpty ? [Account(name: "Codex", note: "загружаю…", windows: [])] : accounts
    }()
    @Published var updated: Date? = nil
    @Published var loading = false
    @Published var claudeNotice: String?
    func refreshAll() { refreshClaude(); claudeNotice = "Кеш перечитан. Свежую квоту выдаёт работающий Claude Code; для штатной проверки откройте /usage. Перечитывание не обновляет время получения."; refreshCodex() }

    func refreshClaude() { claude = readClaude(); apiConnections = readAPIConnections() }

    func refreshCodex() {
        if loading { return }
        loading = true
        apiConnections = readAPIConnections()
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["python3", limitsScript, "--json"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var accounts: [Account]
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                accounts = ((j["accounts"] as? [[String: Any]]) ?? []).map {
                    parseCodex(($0["name"] as? String) ?? "Codex", $0, home: $0["home"] as? String)
                }
            } catch {
                accounts = [Account(name: "Codex", note: "limits.py не запустился", windows: [])]
            }
            DispatchQueue.main.async {
                self.codex = accounts
                self.updated = Date()
                self.loading = false
            }
        }
    }
}

struct Bar: View {
    let left: Double
    var color: Color { left >= 50 ? .green : (left >= 20 ? .yellow : .red) }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color.opacity(0.9)).frame(width: max(4, g.size.width * left / 100))
            }
        }.frame(height: 6)
    }
}

struct AccountView: View {
    let a: Account
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let n = a.note { Text(n).font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true) }
            }
            ForEach(a.windows) { w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(w.name).font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Text(w.left.map { "осталось \(Int($0.rounded()))%" } ?? "неизвестно")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    if let l = w.left { Bar(left: l) }
                    let r = resetText(w.resets)
                    if !r.isEmpty { Text("сброс " + r).font(.system(size: 9.5)).foregroundColor(.secondary) }
                }
            }
        }
    }
}

struct WidgetView: View {
    @ObservedObject var m: Model
    @ObservedObject private var hidden = HiddenWidgetAccounts.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 16, weight: .medium)).accessibilityLabel("Лимиты аккаунтов").help("Остатки и время сброса лимитов")
                Spacer()
                if m.loading { ProgressView().scaleEffect(0.45).frame(width: 12, height: 12) }
                else if let u = m.updated {
                    Text(u, style: .time).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Button("Пульт") { NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Пульт.app").path)) }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
                Button("Открыть") { openAccountsWindow() }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
            }
            if !hidden.contains("claude") {
                AccountView(a: m.claude)
                Button("Проверить в Claude Code…") { openClaudeUsage() }.font(.caption).buttonStyle(.borderless).help("Открыть штатную /usage без модельного запроса")
            }
            ForEach(m.codex.filter { !hidden.contains(HiddenWidgetAccounts.codex(home: $0.home, name: $0.name)) }) { a in
                Divider().opacity(0.4)
                AccountView(a: a)
            }
            ForEach(m.apiConnections.filter { !hidden.contains("api:" + $0.id.uuidString) }, id: \.id) { connection in
                Divider().opacity(0.4)
                HStack { VStack(alignment: .leading) { Text(connection.name).font(.system(size: 13, weight: .semibold)); Text(connection.model + " · квота неизвестна").font(.caption2).foregroundColor(.secondary) }; Spacer(); Button { openAPIManager(connection.id) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help("Выбрать API в Пульте").accessibilityLabel("Открыть " + connection.name + " в Пульте") }
            }
            Button { MapWindow.shared.show() } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
            }.buttonStyle(.borderless).help("Открыть карту команд")
        }
        .padding(14)
        .frame(width: 250)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .environment(\.colorScheme, .dark)
    }
}

struct AccountsView: View {
    @ObservedObject var m: Model
    @ObservedObject private var hidden = HiddenWidgetAccounts.shared
    func best() -> Account? {
        m.codex.filter { !hidden.contains(HiddenWidgetAccounts.codex(home: $0.home, name: $0.name)) }.filter { $0.home != nil && !$0.windows.isEmpty }
            .max { ($0.windows.compactMap(\.left).min() ?? 0) < ($1.windows.compactMap(\.left).min() ?? 0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Аккаунты Codex").font(.title2.bold())
                Spacer()
                Button("Обновить") { m.refreshAll() }
            }
            if let notice = m.claudeNotice { Text(notice).font(.caption).foregroundColor(.secondary) }
            if !hidden.keys.isEmpty { Button("Вернуть скрытые записи (\(hidden.keys.count))") { hidden.restoreAll() } }
            Button {
                inTerminal("python3 " + q(widgetDir + "codex_switch.py"))
            } label: {
                Label("Codex авто — сам выберет аккаунт и переключит при конце лимита", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.controlSize(.large).buttonStyle(.borderedProminent)
            ScrollView {
                VStack(spacing: 10) {
                    if !hidden.contains("claude") {
                        VStack(alignment: .leading, spacing: 8) {
                            AccountView(a: m.claude)
                            Button("Проверить в Claude Code…") { openClaudeUsage() }
                            HideWidgetAccountButton(hidden: hidden, key: "claude", name: "Claude")
                        }.padding(12)
                    }
                    ForEach(m.codex.filter { !hidden.contains(HiddenWidgetAccounts.codex(home: $0.home, name: $0.name)) }) { a in
                        HStack(alignment: .top, spacing: 12) {
                            AccountView(a: a)
                            HideWidgetAccountButton(hidden: hidden, key: HiddenWidgetAccounts.codex(home: a.home, name: a.name), name: a.name)
                            if let h = a.home {
                                Button(a.loggedIn ? "Открыть" : "Войти") {
                                    inTerminal(q(widgetDir + "open_codex.sh") + " " + q((h as NSString).expandingTildeInPath) + " " + q(a.name))
                                }.buttonStyle(.bordered).frame(width: 80)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                    }
                    ForEach(m.apiConnections.filter { !hidden.contains("api:" + $0.id.uuidString) }, id: \.id) { connection in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(connection.name).bold(); Text(connection.model + " · квота API неизвестна").font(.caption).foregroundColor(.secondary) }
                            Spacer()
                            HideWidgetAccountButton(hidden: hidden, key: "api:" + connection.id.uuidString, name: connection.name)
                            Button("Выбрать") { openAPIManager(connection.id) }
                        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            HStack {
                Button { inTerminal(q(widgetDir + "add_account.sh")) } label: { Label("Добавить аккаунт", systemImage: "plus") }
                Button { openAPIManager() } label: { Label("API-подключения…", systemImage: "network") }
                Spacer()
                if let b = best() { Text("Больше всего лимита: \(b.name)").font(.caption).foregroundColor(.secondary) }
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 520)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = Model()
    var timers: [Timer] = []
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: WidgetView(m: model))
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 420),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("LimitsWidget")
        if !window.setFrameUsingName("LimitsWidget"), let s = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: s.maxX - 270, y: s.maxY - 20))
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Обновить", action: #selector(refresh), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        host.menu = menu
        keepOnScreen()
        window.orderFront(nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.keepOnScreen() }
        // Высота окна — под содержимое.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.fit() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.model.refreshClaude() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.model.refreshCodex() })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Лимиты аккаунтов")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("Лимиты аккаунтов")
            button.toolTip = "Показать или скрыть Лимиты"
            button.target = self
            button.action = #selector(statusBarClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.refreshCodex()
        openAccountsWindow = { [weak self] in self?.showAccounts() }
    }

    var accounts: NSWindow?
    func showAccounts() {
        if accounts == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Аккаунты"
            w.contentView = NSHostingView(rootView: AccountsView(m: model))
            w.isReleasedWhenClosed = false
            w.center()
            accounts = w
        }
        model.refreshCodex()
        NSApp.activate(ignoringOtherApps: true)
        accounts?.makeKeyAndOrderFront(nil)
    }

    /// Окно должно быть на включённом экране; иначе — правый верхний угол основного.
    func keepOnScreen() {
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame.insetBy(dx: 40, dy: 40)) }
        if !visible, let s = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: s.maxX - window.frame.width - 20, y: s.maxY - 20))
        }
    }

    func fit() {
        keepOnScreen()
        guard let v = window.contentView else { return }
        let h = v.fittingSize.height
        if abs(window.frame.height - h) > 1 {
            var f = window.frame
            f.origin.y += f.height - h
            f.size.height = h
            window.setFrame(f, display: true)
        }
    }

    @objc func statusBarClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            func action(_ title: String, _ selector: Selector) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            action("Показать Лимиты", #selector(showWidget))
            action("Скрыть виджет", #selector(hideWidget))
            menu.addItem(.separator())
            action("Обновить", #selector(refresh))
            action("Аккаунты…", #selector(openAccounts))
            menu.addItem(.separator())
            action("Выйти из Лимитов", #selector(quitWidget))
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
            }
        } else { toggleWidget() }
    }

    @objc func hideWidget() { window.orderOut(nil) }
    @objc func openAccounts() { showAccounts() }
    @objc func quitWidget() { NSApp.terminate(nil) }
    @objc func showWidget() {
        window.orderOut(nil)
        toggleWidget()
    }

    @objc func toggleWidget() {
        if window.isVisible && window.level == .floating {
            window.orderOut(nil)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            return
        }
        window.level = .floating
        if let button = statusItem.button, let bar = button.window {
            let anchor = bar.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = bar.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            var frame = window.frame
            frame.origin.x = min(max(screen.minX, anchor.midX - frame.width / 2), screen.maxX - frame.width)
            frame.origin.y = min(anchor.minY - 8, screen.maxY) - frame.height
            window.setFrame(frame, display: true)
        }
        keepOnScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func refresh() { model.refreshAll() }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
