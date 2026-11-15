import AppKit
@main struct QueueChecks {
static func main() {
 let defaults = UserDefaults.standard
 let previousTarget = defaults.object(forKey: "selectedConnection")
 defer {
  if let previousTarget { defaults.set(previousTarget, forKey: "selectedConnection") }
  else { defaults.removeObject(forKey: "selectedConnection") }
 }
 let chat = Chat(connectImmediately: false)
 chat.target = "codex"
 chat.busy = true
 chat.send("first"); chat.send("second")
 let second = chat.pendingMessages[1]
 chat.sendQueuedNow(second)
 precondition(chat.pendingMessages.first?.id == second.id)
 precondition(chat.immediateQueuedID == second.id)
 precondition(chat.pendingMessages.count == 2)
 chat.busy = false; chat.drainQueue()
 precondition(chat.pendingMessages.count == 2, "No client must retain messages")
 chat.target = "claude"
 chat.sendQueuedNow(second)
 precondition(chat.pendingMessages.count == 2)
 print("PASS: immediate priority, no message loss, no cross-provider dispatch")
}
}
