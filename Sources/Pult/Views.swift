// Интерфейс «Пульта» в духе Claude Code: тёмный, моноширинный, ⏺/⎿, поле ввода с «>».
import AppKit
import SwiftUI

let mono = Font.system(size: 13, design: .monospaced)
let monoSmall = Font.system(size: 11.5, design: .monospaced)
let accent = Color(red: 0.85, green: 0.47, blue: 0.34)        // «клодовский» оранжевый
let bg = Color(red: 0.09, green: 0.09, blue: 0.10)
let widgetDir = helperDir

func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

func copyText(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

struct ItemView: View {
    @ObservedObject var it: Item
    @ObservedObject var chat: Chat
    var expanded: Bool { it.expanded || chat.expandedTools }

    var copyable: String {
        switch it.kind {
        case .command: return "$ " + it.text + (it.output.isEmpty ? "" : "\n" + it.output)
        default: return it.text
        }
    }

    var body: some View {
        if !it.autoApproved { visibleContent }
    }

    var visibleContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if it.hover && [.user, .agent, .command, .error].contains(it.kind) && !it.text.isEmpty {
                    CopyButton(text: copyable)
                }
            }
            .onHover { it.hover = $0 }
            .contextMenu {
                Button("Скопировать") { copyText(copyable) }
                if it.kind == .command && !it.output.isEmpty { Button("Скопировать только вывод") { copyText(it.output) } }
                Button("Скопировать весь диалог") { copyText(chat.transcript()) }
            }
    }

    @ViewBuilder var content: some View {
        switch it.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Text(it.claude ? "✳>" : ">").foregroundColor(it.claude ? accent : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(it.text).textSelection(.enabled)
                    if !it.images.isEmpty {
                        HStack { ForEach(it.images, id: \.self) { p in
                            if let img = NSImage(contentsOfFile: p) {
                                Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 90).cornerRadius(6)
                            }
                        } }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        case .agent:
            HStack(alignment: .top, spacing: 8) {
                Text(it.claude ? "✳" : "⏺").foregroundColor(it.claude ? accent : .white)
                MarkdownView(text: it.text, directory: chat.cwd)
            }
        case .command:
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    Text(it.claude ? "✳" : "⏺").foregroundColor(!it.done ? .yellow : (it.exitCode ?? 0) == 0 ? .green : .red)
                    (it.claude ? Text(it.text).bold() : (Text(it.legacy ? "MCP" : "Bash").bold() + Text("(" + it.text + ")")))
                        .lineLimit(expanded ? nil : 2).textSelection(.enabled)
                }
                if !it.output.isEmpty {
                    let lines = it.output.split(separator: "\n", omittingEmptySubsequences: false)
                    HStack(alignment: .top, spacing: 8) {
                        Text("  ⎿").foregroundColor(.secondary)
                        Text(expanded ? it.output : lines.suffix(4).joined(separator: "\n"))
                            .foregroundColor(.secondary).font(monoSmall).textSelection(.enabled)
                    }
                    if lines.count > 4 && !expanded {
                        Text("     … ещё \(lines.count - 4) строк — нажми, чтобы развернуть").font(monoSmall).foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { it.expanded.toggle() }
        case .file:
            HStack(alignment: .top, spacing: 8) {
                Text("⏺").foregroundColor(it.done ? .green : .yellow)
                Text("Update").bold() + Text("(" + it.text + ")")
            }
        case .thinking:
            HStack(alignment: .top, spacing: 8) {
                Text("✻").foregroundColor(accent)
                Text(it.text.isEmpty ? "думает…" : it.text).italic().foregroundColor(.secondary).font(monoSmall)
            }
        case .note:
            Text(it.text).italic().foregroundColor(.secondary).font(monoSmall)
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Text("⏺").foregroundColor(.red)
                Text(it.text).foregroundColor(.red.opacity(0.9)).textSelection(.enabled)
            }
        case .question:
            UserQuestionView(item: it, chat: chat)
        case .approval:
            VStack(alignment: .leading, spacing: 8) {
                Text("Нужно разрешение").bold().foregroundColor(accent)
                Text(it.text).textSelection(.enabled)
                if let d = it.decision {
                    Text(d == "decline" ? "✗ отклонено" : "✓ разрешено").foregroundColor(d == "decline" ? .red : .green)
                } else {
                    HStack {
                        Button("Да") { chat.answer(it, "accept") }.keyboardShortcut("y", modifiers: [])
                        Button("Да, до конца сессии") { chat.answer(it, "acceptForSession") }
                        Button("Нет") { chat.answer(it, "decline") }.keyboardShortcut("n", modifiers: [])
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 1))
        }
    }
}

struct CopyButton: View {
    let text: String
    @StateObject private var done = Flag()
    var body: some View {
        Button {
            copyText(text); done.on = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done.on = false }
        } label: {
            Label(done.on ? "скопировано" : "копировать", systemImage: done.on ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color(red: 0.2, green: 0.2, blue: 0.22)))
        }
        .buttonStyle(.plain).foregroundColor(.secondary).padding(2)
    }
}

struct Spinner: View {
    let start: Date
    private let frames = ["✻", "✶", "✳", "✢", "·", "✢", "✳", "✶"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            HStack(spacing: 8) {
                Text(frames[Int(t / 0.15) % frames.count]).foregroundColor(accent)
                Text("Работаю… \(Int(t))s · Esc — прервать").foregroundColor(accent)
            }
        }
    }
}

final class UIState: ObservableObject {
    @Published var draft = ""
    @Published var slashSelection = 0
    @Published var slashDismissed = false
    @Published var showBot = false
    @Published var showWallpaper = false
    @Published var showSettings = false
    @Published var search = ""
}

let relFmt: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "ru_RU"); f.unitsStyle = .short; return f }()

struct Sidebar: View {
    @ObservedObject var chat: Chat
    @ObservedObject var ui: UIState
    var list: [ThreadInfo] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? chat.threads : chat.threads.filter { $0.title.lowercased().contains(q) || $0.account.lowercased().contains(q) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { chat.showSidebar = false } label: { Image(systemName: "chevron.left") }.help("Свернуть вбок (⌘\\)")
                Text("Диалоги").font(.system(size: 13, weight: .bold))
                Spacer()
                Button { chat.loadThreads() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }.help("Новый диалог")
            }.buttonStyle(.borderless)
            TextField("Поиск", text: $ui.search).textFieldStyle(.roundedBorder).font(.system(size: 12))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(list) { t in
                        Button { chat.open(t) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).lineLimit(2).font(.system(size: 12))
                                Text("\(t.account) · " + (Date().timeIntervalSince(t.date) < 60 ? "сейчас" : relFmt.localizedString(for: t.date, relativeTo: Date())))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(t.id == chat.threadId ? accent.opacity(0.25) : Color.clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if list.isEmpty { Text(chat.threads.isEmpty ? "Загружаю…" : "Ничего не найдено").font(.system(size: 11)).foregroundColor(.secondary) }
                }
            }
        }
        .padding(10)
        .frame(width: 270)
        .background(Color(red: 0.065, green: 0.065, blue: 0.075))
    }
}

final class PultWallpaper: ObservableObject {
    static let shared = PultWallpaper()
    private let file = URL(fileURLWithPath: appDataDir + "/background-image")
    @Published var image: NSImage?
    @Published var dimming: Double = UserDefaults.standard.object(forKey: "backgroundDimming") as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(dimming, forKey: "backgroundDimming") }
    }

    init() { image = NSImage(contentsOf: file) }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.title = "Выбрать картинку на фон"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 30 * 1024 * 1024, let picture = NSImage(data: data), picture.isValid else {
                throw NSError(domain: "PultWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Выбери изображение размером до 30 МБ."])
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            image = picture
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось установить фон"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func reset() {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            image = nil
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

struct WallpaperControls: View {
    @ObservedObject var wallpaper = PultWallpaper.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Картинка на фон").font(.headline)
            HStack {
                Button("Выбрать картинку…") { wallpaper.choose() }
                Button("Сбросить") { wallpaper.reset() }.disabled(wallpaper.image == nil)
            }
            if wallpaper.image != nil {
                HStack {
                    Text("Затемнение")
                    Slider(value: $wallpaper.dimming, in: 0.2...0.9)
                    Text("\(Int(wallpaper.dimming * 100))%").monospacedDigit().frame(width: 40)
                }
            }
        }
    }
}

struct PultBackground: View {
    @ObservedObject var wallpaper = PultWallpaper.shared
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                bg
                if let image = wallpaper.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    Color.black.opacity(wallpaper.dimming)
                }
            }
        }.allowsHitTesting(false)
    }
}

struct ProviderIcon: View {
    let claude: Bool
    private static let gptIcon = NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
    private static let claudeIcon = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
    var body: some View {
        Image(nsImage: claude ? Self.claudeIcon : Self.gptIcon)
            .resizable().interpolation(.high).scaledToFit().frame(width: 18, height: 18)
            .saturation(0)
            .opacity(0.5)
            .accessibilityLabel(claude ? "Claude" : "GPT")
    }
}

struct ChatView: View {
    @ObservedObject var chat: Chat
    @ObservedObject var proxy = Proxy.shared
    @StateObject private var ui = UIState()
    @StateObject private var promptCoach = PromptCoach()
    @ObservedObject private var apiStore = APIConnectionStore.shared

    func pct(_ a: Account) -> String { chat.remaining(a).map { "\(Int($0))%" } ?? "?" }

    var topBar: some View {
        HStack(spacing: 12) {
            Button { chat.showSidebar.toggle() } label: { PultIcon(symbol: "sidebar.left") }
                .buttonStyle(PultIconStyle(selected: chat.showSidebar)).accessibilityLabel("Показать диалоги")
                .keyboardShortcut("\\", modifiers: .command).help("Диалоги (⌘\\)")
            Text("✻ Пульт").bold().foregroundColor(accent)
            Text(chat.items.contains(where: { $0.kind == .question && $0.decision == nil }) ? "Ждёт ответа" : (chat.busy ? "● Работает" : "Готов"))
                .font(monoSmall).foregroundColor(chat.busy ? .green : .secondary)
            Menu {
                ForEach(Array(chat.accounts.enumerated()), id: \.offset) { i, a in
                    Button((chat.target == "codex" && i == chat.current ? "● " : "   ") + a.name + " — осталось " + pct(a)) { chat.chooseCodex(i) }.disabled(chat.busy || chat.nativeCLIIsRunning)
                }
                Divider()
                Button("Войти / открыть аккаунт в терминале…") {
                    Terminal.run(shq(widgetDir + "open_codex.sh") + " " + shq(chat.account.home) + " " + shq(chat.account.name))
                }
                Button("Добавить аккаунт…") { Terminal.run(shq(widgetDir + "add_account.sh")) }
                Button("Claude CLI") { chat.target = "claude" }.disabled(chat.busy || chat.nativeCLIIsRunning)
                Divider()
                ForEach(apiStore.connections) { connection in
                    Button((chat.target == connection.target ? "● " : "") + connection.name + " · API") { chat.chooseAPI(connection) }.disabled(chat.busy || chat.nativeCLIIsRunning)
                }
                Button("Добавить / изменить API…") { chat.showAPIConnections = true }

                Button("Обновить список и лимиты") { chat.accounts = loadAccounts(); chat.refreshAllLimits() }
            } label: {
                Text(chat.connecting && !chat.isAPI ? "подключаю…" : chat.isAPI ? chat.connectionTitle + " · API" : "\(chat.connectionTitle) · \(pct(chat.account))")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Новый") { chat.newChat() }.keyboardShortcut("n")
            Button { chat.askClaude() } label: { Text("✳ Claude").foregroundColor(accent) }
                .help("Отдать этот диалог Codex Claude — он разберётся прямо здесь. Правый клик — ещё")
                .disabled(chat.items.isEmpty || chat.busy)
                .contextMenu {
                    Button("Открыть разговор с Claude в Terminal") { chat.claudeInTerminal() }
                    Button("Начать с Claude заново (новый разговор)") { chat.resetClaude() }
                }
            Button { ui.showWallpaper.toggle() } label: { PultIcon(symbol: "photo") }
                .buttonStyle(PultIconStyle(selected: ui.showWallpaper)).accessibilityLabel("Фон окна")
                .help("Настроить фон")
                .popover(isPresented: $ui.showWallpaper) {
                    WallpaperControls().padding(16).frame(width: 300)
                }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Лимиты.app").path)) } label: { PultIcon(symbol: "gauge.with.dots.needle.50percent") }
                .buttonStyle(PultIconStyle()).help("Показать лимиты аккаунтов").accessibilityLabel("Лимиты аккаунтов")
            Button { ui.showSettings = true } label: { PultIcon(symbol: "slider.horizontal.3") }
                .buttonStyle(PultIconStyle()).help("Настройки Пульта").accessibilityLabel("Настройки Пульта")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    var statusLine: some View {
        let l = chat.limits[chat.account.home]
        let five = l?.five.map { "5ч \(Int(100 - $0))%" } ?? "5ч ?"
        let week = l?.week.map { "нед \(Int(100 - $0))%" } ?? "нед ?"
        let dir = chat.cwd.replacingOccurrences(of: homeDir, with: "~")
        return HStack(spacing: 10) {
            Text(chat.connectionTitle); Text("·"); Text(chat.isAPI ? (chat.selectedAPI?.model ?? "—") : chat.model); Text("·");
            if chat.isAPI { Label("Квота API неизвестна", systemImage: "gauge.with.dots.needle.50percent") } else { Text(five); Text(week) }
            Text("·"); Text(dir).lineLimit(1).truncationMode(.middle)
            Spacer()
            if proxy.enabled { Text("VLESS").foregroundColor(proxy.status.hasPrefix("включён") ? .green : .orange) }
            if !chat.isAPI && chat.autoSwitch { Text("авто ⇄").foregroundColor(.secondary) }
        }
        .font(monoSmall).foregroundColor(.secondary)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    var body: some View {
        HStack(spacing: 0) {
            if chat.showSidebar { Sidebar(chat: chat, ui: ui); Divider().opacity(0.3) }
            else {
                Button { chat.showSidebar = true } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                        Text("Диалоги").font(.system(size: 11)).fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 60)
                        Spacer()
                    }.padding(.top, 14).frame(width: 22).frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundColor(.secondary).background(Color(red: 0.065, green: 0.065, blue: 0.075)).help("Показать диалоги")
                Divider().opacity(0.3)
            }
            main
            if promptCoach.isOpen {
                Divider().opacity(0.3)
                PromptCoachView(coach: promptCoach, chat: chat, ui: ui)
            }
        }
        .frame(minWidth: promptCoach.isOpen ? 1120 : 640)
        .onDisappear { promptCoach.close() }
        .background(PultBackground())
        .preferredColorScheme(.dark)
    }

    var main: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            ScrollViewReader { sv in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("✻ Добро пожаловать в Пульт").bold().foregroundColor(accent)
                                Text("Codex на всех твоих аккаунтах. Кончится лимит — сам продолжит на другом.").foregroundColor(.secondary)
                                Text("✳ Claude — отдать диалог Claude, если Codex тупит. API — через меню аккаунтов.").foregroundColor(.secondary)
                            }
                            .padding(12)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.6), lineWidth: 1))
                        }
                        ForEach(chat.items.filter { !chat.focusedConversation || [.user, .agent, .error, .question, .approval].contains($0.kind) }) { ItemView(it: $0, chat: chat).id($0.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.items.count) { _ in withAnimation { sv.scrollTo("bottom") } }
                .onReceive(Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()) { _ in
                    if chat.busy { sv.scrollTo("bottom") }
                }
            }
            if chat.nativeCLIIsRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Выполняется команда CLI…").font(monoSmall)
                    Button("Остановить") { chat.interrupt() }.buttonStyle(.borderless)
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 6)
            }
            if chat.busy, let s = chat.turnStarted { Spinner(start: s).padding(.horizontal, 16).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading) }
            if !chat.attachments.isEmpty {
                HStack { ForEach(chat.attachments, id: \.self) { p in
                    HStack(spacing: 4) {
                        Text("🖼 " + (p as NSString).lastPathComponent).font(monoSmall).lineLimit(1)
                        Button("✕") { chat.attachments.removeAll { $0 == p } }.buttonStyle(.borderless)
                    }.padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
                }; Spacer() }.padding(.horizontal, 14).padding(.bottom, 4)
            }
            if !chat.pendingMessages.isEmpty { MessageQueueView(chat: chat, ui: ui) }
            if ui.draft.hasPrefix("/"), !ui.draft.contains(where: { $0.isWhitespace }), !ui.slashDismissed {
                SlashSuggestions(chat: chat, ui: ui)
            }
            HStack(alignment: .top, spacing: 8) {
                Button {
                    if !chat.busy && !chat.nativeCLIIsRunning { chat.target = chat.target == "claude" ? "codex" : "claude" }
                } label: {
                    Group { if chat.isAPI { PultIcon(symbol: "network") } else { ProviderIcon(claude: chat.target == "claude") } }
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(chat.target == "claude" ? "Claude → GPT" : "GPT → Claude")
                Button { pickImages(chat) } label: { PultIcon(symbol: "paperclip") }.buttonStyle(PultIconStyle()).help("Картинка (или перетащи / ⇧⌘V)")
                Button {
                    promptCoach.open(draft: ui.draft, chat: chat)
                } label: { PultIcon(symbol: "wand.and.stars") }
                .buttonStyle(PultIconStyle(selected: promptCoach.isOpen))
                .accessibilityLabel("Улучшить промпт")
                .help("Суперпромпт: прочитать диалог, уточнить и улучшить запрос")
                .disabled(ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.busy || chat.connecting || chat.nativeCLIIsRunning)
                Text(">").foregroundColor(chat.target == "claude" ? accent : .secondary)
                TextField(chat.busy ? "добавить в очередь…" : (chat.isAPI ? "Напиши в API…" : chat.target == "claude" ? "Напиши Claude…" : "Напиши задачу…"), text: $ui.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...10)
                    .onChange(of: ui.draft) { _ in ui.slashSelection = 0; ui.slashDismissed = false }
                    .onKeyPress(.tab) {
                        guard ui.draft.hasPrefix("/"), !ui.draft.contains(where: { $0.isWhitespace }) else { return .ignored }
                        let matches = chat.matchingCommands(ui.draft)
                        guard !matches.isEmpty else { return .ignored }
                        ui.draft = "/" + matches[min(ui.slashSelection, matches.count - 1)].name + " "
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard ui.draft.hasPrefix("/"), !ui.slashDismissed else { return .ignored }
                        let count = chat.matchingCommands(ui.draft).count
                        guard count > 0 else { return .ignored }
                        ui.slashSelection = (ui.slashSelection + 1) % count
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard ui.draft.hasPrefix("/"), !ui.slashDismissed else { return .ignored }
                        let count = chat.matchingCommands(ui.draft).count
                        guard count > 0 else { return .ignored }
                        ui.slashSelection = (ui.slashSelection + count - 1) % count
                        return .handled
                    }
                    .onSubmit {
                        let matches = chat.matchingCommands(ui.draft)
                        let exact = matches.contains { ui.draft == "/" + $0.name }
                        if !matches.isEmpty, !exact, !ui.slashDismissed {
                            ui.draft = "/" + matches[min(ui.slashSelection, matches.count - 1)].name + " "
                        } else {
                            let t = ui.draft; ui.draft = ""; chat.send(t)
                        }
                    }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 6)
            HStack {
                Button { chat.toggleAutoApprove() } label: {
                    Label("Подтверждать за меня" + (chat.autoApprove ? ": вкл" : ": выкл"),
                          systemImage: chat.autoApprove ? "checkmark.shield.fill" : "checkmark.shield")
                        .foregroundColor(chat.autoApprove ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Автоматически подтверждать команды, файлы, дополнительные права и обычные подтверждения MCP. Настройка сохраняется. Вопросы и ввод недостающих данных остаются ручными.")
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.bottom, 6)
            HStack(spacing: 12) {
                let input = chat.target == "claude" ? chat.claudeInputTokens : chat.codexInputTokens
                let output = chat.target == "claude" ? chat.claudeOutputTokens : chat.codexOutputTokens
                let cached = chat.target == "claude" ? chat.claudeCachedTokens : chat.codexCachedTokens
                Text((chat.isAPI ? "Токены API-запроса · вход: " : chat.target == "claude" ? "Токены хода · вход: " : "Токены диалога · вход: ") + (input.map(String.init) ?? "—"))
                Text("выход: " + (output.map(String.init) ?? "—"))
                Text("кэш: " + (cached.map(String.init) ?? "—"))
                Spacer()
            }.font(monoSmall).foregroundColor(.secondary).padding(.horizontal, 16).padding(.bottom, 5)
            statusLine
        }
        .font(mono)
        .preferredColorScheme(.dark)
        .onExitCommand {
            if ui.draft.hasPrefix("/"), !ui.slashDismissed { ui.slashDismissed = true }
            else { chat.interrupt() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    guard let u = url, ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(u.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { chat.attachments.append(u.path) }
                }
            }
            return true
        }
        .onChange(of: apiStore.revision) { _ in chat.apiConfigurationDidChange() }
        .sheet(isPresented: $chat.showAPIConnections) { APIConnectionsView(store: apiStore, onSelect: { chat.chooseAPI($0) }, canSelect: !chat.busy && !chat.nativeCLIIsRunning) }
        .onChange(of: chat.showCommandSettings) { show in if show { ui.showSettings = true; chat.showCommandSettings = false } }
        .sheet(isPresented: $chat.showModelChoices) { ModelChoicesView(chat: chat) }
        .sheet(isPresented: $chat.showClaudeConversations) { ClaudeConversationsView(chat: chat) }
        .alert(item: $chat.pendingNativeAction) { action in
            Alert(title: Text(action.title), message: Text(action.message), primaryButton: .destructive(Text("Выполнить")) { action.perform() }, secondaryButton: .cancel())
        }
        .sheet(isPresented: $ui.showSettings) { SettingsView(chat: chat, close: { ui.showSettings = false }) }
    }
}

struct SettingsView: View {
    @ObservedObject var wallpaper = PultWallpaper.shared
    @ObservedObject var chat: Chat
    @ObservedObject var proxy = Proxy.shared
    let close: () -> Void

    var body: some View {
        Form {
            Section("Картинка на фон") {
                HStack {
                    Button("Выбрать картинку…") { wallpaper.choose() }
                    Button("Сбросить") { wallpaper.reset() }.disabled(wallpaper.image == nil)
                }
                if wallpaper.image != nil {
                    HStack {
                        Text("Затемнение")
                        Slider(value: $wallpaper.dimming, in: 0.2...0.9)
                        Text("\(Int(wallpaper.dimming * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Text("Картинка сохраняется в Пульте и остаётся после перезапуска.").font(.caption).foregroundColor(.secondary)
            }
            Section("Codex") {
                TextField("Модель Codex", text: $chat.model)
                TextField("Модель Claude (пусто — по умолчанию CLI)", text: $chat.claudeModel)
                HStack {
                    TextField("Рабочая папка", text: $chat.cwd)
                    Button("…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { chat.cwd = u.path; chat.newChat() }
                    }
                }
                Picker("Песочница", selection: $chat.sandbox) {
                    Text("только чтение").tag("read-only")
                    Text("запись в папке проекта").tag("workspace-write")
                    Text("полный доступ").tag("danger-full-access")
                }
                Toggle("Авто-переключение аккаунтов (конец лимита и заранее на 5%)", isOn: $chat.autoSwitch)
                Toggle("Уведомлять в macOS, если ход длился > 1 мин и окно не активно", isOn: $chat.notifyTelegram)
            }
            Section("VLESS только для Пульта") {
                Toggle("Подключаться через VLESS", isOn: $proxy.enabled).disabled(!proxy.available && !proxy.enabled)
                if proxy.names.count > 1 {
                    Picker("Сервер", selection: $proxy.selected) {
                        ForEach(Array(proxy.names.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
                    }
                }
                Text("Статус: \(proxy.status)").foregroundColor(.secondary)
                if !proxy.available {
                    Text("Положи ссылку vless://… в ~/Library/Application Support/PultPublic/vless.txt — и включи. Действует только на Codex/Claude, запущенные из Пульта; после переключения выбери аккаунт заново.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            HStack { Spacer(); Button("Готово", action: close).keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 650)
    }
}

let attachDir = appDataDir + "/attachments"

func pickImages(_ chat: Chat) {
    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.image]
    if p.runModal() == .OK { chat.attachments += p.urls.map(\.path) }
}

/// ⇧⌘V: картинка из буфера (скриншот) → файл → вложение.
func pasteImage(_ chat: Chat) {
    let pb = NSPasteboard.general
    if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
        chat.attachments += urls.filter { NSImage(contentsOf: $0) != nil }.map(\.path); return
    }
    guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: attachDir, withIntermediateDirectories: true)
    let path = attachDir + "/paste-\(Int(Date().timeIntervalSince1970)).png"
    if (try? png.write(to: URL(fileURLWithPath: path))) != nil { chat.attachments.append(path) }
}
