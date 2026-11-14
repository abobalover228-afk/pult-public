import AppKit
import SwiftUI

final class FakePromptTransport: PromptCoachTransport {
    var onNotification: (String, JSON) -> Void = { _, _ in }
    var onServerRequest: (Any, String, JSON) -> Void = { _, _, _ in }
    var onExit: () -> Void = {}
    var calls: [(String, JSON)] = []
    var rejected = false
    var stopped = false
    func start(_ ready: @escaping (Bool) -> Void) { ready(true) }
    func call(_ method: String, _ params: JSON, _ cb: @escaping (JSON) -> Void) {
        calls.append((method, params))
        if method == "thread/start" { cb(["result": ["thread": ["id": "coach-thread"]]]) }
        else { cb(["result": [:]]) }
    }
    func reject(_ id: Any, _ message: String) { rejected = true }
    func stop() { stopped = true }
    func complete(_ reply: JSON) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
        onNotification("item/completed", ["threadId": "coach-thread", "item": ["type": "agentMessage", "id": UUID().uuidString, "text": text]])
        onNotification("turn/completed", ["threadId": "coach-thread", "turn": ["status": "completed"]])
    }
}

@main struct PromptCoachChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let chat = Chat(connectImmediately: false)
        let originalContext = chat.queueContext
        chat.add(.user, "Самое раннее требование: сохранить API")
        let command = chat.add(.command, "inspect")
        command.output = "START_OF_FULL_OUTPUT" + String(repeating: "x", count: 12000) + "END_OF_FULL_OUTPUT"
        chat.add(.agent, "Уже проверено")
        let fake = FakePromptTransport()
        let coach = PromptCoach(makeClient: { _ in fake })
        coach.open(draft: "сделай норм", chat: chat)
        precondition(coach.isOpen && coach.busy)
        precondition(chat.items.count == 3 && chat.queueContext == originalContext)
        let initial = fake.calls.first { $0.0 == "thread/start" }!.1
        precondition(initial["sandbox"] as? String == "read-only" && initial["ephemeral"] as? Bool == true)
        let turn = fake.calls.last!.1
        let text = ((turn["input"] as! [JSON])[0]["text"] as! String)
        precondition(text.contains("Самое раннее требование") && text.contains("START_OF_FULL_OUTPUT") && text.contains("END_OF_FULL_OUTPUT"))
        precondition(turn["outputSchema"] is JSON)
        fake.onServerRequest(1, "item/commandExecution/requestApproval", [:])
        precondition(fake.rejected)
        fake.complete(["status": "questions", "summary": "Уточним результат", "questions": [["id": "goal", "text": "Как проверить готовность?", "options": ["Тесты", "Демо"]]], "improvedPrompt": ""])
        precondition(!coach.busy && coach.questions.count == 1 && !coach.canAnswer)
        coach.answers["goal"] = "  "
        precondition(!coach.canAnswer)
        coach.answers["goal"] = "Тесты"
        precondition(coach.canAnswer)
        coach.answer()
        precondition(coach.busy && fake.calls.last!.0 == "turn/start")
        fake.complete(["status": "ready", "summary": "Готово", "questions": [], "improvedPrompt": "Сохрани API и добавь тесты."])
        precondition(!coach.busy && coach.improved == "Сохрани API и добавь тесты.")
        precondition(chat.items.count == 3 && chat.pendingMessages.isEmpty)
        precondition(coach.snapshot!.matches(chat))
        chat.newChat()
        precondition(!coach.snapshot!.matches(chat))
        coach.close()
        precondition(fake.stopped && !coach.isOpen)
        fake.complete(["status": "ready", "summary": "late", "questions": [], "improvedPrompt": "stale result"])
        precondition(coach.improved != "stale result")
        precondition((try? PromptCoachReply.parse("{\"status\":\"ready\",\"summary\":\"\",\"questions\":[],\"improvedPrompt\":\" \"}")) == nil)
        precondition((try? PromptCoachReply.parse("{\"status\":\"questions\",\"summary\":\"\",\"questions\":[],\"improvedPrompt\":\"\"}")) == nil)
        print("PASS: full history, isolated read-only session, questions, answers, editable result, no automatic main-chat send, context guard, cancellation and late-event rejection")
    }
}
