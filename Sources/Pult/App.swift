// «Пульт»: Codex на всех аккаунтах в окне в стиле Claude Code.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(atPath: appDataDir, withIntermediateDirectories: true)
        if let url = Bundle.main.url(forResource: "PultAppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        Proxy.shared.apply()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ n: Notification) { Proxy.shared.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct PultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var chat = Chat()

    var body: some Scene {
        WindowGroup("Пульт") {
            ChatView(chat: chat).frame(minWidth: 640, minHeight: 480)
                .onOpenURL { url in
                    guard !chat.busy, !chat.nativeCLIIsRunning else { return }
                    if url.host == "connections" { chat.showAPIConnections = true }
                    if url.host == "api", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                       let connection = APIConnectionStore.shared.connections.first(where: { $0.id.uuidString == id }) { chat.chooseAPI(connection) }
                }
        }
        .defaultSize(width: 900, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый диалог") { chat.newChat() }.keyboardShortcut("n")
            }
            CommandGroup(after: .pasteboard) {
                Button("Вставить картинку") { pasteImage(chat) }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
