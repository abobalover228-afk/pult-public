import AppKit
import Foundation
import SwiftUI
@main struct ConversationChecks {
 @MainActor static func main() throws {
    _=NSApplication.shared
    let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("pult-state-check-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:temporary)}
    LocalConversationStore.directory=temporary
    let suite="pult-conversations-tests-"+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let prefs=ConversationPreferences(defaults:defaults);prefs.globalRules="global";precondition(prefs.rules("one")=="global")
    prefs.setOverride("override",for:"one");precondition(prefs.rules("one")=="override");prefs.copyOverride(from:"one",to:"two")
    prefs.togglePin("stable-thread");let reopened=ConversationPreferences(defaults:defaults)
    precondition(reopened.pins.contains("stable-thread") && reopened.rules("two")=="override")
    reopened.setOverride(nil,for:"one");precondition(reopened.rules("one")=="global")
    prefs.focusedConversation = true; prefs.expandedTools = true
    let reloaded = ConversationPreferences(defaults: defaults)
    precondition(reloaded.focusedConversation && reloaded.expandedTools)
    let shared = ConversationPreferences.shared
    let previousFocused = shared.focusedConversation, previousExpanded = shared.expandedTools
    defer { shared.focusedConversation = previousFocused; shared.expandedTools = previousExpanded }
    shared.focusedConversation = false; shared.expandedTools = false
    let chat=Chat(connectImmediately:false);chat.connectBranches=false;chat.target="codex"
    let other = Chat(connectImmediately:false)
    chat.focusedConversation = true; chat.expandedTools = true
    precondition(other.focusedConversation && other.expandedTools)
    let expandedCommand = chat.add(.command, "keep expanded")
    chat.busy = true; chat.busy = false
    precondition(chat.expandedTools && !expandedCommand.serviceCollapsed)
    chat.items.removeAll(); chat.expandedTools = false; chat.focusedConversation = false
    let cmd=chat.add(.command,"inspect");cmd.output=String(repeating:"x",count:20000);cmd.exitCode=0
    let error=chat.add(.command,"failure");error.exitCode=1
    let question=chat.add(.question,"unanswered")
    let approval=chat.add(.approval,"permission")
    let answer=chat.add(.agent,"visible answer")
    let plan=chat.add(.note,"TODO");plan.isPlan=true
    chat.busy=true;chat.busy=false
    precondition(cmd.serviceCollapsed && cmd.output.count==20000 && plan.serviceCollapsed)
    precondition(!error.serviceCollapsed && !question.serviceCollapsed && !approval.serviceCollapsed && !answer.serviceCollapsed)
    cmd.serviceCollapsed=false;precondition(cmd.output.count==20000)
    precondition(chat.handleFast("/fast on") && chat.codexFast)
    precondition(chat.fastTurnOptions["serviceTier"] as? String == "fast")
    precondition(chat.handleFast("/fast off") && !chat.codexFast)
    chat.target="claude";_ = chat.handleFast("/fast on");precondition(chat.claudeFast && !chat.codexFast)
    chat.target="api:invalid";_ = chat.handleFast("/fast on");precondition(chat.claudeFast && !chat.codexFast)
    chat.target="codex";chat.newChat()
    let first=chat.add(.user,"original");first.images=["/tmp/attachment.png"]
    chat.add(.agent,"MUST NOT ENTER NEW CONTEXT")
    chat.pendingMessages=[QueuedMessage(text:"old queue",images:[],provider:"codex",directory:chat.cwd,context:chat.queueContext)]
    chat.beginEdit(first);chat.editingText="edited";chat.editingImages=[]
    // fake Codex transport: capture fresh thread/start and turn/start without executing a model.
    let client=CodexClient(home:chat.account.home);var requests:[JSON]=[]
    client.requestTransport={ req in
        requests.append(req)
        if req["method"] as? String == "thread/start"{client.handle(["id":req["id"]!,"result":["thread":["id":"new-thread"]]])}
        if req["method"] as? String == "turn/start"{client.handle(["id":req["id"]!,"result":[:]])}
    };chat.client=client
    chat.editAndContinue()
    let wire=String(data:try JSONSerialization.data(withJSONObject:requests),encoding:.utf8)!
    precondition(!wire.contains("MUST NOT ENTER NEW CONTEXT") && wire.contains("edited"))
    precondition(chat.restorePoint != nil && chat.pendingMessages.isEmpty && !LocalConversationStore.threads().isEmpty)
    chat.busy=false;chat.restoreEditedBranch()
    precondition(chat.items.contains{$0.text=="MUST NOT ENTER NEW CONTEXT"} && chat.pendingMessages.count==1 && chat.queuePaused)
    // Native scrolling anchor stability under content growth above the viewport.
    let state=FollowState();state.following=false
    precondition(FollowState.preservedY(origin:500,old:["anchor":550],new:["anchor":750]) == 700)
    state.resume();precondition(state.following)
    print("PASS: rules inheritance/persistence, stable pins, non-destructive folding, fast routing, clean edit branch and restore, native scroll anchor preservation")
 }
}
