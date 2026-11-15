import AppKit
import SwiftUI
@main struct QuestionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "workingDirectory")
        let previousAuto = defaults.object(forKey: "autoApprove")
        defer { if let previousAuto = previousAuto { defaults.set(previousAuto, forKey: "autoApprove") } else { defaults.removeObject(forKey: "autoApprove") } }
        defer { if let previous = previous { defaults.set(previous, forKey: "workingDirectory") } else { defaults.removeObject(forKey: "workingDirectory") } }
        let chat = Chat(connectImmediately: false)
        chat.cwd = "/tmp/pult-persistence-check"
        let reopened = Chat(connectImmediately: false)
        precondition(reopened.cwd == "/tmp/pult-persistence-check")
        chat.autoApprove = true
        let payload: JSON = ["questions": [["id": "a", "question": "Что выбрать?", "options": [["label": "Первый", "description": "Вариант"]]], ["id": "b", "question": "Уточнение", "isSecret": true]]]
        let item = chat.presentQuestion(id: 99, params: payload)
        precondition(item.kind == .question && item.decision == nil && item.questionAnswers.isEmpty)
        chat.toggleAutoApprove(); chat.toggleAutoApprove()
        precondition(item.decision == nil, "Auto-approval must never answer questions")
        precondition(QuestionPayload.response(payload, answers: [:]) == nil)
        precondition(QuestionPayload.response(payload, answers: ["a": "Первый"]) == nil)
        let reply = QuestionPayload.response(payload, answers: ["a": "Первый", "b": "  свой ответ  "])
        let answers = reply?["answers"] as? [String: JSON]
        precondition(answers?["a"]?["answers"] as? [String] == ["Первый"])
        precondition(answers?["b"]?["answers"] as? [String] == ["свой ответ"])
        item.questionAnswers = ["a": "Первый", "b": "ответ"]
        chat.submitQuestion(item)
        precondition(item.decision == nil, "Disconnected client must keep the response pending")
        precondition(!chat.transcript().contains("свой ответ"))
        let queued = Chat(connectImmediately: false)
        queued.target = "codex"
        queued.busy = true; queued.attachments = ["/tmp/picture.png"]
        queued.send("первое"); queued.send("второе")
        precondition(queued.pendingMessages.map(\.text) == ["первое", "второе"])
        precondition(queued.pendingMessages[0].images == ["/tmp/picture.png"])
        precondition(queued.pendingMessages[1].images.isEmpty && queued.attachments.isEmpty)
        queued.busy = false; queued.drainQueue()
        precondition(queued.pendingMessages.count == 2, "Disconnected queue must retain messages")
        queued.queuePaused = true; queued.drainQueue()
        precondition(queued.pendingMessages.count == 2)
        queued.target = "claude"; queued.drainQueue()
        precondition(queued.pendingMessages.count == 2, "Must not send to another provider")
        precondition(Chat.mcpConfirmationContent([:]) != nil)
        precondition(Chat.mcpConfirmationContent(["mode": "url"]) == nil)
        precondition(Chat.mcpConfirmationContent(["requestedSchema": ["required": ["name"], "properties": ["name": ["type": "string"]]]]) == nil)
        let allowed = Chat.mcpConfirmationContent(["requestedSchema": ["required": ["confirm"], "properties": ["confirm": ["type": "boolean"]]]])
        precondition(allowed?["confirm"] as? Bool == true)
        chat.autoApprove = true
        precondition(Chat(connectImmediately: false).autoApprove)
        print("PASS: persistent auto-approval, MCP confirmations, manual missing data")
        print("PASS: queue FIFO, attachments, disconnected retention, pause, provider isolation")
        print("PASS: cwd persistence, manual questions, auto-approval exclusion, required answers, RPC format, disconnected retry")
    }
}
