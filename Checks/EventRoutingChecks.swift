import AppKit
import Foundation
@main struct EventRoutingChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let chat = Chat(connectImmediately: false)
        let client = CodexClient(home: "/tmp/pult-events")
        client.requestTransport = { request in
            if let id = request["id"] { client.handle(["id": id, "result": ["thread": ["id": "main"]]]) }
        }
        chat.client = client
        chat.withThread { _ in }
        var finished = 0
        chat.onEvent = { _, event in if case .finished = event { finished += 1 } }
        chat.busy = true
        chat.notification("turn/started", ["threadId": "main", "turn": ["id": "current"]])
        chat.notification("item/started", ["threadId": "child", "item": ["id": "foreign", "type": "agentMessage", "text": "foreign"]])
        chat.notification("turn/completed", ["threadId": "child", "turn": ["id": "child-turn", "status": "completed"]])
        precondition(chat.busy && finished == 0 && !chat.items.contains { $0.id == "foreign" })
        chat.notification("turn/completed", ["threadId": "main", "turn": ["id": "old", "status": "completed"]])
        precondition(chat.busy && finished == 0)
        chat.notification("turn/completed", ["threadId": "main", "turn": ["id": "current", "status": "completed"]])
        chat.notification("turn/completed", ["threadId": "main", "turn": ["id": "current", "status": "completed"]])
        precondition(!chat.busy && finished == 1)
        print("PASS: child events isolated, stale turn ignored, exactly one completion")
    }
}
