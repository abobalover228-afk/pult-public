import AppKit
import Foundation
import SwiftUI
final class TeamFake:TeamRequest {
    var prompt="";var instructions="";var completion:((Result<String,APIProblem>)->Void)?;var cancelled=false
    func start(prompt:String,instructions:String,completion:@escaping(Result<String,APIProblem>)->Void){self.prompt=prompt;self.instructions=instructions;self.completion=completion}
    func cancel(){cancelled=true}
}
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
    let chat=Chat(connectImmediately:false);chat.connectBranches=false;chat.target="codex"
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
    // Independent coordinator + two real request slots + synthesis, partial failure, cancellation.
    chat.target="codex";let team=TeamRun();var workers:[TeamFake]=[]
    team.makeRequest={let f=TeamFake();workers.append(f);return f}
    team.start(prompt:"task",chat:chat);precondition(workers.count==1 && team.running)
    workers[0].completion?(.success(#"{"tasks":[{"title":"A","prompt":"independent A"},{"title":"B","prompt":"independent B"}]}"#))
    precondition(workers.count==3 && workers[1] !== workers[2])
    precondition(workers[1].prompt.contains("independent A") && workers[2].prompt.contains("independent B"))
    workers[1].completion?(.success("result A"));workers[2].completion?(.failure(APIProblem(message:"failure B")))
    precondition(workers.count==4 && workers[3].prompt.contains("result A") && workers[3].prompt.contains("failure B"))
    workers[3].completion?(.success("partial synthesis"));precondition(!team.running && team.result=="partial synthesis")
    let stopped=TeamRun();var pending:[TeamFake]=[];stopped.makeRequest={let f=TeamFake();pending.append(f);return f}
    stopped.start(prompt:"cancel",chat:chat);stopped.cancel();pending[0].completion?(.success("late"));precondition(!stopped.running && pending[0].cancelled && stopped.result.isEmpty)
    // Native scrolling anchor stability under content growth above the viewport.
    let state=FollowState();state.following=false
    precondition(FollowState.preservedY(origin:500,old:["anchor":550],new:["anchor":750]) == 700)
    state.resume();precondition(state.following)
    print("PASS: rules inheritance/persistence, stable pins, non-destructive folding, fast routing, clean edit branch and restore, separate team requests, partial failures/cancellation, native scroll anchor preservation")
 }
}
