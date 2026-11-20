// Окно «Пульта»: боковая панель с открытыми чатами и историей, лента, поле ввода, быстрый переход.
import AppKit
import SwiftUI

let panel = Color(red: 0.062, green: 0.062, blue: 0.072)
let card = Color.white.opacity(0.055)
let hairline = Color.white.opacity(0.09)
let uiFont = Font.system(size: 12.5)
let uiSmall = Font.system(size: 11)

// MARK: мелкие детали

struct StatusDot: View {
    let status: ChatStatus
    var size: CGFloat = 8
    var body: some View {
        if status == .working || status == .connecting {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let phase = (sin(ctx.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                Circle().fill(status.color).frame(width: size, height: size)
                    .overlay(Circle().stroke(status.color.opacity(0.55 * (1 - phase)), lineWidth: 2).scaleEffect(1 + phase * 0.9))
            }.frame(width: size + 6, height: size + 6)
        } else {
            Circle().fill(status.color).frame(width: size, height: size).frame(width: size + 6, height: size + 6)
        }
    }
}

struct StatusPill: View {
    let status: ChatStatus
    var body: some View {
        HStack(spacing: 4) {
            StatusDot(status: status, size: 7)
            Text(status.label).font(uiSmall)
        }
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 2)
        .background(Capsule().fill(status.color.opacity(status == .idle ? 0.25 : 0.16)))
        .foregroundColor(status == .idle ? .secondary : status.color)
    }
}

/// Кнопка-«чип» в строке под полем ввода.
struct Chip: View {
    let icon: String
    var text: String = ""
    var active = false
    var tint: Color = accent
    @StateObject private var hover = Flag()
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
            if !text.isEmpty { Text(text).font(uiSmall).lineLimit(1) }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .foregroundColor(active ? tint : Color.primary.opacity(0.75))
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? tint.opacity(0.16) : Color.white.opacity(hover.on ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

struct HoverRow<Content: View>: View {
    var selected = false
    let content: (Bool) -> Content
    @StateObject private var hover = Flag()
    init(selected: Bool = false, @ViewBuilder content: @escaping (Bool) -> Content) { self.selected = selected; self.content = content }
    var body: some View {
        content(hover.on)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? accent.opacity(0.2) : Color.white.opacity(hover.on ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text).font(uiFont)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(red: 0.16, green: 0.16, blue: 0.18)).shadow(color: .black.opacity(0.5), radius: 12, y: 4))
            .overlay(Capsule().stroke(hairline))
            .padding(.top, 14)
    }
}

// MARK: корень окна

struct RootView: View {
    @ObservedObject var mods = ModStore.shared
    @ObservedObject var workspace: Workspace
    @ObservedObject var updater = Updater.shared

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if workspace.sidebar { SidebarView(workspace: workspace, chat: workspace.active); Divider().opacity(0.25) }
                if workspace.showTeamChat && mods.mainPanelID == nil { TeamChatPanel(workspace: workspace); Divider().opacity(0.25) }
                if let key = mods.leftPanelID { ModDockView(key: key, placement: "left").frame(width: 330); Divider().opacity(0.25) }
                if let key = mods.mainPanelID {
                    ModDockView(key: key, placement: "main")
                } else { ChatView(chat: workspace.active, workspace: workspace).id(workspace.active.sessionID) }
                if let key = mods.rightPanelID { Divider().opacity(0.25); ModDockView(key: key, placement: "right").frame(width: 360) }
                if workspace.showTeamTasks && mods.mainPanelID == nil { Divider().opacity(0.25); TeamTasksPanel(workspace: workspace) }
            }
            if let toast = workspace.toast { ToastView(text: toast).transition(.opacity) }
            if workspace.showPalette { PaletteView(workspace: workspace) }
        }
        .sheet(isPresented: Binding(get: { mods.panelID != nil }, set: { if !$0 { mods.panelID = nil } })) {
            if let key = mods.panelID { ModDockView(key: key.contains("/") ? key : key + "/main", placement: "sheet").frame(width: 800, height: 650) }
        }
        .sheet(isPresented: $workspace.showTeamRoom) { TeamRoomView(workspace: workspace) }
        .sheet(isPresented: $workspace.showGuide) { GuideView() }
        .background(PultBackground())
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: workspace.toast)
    }
}

// MARK: боковая панель

struct OpenChatRow: View {
    @ObservedObject var chat: Chat
    let index: Int
    let selected: Bool
    let workspace: Workspace
    var body: some View {
        HoverRow(selected: selected) { hover in
            HStack(spacing: 6) {
                StatusDot(status: chat.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundColor(chat.status.needsYou ? accent : .secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                if hover {
                    Button { workspace.close(chat) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16) }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("Закрыть чат (⌘W)")
                } else if index < 9 {
                    Text("⌘\(index + 1)").font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .onTapGesture { workspace.activate(chat) }
        .contextMenu {
            Button("Закрыть чат") { workspace.close(chat) }
            if chat.busy { Button("Остановить") { chat.interrupt() } }
        }
    }
    var subtitle: String {
        let status = chat.status
        let place = (chat.cwd as NSString).lastPathComponent
        if status == .idle { return chat.providerLabel + " · " + place }
        if status == .working, !chat.subagents.isEmpty { return "Работает · субагентов: \(chat.subagents.count)" }
        return status.label + " · " + chat.providerLabel
    }
}

struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var chat: Chat
    @ObservedObject private var preferences = ConversationPreferences.shared
    @ObservedObject private var limits = LimitsStore.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var telegram = TelegramBridge.shared
    @ObservedObject private var trash = ChatTrash.shared
    @StateObject private var showingTrash = Flag()
    var ui: UIState { chat.ui }

    var history: [(String, [ThreadInfo])] {
        let q = workspace.search.trimmingCharacters(in: .whitespaces).lowercased()
        let open = Set(workspace.chats.map(\.conversationKey))
        let source = showingTrash.on ? trash.entries.map(\.thread) : chat.threads
        let all = source.filter { (showingTrash.on || !trash.ids.contains($0.id)) && !open.contains($0.id) && (q.isEmpty || $0.title.lowercased().contains(q) || $0.account.lowercased().contains(q) || $0.cwd.lowercased().contains(q)) }
        let calendar = Calendar.current
        var groups: [(String, [ThreadInfo])] = []
        func add(_ name: String, _ rows: [ThreadInfo]) { if !rows.isEmpty { groups.append((name, rows)) } }
        let pinned = all.filter { preferences.pins.contains($0.id) }
        let rest = all.filter { !preferences.pins.contains($0.id) }
        add("Закреплённые", pinned)
        add("Сегодня", rest.filter { calendar.isDateInToday($0.date) })
        add("Вчера", rest.filter { calendar.isDateInYesterday($0.date) })
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        add("На этой неделе", rest.filter { !calendar.isDateInToday($0.date) && !calendar.isDateInYesterday($0.date) && $0.date > weekAgo })
        add("Раньше", rest.filter { $0.date <= weekAgo })
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Button { workspace.showPalette = true } label: { PultIcon(symbol: "magnifyingglass") }.buttonStyle(PultIconStyle()).help("Быстрый переход (⌘K)")
                Button { workspace.newChat() } label: { PultIcon(symbol: "square.and.pencil") }.buttonStyle(PultIconStyle()).help("Новый чат (⌘N)")
                Button { workspace.sidebar = false } label: { PultIcon(symbol: "sidebar.left") }.buttonStyle(PultIconStyle()).help("Скрыть панель (⌘\\)")
            }
            .padding(.horizontal, 8).padding(.top, 6).frame(height: 40)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Открытые чаты", extra: workspace.waiting > 0 ? "ждут тебя: \(workspace.waiting)" : nil)
                    ForEach(Array(workspace.chats.enumerated()), id: \.element.sessionID) { index, item in
                        OpenChatRow(chat: item, index: index, selected: item.sessionID == workspace.activeID, workspace: workspace)
                    }
                    Button { workspace.newChat() } label: {
                        HoverRow { _ in
                            HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 11)).frame(width: 14); Text("Новый чат").font(uiFont); Spacer() }.foregroundColor(.secondary)
                        }
                    }.buttonStyle(.plain)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("Поиск по истории", text: $workspace.search).textFieldStyle(.plain).font(uiFont)
                        if !workspace.search.isEmpty { Button { workspace.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(.secondary) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(card))
                    .padding(.top, 12).padding(.bottom, 2)

                    HStack {
                        Button { showingTrash.on.toggle() } label: {
                            Label(showingTrash.on ? "Вернуться к истории" : "Корзина (\(trash.entries.count))", systemImage: "trash")
                        }.buttonStyle(.plain)
                        Spacer()
                        if !showingTrash.on {
                            Menu {
                                Button("Убрать чаты старше 30 дней") {
                                    let cutoff = Date().addingTimeInterval(-30 * 86400)
                                    let open = Set(workspace.chats.map(\.conversationKey))
                                    trash.move(chat.threads.filter { $0.date < cutoff && !open.contains($0.id) })
                                    chat.loadThreads()
                                }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        }
                    }.font(uiSmall).foregroundColor(.secondary).padding(.vertical, 6)
                    ForEach(history, id: \.0) { name, rows in
                        sectionTitle(name)
                        ForEach(rows) { thread in
                            Button { if showingTrash.on { trash.restore(thread.id); chat.loadThreads() }; workspace.open(thread) } label: {
                                HoverRow { _ in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(thread.title).font(uiFont).lineLimit(1)
                                        Text(thread.account + " · " + (Date().timeIntervalSince(thread.date) < 60 ? "сейчас" : relFmt.localizedString(for: thread.date, relativeTo: Date())) + (thread.cwd.isEmpty ? "" : " · " + (thread.cwd as NSString).lastPathComponent))
                                            .font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                            }.buttonStyle(.plain)
                            .contextMenu {
                                if showingTrash.on {
                                    Button("Восстановить") { trash.restore(thread.id); chat.loadThreads() }
                                } else {
                                    Button("Убрать в корзину", role: .destructive) { trash.move([thread]); chat.loadThreads() }
                                }
                                Button(preferences.pins.contains(thread.id) ? "Открепить" : "Закрепить сверху") { preferences.togglePin(thread.id) }
                                Button("Открыть в новом чате") { workspace.newChat(inherit: false).open(thread) }
                            }
                        }
                    }
                    if history.isEmpty { Text(chat.threads.isEmpty ? "История загружается…" : "Ничего не найдено").font(uiSmall).foregroundColor(.secondary).padding(8) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }

            Divider().opacity(0.25)
            footer
        }
        .frame(width: 272)
        .background(panel.opacity(0.94))

    }

    func sectionTitle(_ text: String, extra: String? = nil) -> some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary.opacity(0.8))
            Spacer()
            if let extra = extra { Text(extra).font(.system(size: 10, weight: .medium)).foregroundColor(accent) }
        }.padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
    }

    func quotaRow(_ label: String, used: Double?, reset: Double?) -> some View {
        let left = used.map { max(0, min(100, 100 - $0)) }
        return HStack(spacing: 5) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 23, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if let left = left { Capsule().fill(barColor(left)).frame(width: geometry.size.width * CGFloat(left / 100)) }
                }
            }.frame(height: 4)
            Text(left.map { "\(Int($0))%" } ?? "—").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 32, alignment: .trailing)
        }.help(reset.map { "Сброс: " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Время сброса пока неизвестно")
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if updater.available > 0 || updater.working {
                Button { updater.install() } label: {
                    HStack(spacing: 6) {
                        if updater.working { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) } else { Image(systemName: "arrow.down.circle.fill") }
                        Text(updater.working ? "Обновляюсь…" : "Обновить Пульт (\(updater.available))").font(uiFont)
                        Spacer()
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(accent.opacity(0.2))).foregroundColor(accent)
                }.buttonStyle(.plain).disabled(updater.working).help(updater.notes.joined(separator: "\n"))
            }
            ForEach(Array(chat.accounts.enumerated()), id: \.element.id) { index, account in
                let quota = limits.limits[account.home]
                Button { if !chat.busy && !chat.nativeCLIIsRunning { chat.chooseCodex(index) } } label: {
                    HStack(spacing: 8) {
                        Text(account.name).font(uiSmall).lineLimit(1).frame(width: 62, alignment: .leading)
                            .foregroundColor(chat.target == "codex" && index == chat.current ? .primary : .secondary)
                        VStack(spacing: 4) {
                            quotaRow("5ч", used: quota?.five, reset: quota?.fiveReset)
                            quotaRow("Нед", used: quota?.week, reset: quota?.weekReset)
                        }
                    }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Остаток за 5 часов и неделю у «\(account.name)». Нажми — перейти на аккаунт")
            }
            ModActionButtons(location: "sidebar")
            Button { workspace.showTeamRoom = true } label: {
                Label("Общий проект", systemImage: "person.2.fill").font(uiFont)
            }.buttonStyle(.plain).padding(.vertical, 6)
            HStack(spacing: 8) {
                ModActionButtons(location: "statusbar")
                if telegram.configured {
                    Label(telegram.paired ? "Telegram" : "Telegram: нужен код", systemImage: "paperplane.fill").font(.system(size: 10.5))
                        .foregroundColor(telegram.status.hasPrefix("работает") ? Color(red: 0.4, green: 0.7, blue: 1) : .orange)
                }
                Spacer()
                Text("v\(updater.version)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.6))
                Button { ui.showSettings = true } label: { PultIcon(symbol: "gearshape") }.buttonStyle(PultIconStyle()).help("Настройки (⌘,)").keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    func barColor(_ left: Double?) -> Color {
        guard let left = left else { return .gray }
        return left < 10 ? Color(red: 0.95, green: 0.35, blue: 0.35) : left < 30 ? .orange : Color(red: 0.35, green: 0.8, blue: 0.5)
    }
}

// MARK: выбор модели

struct ModelPicker: View {
    @ObservedObject var chat: Chat
    @ObservedObject private var catalog = ModelCatalog.shared
    var claude: Bool { chat.target == "claude" }
    var models: [ModelChoice] { claude ? ModelCatalog.claude : catalog.codex }
    var current: String { claude ? chat.claudeModel : chat.model }
    var efforts: [String] {
        if claude { return ModelCatalog.claudeEfforts }
        let own = catalog.codex.first { $0.id == chat.model }?.efforts ?? []
        return own.isEmpty ? ["low", "medium", "high", "xhigh"] : own
    }
    var effort: String? { claude ? chat.claudeEffort : chat.reasoningEffort }
    static let effortNames = ["none": "без", "minimal": "мин", "low": "низкая", "medium": "средняя", "high": "высокая", "xhigh": "очень высокая", "max": "максимум"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(claude ? "Модель Claude" : "Модель Codex").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !claude { Button { catalog.load(chat.client, force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundColor(.secondary).help("Обновить список") }
            }
            if models.isEmpty {
                HStack { if catalog.loading { ProgressView().controlSize(.small) }; Text(catalog.loading ? "Загружаю список…" : "Список появится, когда Codex подключится.").font(uiSmall).foregroundColor(.secondary) }
                    .onAppear { catalog.load(chat.client) }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(models) { model in
                        Button { if claude { chat.claudeModel = model.id } else { chat.model = model.id; if let e = chat.reasoningEffort, !model.efforts.isEmpty, !model.efforts.contains(e) { chat.reasoningEffort = nil } } } label: {
                            HoverRow(selected: current == model.id) { _ in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: current == model.id ? "checkmark.circle.fill" : "circle").foregroundColor(current == model.id ? accent : .secondary.opacity(0.5)).font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name).font(.system(size: 12.5, weight: .medium))
                                        if !model.description.isEmpty { Text(model.description).font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if !claude, !models.contains(where: { $0.id == chat.model }), !models.isEmpty {
                        Text("Сейчас выбрана «\(chat.model)» — её нет в списке этого аккаунта.").font(.system(size: 10.5)).foregroundColor(.orange).padding(6)
                    }
                }
            }.frame(maxHeight: 280)
            Divider().opacity(0.3)
            Text("Глубина размышлений").font(uiSmall).foregroundColor(.secondary)
            HStack(spacing: 4) {
                effortButton(nil, "авто")
                ForEach(efforts, id: \.self) { e in effortButton(e, Self.effortNames[e] ?? e) }
            }
            Toggle(isOn: Binding(get: { claude ? chat.claudeFast : chat.codexFast }, set: { if claude { chat.claudeFast = $0 } else { chat.codexFast = $0 } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("⚡ Быстрый режим").font(uiFont)
                    Text("Ответы быстрее, расход лимита выше. Зависит от тарифа.").font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small)
            Text("Выбор сохраняется и действует со следующего сообщения.").font(.system(size: 10.5)).foregroundColor(.secondary)
        }
        .padding(14).frame(width: 340)
    }

    func effortButton(_ value: String?, _ name: String) -> some View {
        Button { if claude { chat.claudeEffort = value } else { chat.reasoningEffort = value } } label: {
            Text(name).font(.system(size: 10.5)).padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(effort == value ? accent.opacity(0.25) : Color.white.opacity(0.06)))
                .foregroundColor(effort == value ? accent : .primary)
        }.buttonStyle(.plain)
    }
}

extension Chat {
    /// Короткое имя модели для чипа под полем ввода.
    var modelLabel: String {
        if isAPI { return selectedAPI?.model ?? "API" }
        if target == "claude" { return ModelCatalog.claude.first { $0.id == claudeModel }?.name ?? (claudeModel.isEmpty ? "По умолчанию" : claudeModel) }
        return ModelCatalog.shared.codex.first { $0.id == model }?.name ?? model
    }
}

// MARK: чат

struct ChatView: View {
    @ObservedObject var chat: Chat
    @ObservedObject var workspace: Workspace
    @ObservedObject var ui: UIState
    @ObservedObject var proxy = Proxy.shared
    @StateObject private var promptCoach = PromptCoach()
    @StateObject private var follow = FollowState()
    @ObservedObject private var preferences = ConversationPreferences.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject var bot = BotStatus.shared
    @ObservedObject var voice = Voice.shared
    @FocusState private var inputFocused: Bool

    init(chat: Chat, workspace: Workspace) { self.chat = chat; self.workspace = workspace; self.ui = chat.ui }

    func pct(_ a: Account) -> String { chat.remaining(a).map { "\(Int($0))%" } ?? "?" }
    var idle: Bool { !chat.busy && !chat.nativeCLIIsRunning }

    var body: some View {
        HStack(spacing: 0) {
            main
            if promptCoach.isOpen {
                Divider().opacity(0.3)
                PromptCoachView(coach: promptCoach, chat: chat, ui: ui)
            }
        }
        .frame(minWidth: promptCoach.isOpen ? 1120 : 480)
        .onDisappear { promptCoach.close() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { inputFocused = true } }
    }

    // MARK: верхняя строка

    var topBar: some View {
        HStack(spacing: 10) {
            if !workspace.sidebar {
                Color.clear.frame(width: 62, height: 1)                      // место под кнопки окна
                Button { workspace.sidebar = true } label: { PultIcon(symbol: "sidebar.left") }.buttonStyle(PultIconStyle()).help("Показать панель (⌘\\)")
                if workspace.waiting > 0 { Text("ждут тебя: \(workspace.waiting)").font(uiSmall).foregroundColor(accent) }
            }
            Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            StatusPill(status: chat.status)
            Spacer(minLength: 8)
            ModActionButtons(location: "toolbar")
            Button { workspace.showTeamChat.toggle() } label: { Image(systemName: "bubble.left.and.bubble.right") }.help("Чат команды")
            Button { workspace.showTeamTasks.toggle() } label: { Image(systemName: "checklist") }.help("Общая доска задач")
            accountMenu
            Button { chat.askClaude() } label: { Chip(icon: "sparkle", text: "Отдать Claude") }
                .buttonStyle(.plain)
                .help("Codex не справился? Claude прочитает этот диалог и разберётся прямо здесь. Правый клик — ещё")
                .disabled(chat.items.isEmpty || chat.busy || chat.target == "claude")
                .opacity(chat.target == "claude" || chat.items.isEmpty ? 0.35 : 1)
                .contextMenu {
                    Button("Открыть разговор с Claude в Terminal") { chat.claudeInTerminal() }
                    Button("Начать с Claude заново (новый разговор)") { chat.resetClaude() }
                }
            Button { ui.showBot = true } label: {
                Chip(icon: "chart.line.uptrend.xyaxis", text: "Бот", active: bot.alarm, tint: .red)
            }.buttonStyle(.plain).help("Торговый бот: состояние и выкладка")
            Button { workspace.sidebar.toggle() } label: { EmptyView() }.keyboardShortcut("\\", modifiers: .command).frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    var accountMenu: some View {
        Menu {
            Section("Codex") {
                ForEach(Array(chat.accounts.enumerated()), id: \.offset) { i, a in
                    Button((chat.target == "codex" && i == chat.current ? "✓ " : "    ") + a.name + " — осталось " + pct(a)) { chat.chooseCodex(i) }.disabled(!idle)
                }
            }
            Section("Claude") {
                Button((chat.target == "claude" ? "✓ " : "    ") + "Claude Code") { chat.switchProvider("claude") }.disabled(!idle)
            }
            if !apiStore.connections.isEmpty {
                Section("API") {
                    ForEach(apiStore.connections) { connection in
                        Button((chat.target == connection.target ? "✓ " : "    ") + connection.name) { chat.chooseAPI(connection) }.disabled(!idle)
                    }
                }
            }
            Divider()
            Button("Войти / открыть аккаунт в терминале…") { Terminal.run(shq(widgetDir + "open_codex.sh") + " " + shq(chat.account.home) + " " + shq(chat.account.name)) }
            Button("Добавить аккаунт Codex…") { Terminal.run(shq(widgetDir + "add_account.sh")) }
            Button("Добавить / изменить API…") { chat.showAPIConnections = true }
            Button("Обновить список и лимиты") { chat.accounts = loadAccounts(); chat.refreshAllLimits(force: true); workspace.say("Лимиты обновляются") }
            Button("Переподключить Codex") { chat.reconnect() }.disabled(chat.target != "codex" || chat.busy)
        } label: {
            Text(chat.connecting && chat.target == "codex" ? "подключаю…" : chat.isAPI ? chat.connectionTitle + " · API" : chat.target == "claude" ? "Claude Code" : "\(chat.account.name) · \(pct(chat.account))")
                .font(uiFont)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Кто отвечает в этом чате")
    }

    // MARK: лента

    var visibleItems: [Item] { chat.items.filter { !chat.focusedConversation || [.user, .agent, .error, .question, .approval].contains($0.kind) } }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("✻").font(.system(size: 34)).foregroundColor(accent)
            Text("Что делаем?").font(.system(size: 24, weight: .semibold))
            Text("Пиши задачу — отвечает \(chat.providerLabel) в папке \(chat.cwd.replacingOccurrences(of: homeDir, with: "~")).").font(.system(size: 13)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button { chooseFolder() } label: { Chip(icon: "folder", text: "Сменить папку") }.buttonStyle(.plain)
                Button { ui.showModel = true } label: { Chip(icon: "cpu", text: "Модель: " + chat.modelLabel) }.buttonStyle(.plain)
                Button { workspace.showPalette = true } label: { Chip(icon: "clock.arrow.circlepath", text: "Продолжить прошлый") }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                hint("↩", "отправить · ⌥↩ — новая строка")
                hint("⌘N", "ещё один чат рядом — работают одновременно")
                hint("⌘K", "быстрый переход к чату, диалогу или действию")
                hint("⌘1…9", "переключение между открытыми чатами")
                hint("/", "команды · !команда — выполнить в терминале проекта")
                hint("Esc", "остановить ответ")
            }.padding(.top, 6)
        }
        .padding(.top, 60).padding(.horizontal, 24).frame(maxWidth: 620, alignment: .leading)
    }

    func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 11, design: .monospaced)).padding(.horizontal, 6).frame(minWidth: 44, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: chat.cwd)
        if p.runModal() == .OK, let u = p.url, u.path != chat.cwd {
            if chat.items.isEmpty { chat.cwd = u.path; chat.newChat() } else { let fresh = workspace.newChat(); fresh.cwd = u.path; fresh.newChat() }
            workspace.say("Папка: " + u.path.replacingOccurrences(of: homeDir, with: "~"))
        }
    }

    var main: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.25)
            FollowingScroll(state: follow) {
                VStack(alignment: .leading, spacing: 12) {
                    if chat.items.isEmpty { emptyState }
                    ForEach(visibleItems) { item in
                        ItemView(it: item, chat: chat).id(item.id)
                            .background(GeometryReader { geometry in Color.clear.preference(key: MessagePositions.self, value: [item.id: geometry.frame(in: .named("conversation-document")).minY]) })
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: "conversation-document")
                .onPreferenceChange(MessagePositions.self) { follow.measurements?($0) }
            }
            .overlay(alignment: .bottom) {
                if !follow.following {
                    Button { follow.resume() } label: {
                        Label("К последним сообщениям", systemImage: "arrow.down").font(uiSmall)
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(Capsule().fill(Color(red: 0.17, green: 0.17, blue: 0.19)).shadow(color: .black.opacity(0.4), radius: 8, y: 2))
                            .overlay(Capsule().stroke(hairline))
                    }.buttonStyle(.plain).padding(.bottom, 8).accessibilityLabel("Вернуться вниз и следить за ответом")
                }
            }
            activity
            if !chat.pendingMessages.isEmpty { MessageQueueView(chat: chat, ui: ui) }
            if ui.draft.hasPrefix("/"), !ui.draft.contains(where: { $0.isWhitespace }), !ui.slashDismissed {
                SlashSuggestions(chat: chat, ui: ui)
            }
            composer
            footer
        }
        .font(mono)
        .sheet(isPresented: $chat.showRules) { RulesEditor(chat: chat, preferences: preferences) }
        .sheet(isPresented: Binding(get: { chat.editingItem != nil }, set: { if !$0 { chat.editingItem = nil } })) { EditMessageView(chat: chat) }
        .onChange(of: chat.queueContext) { _ in follow.resume() }
        .onExitCommand {
            if workspace.showPalette { workspace.showPalette = false }
            else if ui.draft.hasPrefix("/"), !ui.slashDismissed { ui.slashDismissed = true }
            else if voice.listening { voice.stop() }
            else { chat.interrupt() }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for pr in providers {
                if !pr.hasItemConformingToTypeIdentifier("public.file-url") {
                    _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                        if let img = img as? NSImage { DispatchQueue.main.async { saveAttachedImage(img, chat) } }
                    }
                    continue
                }
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    guard let u = url, u.isFileURL else { return }
                    DispatchQueue.main.async { if !chat.attachments.contains(u.path) { chat.attachments.append(u.path) } }
                }
            }
            return true
        }
        .sheet(isPresented: $ui.showBot) { BotView(close: { ui.showBot = false }) }
        .onChange(of: apiStore.revision) { _ in chat.apiConfigurationDidChange() }
        .sheet(isPresented: $chat.showAPIConnections) { APIConnectionsView(store: apiStore, onSelect: { chat.chooseAPI($0) }, canSelect: idle) }
        .onChange(of: chat.showCommandSettings) { show in if show { ui.showSettings = true; chat.showCommandSettings = false } }
        .onChange(of: chat.showModelChoices) { show in if show { ui.showModel = true; chat.showModelChoices = false } }
        .sheet(isPresented: $chat.showClaudeConversations) { ClaudeConversationsView(chat: chat) }
        .alert(item: $chat.pendingNativeAction) { action in
            Alert(title: Text(action.title), message: Text(action.message), primaryButton: .destructive(Text("Выполнить")) { action.perform() }, secondaryButton: .cancel())
        }

        .sheet(isPresented: $ui.showSettings) { SettingsView(chat: chat, close: { ui.showSettings = false }) }
    }

    /// Строка «что сейчас происходит» над полем ввода.
    @ViewBuilder var activity: some View {
        if chat.nativeCLIIsRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Выполняется команда…").font(monoSmall)
                Button("Остановить") { chat.interrupt() }.buttonStyle(.borderless)
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 6)
        }
        if chat.busy, let started = chat.turnStarted {
            HStack(spacing: 8) {
                Spinner(start: started, detail: chat.subagents.isEmpty ? "" : " · субагентов в работе: \(chat.subagents.count)")
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 6)
        }
    }

    // MARK: поле ввода

    func submit() {
        let matches = chat.matchingCommands(ui.draft)
        let exact = matches.contains { ui.draft == "/" + $0.name }
        if !matches.isEmpty, !exact, !ui.slashDismissed {
            ui.draft = "/" + matches[min(ui.slashSelection, matches.count - 1)].name + " "
            return
        }
        let text = ui.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty else { return }
        ui.draft = ""
        if voice.listening { voice.stop() }
        if ui.multi, !text.hasPrefix("/"), !chat.isAPI {
            ui.multi = false
            if chat.busy { chat.send(multiAgentPrompt + text) } else { chat.add(.user, text); chat.send(multiAgentPrompt + text, echo: false) }
        } else { chat.send(text) }
        follow.resume()
    }

    var placeholder: String {
        if voice.listening { return "Говори — я записываю…" }
        if chat.busy { return "Напиши ещё — встанет в очередь…" }
        return chat.isAPI ? "Сообщение для API…" : chat.target == "claude" ? "Задача для Claude…" : "Задача для Codex…"
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.attachments, id: \.self) { path in
                            HStack(spacing: 5) {
                                if isImagePath(path), let image = NSImage(contentsOfFile: path) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                                } else { Image(systemName: "doc").font(.system(size: 11)) }
                                Text((path as NSString).lastPathComponent).font(uiSmall).lineLimit(1).frame(maxWidth: 160)
                                Button { chat.attachments.removeAll { $0 == path } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 7).frame(height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(">").foregroundColor(chat.target == "claude" ? accent : .secondary).padding(.top, 1)
                TextField(placeholder, text: $ui.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...12).focused($inputFocused)
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
                    .onSubmit { submit() }
            }
            HStack(spacing: 6) {
                Button { if idle { chat.switchProvider(chat.target == "claude" ? "codex" : "claude") } } label: {
                    HStack(spacing: 5) {
                        Group { if chat.isAPI { Image(systemName: "network").font(.system(size: 11.5)) } else { ProviderIcon(claude: chat.target == "claude") } }.frame(width: 16, height: 16)
                        Text(chat.isAPI ? "API" : chat.target == "claude" ? "Claude" : "Codex").font(uiSmall)
                    }
                    .padding(.horizontal, 8).frame(height: 24).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                }.buttonStyle(.plain).disabled(!idle).help("Переключить Codex ⇄ Claude")
                Button { ui.showModel.toggle() } label: {
                    Chip(icon: "cpu", text: chat.modelLabel + ((chat.target == "claude" ? chat.claudeEffort : chat.reasoningEffort).map { " · " + (ModelPicker.effortNames[$0] ?? $0) } ?? "") + ((chat.target == "claude" ? chat.claudeFast : chat.codexFast) && !chat.isAPI ? " ⚡" : ""))
                }
                .buttonStyle(.plain).disabled(chat.isAPI).help("Модель, глубина размышлений и быстрый режим")
                .popover(isPresented: $ui.showModel, arrowEdge: .top) { ModelPicker(chat: chat) }
                Button { pickFiles(chat) } label: { Chip(icon: "paperclip") }.buttonStyle(.plain).help("Файлы и картинки (перетащи в окно или ⇧⌘V)")
                Button { voice.toggle(chat) } label: { Chip(icon: voice.listening ? "waveform" : "mic", active: voice.listening, tint: .red) }
                    .buttonStyle(.plain).help(voice.listening ? "Остановить запись" : "Надиктовать задачу голосом (⇧⌘M)").keyboardShortcut("m", modifiers: [.command, .shift])
                Button { promptCoach.open(draft: ui.draft, chat: chat) } label: { Chip(icon: "wand.and.stars", active: promptCoach.isOpen) }
                    .buttonStyle(.plain).help("Суперпромпт: уточнить и улучшить запрос перед отправкой")
                    .disabled(ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.busy || chat.connecting || chat.nativeCLIIsRunning)
                Button { ui.multi.toggle() } label: { Chip(icon: "person.3", text: ui.multi ? "Мультиагент" : "", active: ui.multi) }
                    .buttonStyle(.plain).disabled(chat.isAPI).help("Мультиагент: главный агент раздаст задачу субагентам и проверит их. Лимиты тратятся быстрее")
                Button { chat.toggleAutoApprove() } label: {
                    Chip(icon: chat.autoApprove ? "checkmark.shield.fill" : "hand.raised", text: chat.autoApprove ? "" : "Спрашивать", active: !chat.autoApprove, tint: .orange)
                }.buttonStyle(.plain).help(chat.autoApprove ? "Сейчас: команды и правки выполняются без вопросов. Нажми — спрашивать разрешение на каждое действие" : "Сейчас: каждое действие ждёт твоего разрешения. Нажми — подтверждать за тебя")
                Button { chat.showRules = true } label: { Chip(icon: "text.badge.checkmark", active: !chat.effectiveRules.isEmpty) }.buttonStyle(.plain).help("Правила: общие и для этого чата")
                if chat.restorePoint != nil { Button { chat.restoreEditedBranch() } label: { Chip(icon: "arrow.uturn.backward", text: "Вернуть до правки") }.buttonStyle(.plain).disabled(chat.busy) }
                Spacer(minLength: 4)
                if chat.busy || chat.nativeCLIIsRunning {
                    Button { chat.interrupt() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.14)))
                    }.buttonStyle(.plain).help("Остановить (Esc)")
                }
                Button { submit() } label: {
                    Image(systemName: chat.busy ? "text.badge.plus" : "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? accent : Color.white.opacity(0.1))).foregroundColor(canSend ? .black : .secondary)
                }.buttonStyle(.plain).disabled(!canSend).help(chat.busy ? "Добавить в очередь (↩)" : "Отправить (↩)")
            }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(inputFocused ? accent.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 6)
        .onTapGesture { inputFocused = true }
    }

    var canSend: Bool { !ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty }

    var footer: some View {
        let claude = chat.target == "claude"
        let input = claude ? chat.claudeInputTokens : chat.codexInputTokens
        let output = claude ? chat.claudeOutputTokens : chat.codexOutputTokens
        let l = chat.limits[chat.account.home]
        return HStack(spacing: 10) {
            Button { chooseFolder() } label: {
                Label(chat.cwd.replacingOccurrences(of: homeDir, with: "~"), systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }.buttonStyle(.plain).help("Рабочая папка. Нажми — выбрать другую")
            if input != nil || output != nil {
                Text("↑\(Self.short(input)) ↓\(Self.short(output))").help(claude ? "Токены последнего хода: вход / выход" : "Токены диалога: вход / выход")
            }
            Spacer()
            if !chat.isAPI, !claude {
                Text("5ч " + (l?.five.map { "\(Int(100 - $0))%" } ?? "?") + " · нед " + (l?.week.map { "\(Int(100 - $0))%" } ?? "?")).help("Сколько лимита осталось у «\(chat.account.name)»")
                if chat.autoSwitch { Image(systemName: "arrow.left.arrow.right").help("Авто-переключение аккаунтов включено") }
            }
            if proxy.enabled { Text("VLESS").foregroundColor(proxy.status.hasPrefix("включён") ? .green : .orange).help(proxy.status) }
        }
        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    static func short(_ n: Int?) -> String {
        guard let n = n else { return "—" }
        return n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: быстрый переход (⌘K)

struct PaletteEntry: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let run: () -> Void
}

final class PaletteState: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
}

struct PaletteView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = PaletteState()
    @FocusState private var focused: Bool

    var entries: [PaletteEntry] {
        let chat = workspace.active
        var all: [PaletteEntry] = workspace.chats.enumerated().map { i, c in
            PaletteEntry(id: "chat" + c.sessionID.uuidString, icon: "bubble.left", title: c.title, detail: c.status.label + " · " + c.providerLabel + (i < 9 ? " · ⌘\(i + 1)" : "")) { workspace.activate(c) }
        }
        all += [
            PaletteEntry(id: "new", icon: "square.and.pencil", title: "Новый чат", detail: "⌘N") { workspace.newChat() },
            PaletteEntry(id: "provider", icon: "arrow.left.arrow.right", title: chat.target == "claude" ? "Переключить на Codex" : "Переключить на Claude", detail: "Кто отвечает в этом чате") { if !chat.busy { chat.switchProvider(chat.target == "claude" ? "codex" : "claude") } },
            PaletteEntry(id: "model", icon: "cpu", title: "Выбрать модель", detail: chat.modelLabel) { chat.ui.showModel = true },
            PaletteEntry(id: "settings", icon: "gearshape", title: "Настройки", detail: "Telegram, обновления, голос, VLESS") { chat.ui.showSettings = true },
            PaletteEntry(id: "bot", icon: "chart.line.uptrend.xyaxis", title: "Торговый бот", detail: "Состояние и выкладка") { chat.ui.showBot = true },
            PaletteEntry(id: "approve", icon: "checkmark.shield", title: chat.autoApprove ? "Спрашивать разрешение на действия" : "Подтверждать действия за меня", detail: "Сейчас: " + (chat.autoApprove ? "без вопросов" : "спрашивает")) { chat.toggleAutoApprove() },
            PaletteEntry(id: "rules", icon: "text.badge.checkmark", title: "Правила чата", detail: "Общие и для этого чата") { chat.showRules = true },
            PaletteEntry(id: "limits", icon: "gauge.with.dots.needle.50percent", title: "Обновить лимиты", detail: "Все аккаунты") { chat.refreshAllLimits(force: true); workspace.say("Лимиты обновляются") },
            PaletteEntry(id: "update", icon: "arrow.down.circle", title: "Проверить обновления", detail: "v" + Updater.shared.version) { Updater.shared.check(manual: true); chat.ui.showSettings = true },
            PaletteEntry(id: "close", icon: "xmark", title: "Закрыть этот чат", detail: "⌘W") { workspace.close(chat) }
        ]
        let open = Set(workspace.chats.map(\.conversationKey))
        all += chat.threads.filter { !ChatTrash.shared.ids.contains($0.id) && !open.contains($0.id) }.prefix(state.query.isEmpty ? 8 : 400).map { t in
            PaletteEntry(id: "thread" + t.id, icon: "clock.arrow.circlepath", title: t.title, detail: t.account + " · " + relFmt.localizedString(for: t.date, relativeTo: Date())) { workspace.open(t) }
        }
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
    }

    func run(_ entry: PaletteEntry) { workspace.showPalette = false; entry.run() }

    var body: some View {
        let list = Array(entries.prefix(40))
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).onTapGesture { workspace.showPalette = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Чат, прошлый диалог или действие…", text: $state.query)
                        .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                        .onChange(of: state.query) { _ in state.selection = 0 }
                        .onKeyPress(.downArrow) { state.selection = min(state.selection + 1, max(0, list.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { state.selection = max(state.selection - 1, 0); return .handled }
                        .onKeyPress(.escape) { workspace.showPalette = false; return .handled }
                        .onSubmit { if list.indices.contains(state.selection) { run(list[state.selection]) } }
                }.padding(14)
                Divider().opacity(0.3)
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                                Button { run(entry) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.icon).frame(width: 18).foregroundColor(index == state.selection ? accent : .secondary)
                                        Text(entry.title).font(.system(size: 13)).lineLimit(1)
                                        Spacer()
                                        Text(entry.detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(index == state.selection ? accent.opacity(0.18) : Color.clear))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(entry.id)
                            }
                            if list.isEmpty { Text("Ничего не найдено").font(uiFont).foregroundColor(.secondary).padding(16) }
                        }.padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: state.selection) { value in if list.indices.contains(value) { reader.scrollTo(list[value].id) } }
                }
            }
            .frame(width: 580)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.12, blue: 0.135)).shadow(color: .black.opacity(0.6), radius: 30, y: 10))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline))
            .padding(.top, 90)
        }
        .onAppear { focused = true }
    }
}

// MARK: настройки

final class SettingsForm: ObservableObject {
    @Published var token = ""
    @Published var remote = ""
    @Published var tab = UserDefaults.standard.string(forKey: "settingsTab") ?? "work" {
        didSet { UserDefaults.standard.set(tab, forKey: "settingsTab") }
    }
}

struct SettingsView: View {
    @ObservedObject var mods = ModStore.shared
    @ObservedObject var wallpaper = PultWallpaper.shared
    @ObservedObject var chat: Chat
    @ObservedObject var proxy = Proxy.shared
    @ObservedObject var telegram = TelegramBridge.shared
    @ObservedObject var updater = Updater.shared
    @ObservedObject var voice = Voice.shared
    @StateObject private var form = SettingsForm()
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $form.tab) {
                Text("Работа").tag("work"); Text("Telegram").tag("telegram"); Text("Обновления").tag("update")
                Text("Голос").tag("voice"); Text("Сеть").tag("net"); Text("Вид").tag("look"); Text("Гайд").tag("guide"); Text("Моды").tag("mods")
            }.pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 16)
            Form {
                switch form.tab {
                case "telegram": telegramSection
                case "update": updateSection
                case "voice": voiceSection
                case "net": networkSection
                case "look": lookSection
                case "guide": Section("Помощь") { Button("Открыть гайд") { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Workspace.shared.showGuide = true } } }
                case "mods": ModsSettingsView()
                default: workSection
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Готово", action: close).keyboardShortcut(.defaultAction) }.padding([.horizontal, .bottom], 16)
        }
        .frame(width: 600, height: 560)
        .onAppear { form.remote = updater.remote; form.tab = UserDefaults.standard.string(forKey: "settingsTab") ?? "work" }

    }

    @ViewBuilder var workSection: some View {
        Section("Этот чат") {
            HStack {
                TextField("Рабочая папка", text: $chat.cwd)
                Button("Выбрать…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { chat.cwd = u.path; chat.newChat() }
                }
            }
            Picker("Что можно Codex", selection: $chat.sandbox) {
                Text("только читать").tag("read-only")
                Text("менять файлы в папке проекта").tag("workspace-write")
                Text("полный доступ к компьютеру").tag("danger-full-access")
            }
            Toggle("Подтверждать действия за меня", isOn: Binding(get: { chat.autoApprove }, set: { if $0 != chat.autoApprove { chat.toggleAutoApprove() } }))
            Text("Включено — команды, правки файлов и запросы доп. прав выполняются без вопросов. Выключи, если хочешь разрешать каждое действие сам (в окне или кнопками в Telegram).").font(.caption).foregroundColor(.secondary)
        }
        Section("Аккаунты и вопросы") {
            Toggle("Авто-переключение аккаунтов Codex (кончился лимит или осталось меньше 5%)", isOn: $chat.autoSwitch)
            Toggle("Codex задаёт вопросы карточкой с вариантами", isOn: Binding(get: { UserDefaults.standard.object(forKey: "codexQuestions") as? Bool ?? true }, set: { UserDefaults.standard.set($0, forKey: "codexQuestions"); chat.objectWillChange.send() }))
            Text("Когда агенту не хватает твоего решения, он спрашивает и ждёт, а не гадает. Для Codex это экспериментальная возможность; изменение применится после переподключения.").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder var telegramSection: some View {
        Section("Свой бот") {
            Text("1. Создай бота у @BotFather и скопируй токен.\n2. Вставь токен сюда и нажми «Подключить».\n3. Отправь боту код привязки — после этого он слушает только тебя.").font(.caption).foregroundColor(.secondary)
            HStack {
                SecureField(telegram.configured ? "Токен сохранён в .env — вставь новый, чтобы заменить" : "Токен бота", text: $form.token)
                Button(telegram.configured ? "Заменить" : "Подключить") { telegram.setToken(form.token); form.token = "" }.disabled(form.token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            LabeledContent("Состояние", value: telegram.status)
            if telegram.configured, !telegram.paired, !telegram.pairCode.isEmpty {
                LabeledContent("Код привязки") {
                    HStack { Text(telegram.pairCode).font(.system(size: 20, weight: .bold, design: .monospaced)).textSelection(.enabled); Button("Скопировать") { copyText(telegram.pairCode) } }
                }
                Text("Открой @\(telegram.botName) в Telegram и отправь этот код.").font(.caption).foregroundColor(.secondary)
            }
            if telegram.configured {
                HStack {
                    if telegram.paired { Button("Отвязать телефон") { telegram.unpair() } }
                    Button("Отключить бота", role: .destructive) { telegram.setToken("") }
                }
            }
        }
        Section("Что приходит") {
            Toggle("Сообщать о каждом завершённом ходе, а не только о долгих", isOn: $telegram.notifyAlways)
            Text("Всегда: ответы на задачи, отправленные из Telegram. Когда окно Пульта не активно: вопросы агента и запросы разрешений с кнопками, итог хода дольше минуты. Субагенты отдельных сообщений не шлют — приходит один итог.").font(.caption).foregroundColor(.secondary)
            if !telegram.configured {
                Toggle("Пока своего бота нет — слать итог через общий бот на сервере", isOn: $chat.notifyTelegram)
            }
        }
    }

    @ViewBuilder var updateSection: some View {
        Section("Версия") {
            LabeledContent("Установлено", value: "\(updater.version) · \(updater.commit)")
            LabeledContent("Исходники", value: updater.source.replacingOccurrences(of: homeDir, with: "~"))
            if !updater.status.isEmpty { Text(updater.status).font(.callout).textSelection(.enabled) }
            if !updater.notes.isEmpty { Text(updater.notes.map { "• " + $0 }.joined(separator: "\n")).font(.caption).foregroundColor(.secondary) }
            HStack {
                Button("Проверить сейчас") { updater.check(manual: true) }.disabled(updater.working || updater.remote.isEmpty)
                Button("Обновить") { updater.install() }.disabled(updater.working || updater.available == 0)
                if updater.working { ProgressView().controlSize(.small) }
            }
        }
        Section("GitHub") {
            HStack {
                TextField("https://github.com/abobalover228-afk/pult-public", text: $form.remote)
                Button("Привязать") { updater.setRemote(form.remote) }.disabled(form.remote.trimmingCharacters(in: .whitespaces).isEmpty || form.remote == updater.remote)
            }
            Toggle("Ставить обновления автоматически, когда все чаты свободны", isOn: $updater.auto)
            Text("Пульт раз в полчаса проверяет готовые релизы этого репозитория. Скачивает более новую версию, проверяет SHA-256 и подпись, сохраняет предыдущую копию приложения и перезапускается, когда работа закончена.").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder var voiceSection: some View {
        Section("Голос") {
            Toggle("Озвучивать ответы", isOn: $voice.speakReplies)
            Toggle("Режим «без рук»: договорил — отправилось, ответ озвучен — снова слушаю", isOn: $voice.handsFree)
            Picker("Язык распознавания", selection: $voice.language) {
                Text("Русский").tag("ru-RU"); Text("English").tag("en-US")
            }
            if !voice.problem.isEmpty { Text(voice.problem).foregroundColor(.orange).font(.callout) }
            Text("Микрофон включается кнопкой у поля ввода или ⇧⌘M. При первом включении macOS спросит доступ к микрофону и распознаванию речи.").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder var networkSection: some View {
        Section("VLESS только для Пульта") {
            Toggle("Подключаться через VLESS", isOn: $proxy.enabled).disabled(!proxy.available && !proxy.enabled)
            if proxy.names.count > 1 {
                Picker("Сервер", selection: $proxy.selected) {
                    ForEach(Array(proxy.names.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
                }
            }
            LabeledContent("Состояние", value: proxy.status)
            Text(proxy.available ? "Через VLESS идут Codex, Claude, Telegram и обновления, запущенные из Пульта. Остальной Mac не затрагивается. Свободные чаты переподключаются сами." : "Положи ссылку vless://… в ~/Documents/pult/vless.txt и xray в ~/Documents/pult/bin/xray — после этого переключатель станет активным.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder var lookSection: some View {
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
        }
        Section("Лента · сохраняется для всех чатов") {
            Toggle("Показывать только сообщения (без команд и служебных блоков)", isOn: $chat.focusedConversation)
            Toggle("Разворачивать вывод команд целиком", isOn: $chat.expandedTools)
        }
    }
}
