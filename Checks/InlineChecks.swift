import AppKit
import SwiftUI

@main struct InlineChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let chat = Chat(connectImmediately: false)
        chat.target = "codex"
        precondition(!chat.handleSlash("обычное сообщение"))
        precondition(!chat.handleSlash("/tmp/file.txt посмотри файл"))
        precondition(chat.handleSlash("/definitely-unknown"))
        precondition(chat.items.last?.kind == .error)
        precondition(chat.handleSlash("/model test-codex"))
        precondition(chat.model == "test-codex")
        chat.busy = true
        precondition(chat.handleSlash("/model must-not-change"))
        precondition(chat.model == "test-codex")
        chat.busy = false; chat.target = "claude"
        precondition(chat.handleSlash("/model test-claude"))
        precondition(chat.claudeModel == "test-claude" && chat.model == "test-codex")
        precondition(chat.handleSlash("/permissions") && chat.showCommandSettings)
        precondition(chat.handleSlash("/help"))
        precondition(chat.items.last?.text.contains("/cost") == true)
        precondition(chat.items.last?.text.contains("/archive") == false)
        precondition(PultCommand.matches("/mo", provider: "codex").map(\.name) == ["model"])
        precondition(PultCommand.matches("/model foo", provider: "codex").isEmpty)
        precondition(PultCommand.matches("/arc", provider: "claude").isEmpty)
        precondition(PultCommand.matches("/arc", provider: "codex").map(\.name) == ["archive"])
        chat.target = "codex"
        precondition(chat.handleSlash("/mcp"))
        precondition(chat.items.last?.text == "Codex ещё не подключён.")
        print("PASS: routing, provider isolation, busy guard, settings, unknown commands, path prompts, completion")
        print("Codex commands: \(PultCommand.list(for: "codex").count), Claude commands: \(PultCommand.list(for: "claude").count)")
    }
}
