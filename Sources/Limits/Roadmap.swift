import AppKit
import SwiftUI

struct RoadmapEntry: Decodable, Identifiable {
    let id, provider, name, meaning, category, status, syntax, kind, detail, source: String
    static let all = (try? JSONDecoder().decode([RoadmapEntry].self, from: Data(roadmapCommandsJSON.utf8))) ?? []
    var statusLabel: String {
        switch status { case "ready": return "В Пульте"; case "partial": return "Частично"; case "removed": return "Удалено из CLI"; default: return "Ещё не перенесено" }
    }
}
final class RoadmapState: ObservableObject {
    @Published var mode = "tasks"
    @Published var provider = "codex"
    @Published var category = "all"
    @Published var status = "all"
    @Published var search = ""
    @Published var selected: String?
    @Published var pins = Set(UserDefaults.standard.stringArray(forKey: "roadmapWishlist") ?? []) {
        didSet { UserDefaults.standard.set(Array(pins).sorted(), forKey: "roadmapWishlist") }
    }
    @Published var widgetTab = "limits"
}
struct RoadmapView: View {
    @ObservedObject var state: RoadmapState
    private let categories: [(String, String, String)] = [
        ("sessions", "Начать или продолжить", "Новые разговоры, история, ветки и экспорт"),
        ("models", "Выбрать модель", "Модель, скорость и глубина размышлений"),
        ("context", "Разобраться с контекстом", "Сжатие, память и инструкции проекта"),
        ("rights", "Настроить разрешения", "Песочница и подтверждения"),
        ("work", "Написать и проверить", "План, изменения, ревью и запуск"),
        ("automation", "Дать большую задачу", "Цели, агенты, фон и расписания"),
        ("integrations", "Подключить инструменты", "MCP, skills, плагины и редактор"),
        ("account", "Посмотреть расход", "Токены, квоты и аккаунты"),
        ("appearance", "Настроить внешний вид", "Тема, клавиши и отображение"),
        ("diagnostics", "Понять, что сломалось", "Состояние, настройки и диагностика")
    ]
    var filtered: [RoadmapEntry] {
        RoadmapEntry.all.filter { entry in
            entry.provider == state.provider &&
            (state.category == "all" || entry.category == state.category) &&
            (state.status == "all" || (state.status == "pins" ? state.pins.contains(entry.id) : entry.status == state.status)) &&
            (state.search.isEmpty || (entry.name + " " + entry.meaning).localizedCaseInsensitiveContains(state.search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Провайдер", selection: $state.provider) {
                Text("GPT / Codex").tag("codex"); Text("Claude").tag("claude")
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Вид карты", selection: $state.mode) {
                Text("Что хочу сделать").tag("tasks"); Text("Команды").tag("commands")
            }.pickerStyle(.segmented).labelsHidden()
            if state.mode == "tasks" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Мой Пульт").font(.headline)
                        Text("Один чат · GPT ↔ Claude · команды по / · вопросы · очередь · папка между запусками").font(.caption).foregroundColor(.secondary)
                        ForEach(categories, id: \.0) { category in
                            Button {
                                state.category = category.0; state.status = "all"; state.search = ""; state.mode = "commands"
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(category.1); Spacer(); Image(systemName: "chevron.right") }
                                    Text(category.2).font(.caption).foregroundColor(.secondary)
                                    let entries = RoadmapEntry.all.filter { $0.provider == state.provider && $0.category == category.0 }
                                    Text("\(entries.filter { $0.status == "ready" }.count) готово · \(entries.filter { $0.status == "partial" }.count) частично · \(entries.filter { $0.status == "planned" }.count) в плане")
                                        .font(.caption2).foregroundColor(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }.padding(.vertical, 4)
                }.frame(height: 430)
            } else {
                TextField("Найти команду или задачу", text: $state.search).textFieldStyle(.roundedBorder)
                Picker("Задача", selection: $state.category) {
                    Text("Все задачи").tag("all")
                    ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Статус", selection: $state.status) {
                    Text("Все команды").tag("all"); Text("В Пульте").tag("ready")
                    Text("Частично").tag("partial"); Text("Ещё не перенесено").tag("planned")
                    Text("Мой план").tag("pins")
                }
                Text("Найдено: \(filtered.count) · справочник: \(RoadmapEntry.all.count)").font(.caption2).foregroundColor(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(filtered) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { state.selected = state.selected == entry.id ? nil : entry.id } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .top) {
                                            Text(entry.name).font(.system(size: 12, weight: .medium, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 3)
                                            Image(systemName: state.selected == entry.id ? "chevron.up" : "chevron.down")
                                        }
                                        Text(entry.meaning).font(.caption).foregroundColor(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if state.selected == entry.id {
                                    Text(entry.statusLabel).font(.caption).foregroundColor(entry.status == "ready" ? .green : .orange)
                                    Text(entry.syntax).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    Text(entry.detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Button(state.pins.contains(entry.id) ? "✓ В моём плане" : "+ В мой план") {
                                            if state.pins.contains(entry.id) { state.pins.remove(entry.id) } else { state.pins.insert(entry.id) }
                                        }.buttonStyle(.borderless)
                                        Spacer(minLength: 0)
                                        if let url = URL(string: entry.source) { Link("Справка", destination: url) }
                                    }.font(.caption)
                                }
                            }
                            Divider().opacity(0.3)
                        }
                        if filtered.isEmpty { Text("Нет команд по этому фильтру.").font(.caption).foregroundColor(.secondary) }
                    }
                }.frame(height: 340)
            }
            Text("Справочник на 14.11.2026. Наличие команд CLI зависит от версии, платформы и тарифа. «В моём плане» — твой выбор, не обещанный срок.")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor final class MapWindow {
    static let shared = MapWindow()
    private var window: NSWindow?
    private let state = RoadmapState()
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Карта команд"
            w.contentView = NSHostingView(rootView: CommandMap(state: state).frame(minWidth: 880, minHeight: 650).preferredColorScheme(.dark))
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct CommandMap: View {
    @ObservedObject var state: RoadmapState
    private let branches: [(String,String,String)] = [
        ("sessions","Разговоры","bubble.left.and.bubble.right"),
        ("models","Модели","sparkles"),
        ("context","Контекст и память","brain"),
        ("rights","Разрешения","lock.shield"),
        ("work","Разработка","hammer"),
        ("automation","Агенты и задачи","point.3.connected.trianglepath.dotted"),
        ("integrations","Инструменты","puzzlepiece.extension"),
        ("account","Токены и аккаунт","gauge"),
        ("appearance","Интерфейс","paintbrush"),
        ("diagnostics","Диагностика","stethoscope")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Карта команд").font(.title2)
                Spacer()
                Picker("Провайдер", selection: $state.provider) {
                    Text("GPT / Codex").tag("codex"); Text("Claude").tag("claude")
                }.pickerStyle(.segmented).frame(width: 230)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geometry in map(geometry.size) }.frame(minWidth: 540)
                Divider()
                VStack {
                    RoadmapView(state: state)
                    Spacer(minLength: 0)
                }.padding(16).frame(width: 300)
            }
        }
        .onAppear { state.mode = "commands" }
    }

    // Карта собрана из отдельных частей: одним выражением SwiftUI компилятор не успевал вывести типы.
    private func point(_ index: Int, _ size: CGSize) -> CGPoint {
        let angle = Double(index) * 2 * .pi / Double(branches.count) - .pi / 2
        let rx = max(120, size.width / 2 - 108), ry = max(190, size.height / 2 - 68)
        return CGPoint(x: size.width / 2 + rx * cos(angle), y: size.height / 2 + ry * sin(angle))
    }

    private func map(_ size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return ZStack {
            Path { path in
                for index in branches.indices {
                    let end = point(index, size)
                    path.move(to: center)
                    path.addCurve(to: end, control1: CGPoint(x: (center.x + end.x) / 2, y: center.y), control2: CGPoint(x: end.x, y: (center.y + end.y) / 2))
                }
            }.stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
            VStack(spacing: 8) {
                Image(systemName: "command").font(.system(size: 28))
                Text(state.provider == "codex" ? "GPT / Codex" : "Claude Code").font(.headline)
                Text("Что хочу сделать?").font(.caption).foregroundColor(.secondary)
            }.padding(18).background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.12))).position(center)
            ForEach(Array(branches.enumerated()), id: \.element.0) { index, branch in
                branchButton(branch).position(point(index, size))
            }
        }
    }

    private func branchButton(_ branch: (String, String, String)) -> some View {
        let selected = state.category == branch.0
        let count = RoadmapEntry.all.filter { $0.provider == state.provider && $0.category == branch.0 }.count
        return Button { state.category = branch.0; state.selected = nil; state.search = ""; state.mode = "commands" } label: {
            VStack(spacing: 6) {
                Image(systemName: branch.2).font(.system(size: 19))
                Text(branch.1).font(.system(size: 13, weight: .medium))
                Text("\(count) команд").font(.caption2).foregroundColor(.secondary)
            }
            .frame(width: 145, height: 74)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15)))
        }.buttonStyle(.plain)
    }
}
