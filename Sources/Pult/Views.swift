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
        if !it.autoApproved {
            if it.canCollapse && it.serviceCollapsed && !expanded {
                Button { it.serviceCollapsed=false;it.expanded=true } label: {
                    HStack { Image(systemName:"chevron.right");Text(it.isPlan ? "План / TODO" : it.kind == .command ? "Команда и результат" : "Служебный блок");Text(String(it.text.prefix(70))).foregroundColor(.secondary);Spacer() }
                }.buttonStyle(.plain).font(monoSmall).help("Раскрыть сохранённое содержимое")
            } else { visibleContent }
        }
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
                if it.kind == .user { Button("Изменить и продолжить отсюда…") { chat.beginEdit(it) } }
                if it.canCollapse { Button(it.serviceCollapsed ? "Раскрыть блок" : "Свернуть блок") { it.serviceCollapsed.toggle();it.expanded=false } }
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
                Label(it.decision == nil ? "Нужно разрешение" : "Разрешение", systemImage: "lock.shield").font(.system(size: 12.5, weight: .semibold)).foregroundColor(it.decision == nil ? accent : .secondary)
                Text(it.text).textSelection(.enabled)
                if let d = it.decision {
                    Text(d == "decline" ? "✗ Отклонено" : d == "expired" ? "Запрос устарел — сессия, которая спрашивала, уже закрыта" : "✓ Разрешено")
                        .font(monoSmall).foregroundColor(d == "decline" ? .red : d == "expired" ? .secondary : .green)
                } else {
                    HStack(spacing: 8) {
                        Button { chat.answer(it, "accept") } label: { Text("Разрешить").padding(.horizontal, 4) }.buttonStyle(.borderedProminent).tint(accent)
                        Button("Разрешать до конца сессии") { chat.answer(it, "acceptForSession") }
                        Button("Нет") { chat.answer(it, "decline") }
                    }.controlSize(.regular).font(uiFont)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(it.decision == nil ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(it.decision == nil ? accent.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1))
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
    var detail = ""
    private let frames = ["✻", "✶", "✳", "✢", "·", "✢", "✳", "✶"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            HStack(spacing: 8) {
                Text(frames[Int(t / 0.15) % frames.count]).foregroundColor(accent)
                Text("Работаю… " + (t >= 60 ? "\(Int(t) / 60)м \(Int(t) % 60)с" : "\(Int(t))с") + detail + " · Esc — прервать").foregroundColor(accent)
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
    @Published var showModel = false
    @Published var multi = false
}

let relFmt: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "ru_RU"); f.unitsStyle = .short; return f }()

final class PultWallpaper: ObservableObject {
    static let shared = PultWallpaper()
    private let file = URL(fileURLWithPath: homeDir + "/Library/Application Support/PultPublic/background-image")
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

let multiAgentPrompt = """
Работай как главный мультиагентной команды. Раздели задачу на независимые части и запусти на них субагентов параллельно \
(Codex: spawn_agent, затем wait_agent; Claude: инструмент Agent, несколько вызовов в одном сообщении). \
Каждому дай полное задание и свои файлы — два субагента не правят один файл. Мелочь делай сам. \
Когда все закончат — проверь их работу (диффы, сборка/тесты), исправь ошибки и дай итог: что сделано, чем проверено, что нет.

Задача:

"""

let attachDir = appDataDir + "/attachments"

func pickFiles(_ chat: Chat) {
    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
    if p.runModal() == .OK { chat.attachments += p.urls.map(\.path).filter { !chat.attachments.contains($0) } }
}

func isImagePath(_ path: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased()) }

/// Не-картинки идут путями: Codex/Claude читают их сами; API не видит диск — туда текст файла (до 100 КБ).
func attachedFilesNote(_ paths: [String], inline: Bool) -> String {
    "\n\nПрикреплённые файлы:\n" + paths.map { p in
        guard inline, let d = FileManager.default.contents(atPath: p), d.count <= 100_000, let s = String(data: d, encoding: .utf8) else { return "- " + p }
        return "- \(p)\n```\n\(s)\n```"
    }.joined(separator: "\n")
}

/// ⇧⌘V: картинка из буфера (скриншот) → файл → вложение.
func pasteImage(_ chat: Chat) {
    let pb = NSPasteboard.general
    if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
        chat.attachments += urls.filter(\.isFileURL).map(\.path); return
    }
    if let img = NSImage(pasteboard: pb) { saveAttachedImage(img, chat) }
}

/// Картинка без файла (буфер, перетаскивание из браузера/Telegram/Фото) → PNG во вложения.
func saveAttachedImage(_ img: NSImage, _ chat: Chat) {
    guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: attachDir, withIntermediateDirectories: true)
    let path = attachDir + "/image-\(UUID().uuidString.prefix(8)).png"
    if (try? png.write(to: URL(fileURLWithPath: path))) != nil { chat.attachments.append(path) }
}
