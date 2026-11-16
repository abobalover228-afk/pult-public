// «Пульт»: Codex и Claude на всех аккаунтах, несколько чатов одновременно, управление из Telegram.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--smoke-test") {
            guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.2.0",
                  Bundle.main.url(forResource: "PultAppIcon", withExtension: "icns") != nil else { exit(1) }
            print("PASS: Pult 2.2 app launch, linked WebRTC and bundle resources")
            exit(0)
        }
        signal(SIGPIPE, SIG_IGN)            // запись в умерший Codex/Claude не должна ронять приложение
        if let url = Bundle.main.url(forResource: "PultAppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        Proxy.shared.apply()
        Proxy.shared.onChange = {
            Workspace.shared.networkChanged()
            TelegramBridge.shared.restart()
        }
        BotStatus.shared.startWatching()
        TelegramBridge.shared.start()
        Updater.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ n: Notification) {
        let chat = Workspace.shared.active
        if chat.unread { chat.unread = false }
    }
    func applicationWillTerminate(_ n: Notification) {
        Workspace.shared.chats.forEach { $0.shutdown() }
        Proxy.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct PultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var workspace = Workspace.shared

    var body: some Scene {
        WindowGroup("Пульт") {
            RootView(workspace: workspace).frame(minWidth: 760, minHeight: 520)
                .onOpenURL { url in
                    if url.host == "room" {
                        TeamRoomModel.shared.code = url.absoluteString
                        workspace.showTeamRoom = true
                        return
                    }
                    let chat = workspace.active
                    guard !chat.busy, !chat.nativeCLIIsRunning else { return }
                    if url.host == "connections" { chat.showAPIConnections = true }
                    if url.host == "api", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                       let connection = APIConnectionStore.shared.connections.first(where: { $0.id.uuidString == id }) { chat.chooseAPI(connection) }
                }
        }
        .defaultSize(width: 1080, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый чат") { workspace.newChat() }.keyboardShortcut("n")
                Button("Новый чат в новой вкладке") { workspace.newChat() }.keyboardShortcut("t")
                Button("Закрыть чат") { workspace.close(workspace.active) }.keyboardShortcut("w")
                Divider()
                Button("Быстрый переход…") { workspace.showPalette.toggle() }.keyboardShortcut("k")
                Button("Следующий чат") { workspace.cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Предыдущий чат") { workspace.cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(0..<9, id: \.self) { i in
                    Button("Чат \(i + 1)") { workspace.activate(index: i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("Вставить файл / картинку") { pasteImage(workspace.active) }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
