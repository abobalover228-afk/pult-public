import AppKit
import SwiftUI

@main struct IntegrationChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let chat = Chat(connectImmediately: false)
        chat.target = "codex"
        let client = CodexClient(home: "/tmp/pult-fake-account")
        var requests: [JSON] = []
        client.requestTransport = { request in
            requests.append(request)
            guard let id = request["id"] else { return }
            var result: JSON = [:]
            if request["method"] as? String == "model/list" {
                result = ["data": [["id": "test-model", "model": "test-model", "displayName": "Test", "description": "Fixture"]], "nextCursor": NSNull()]
            } else if request["method"] as? String == "plugin/list" {
                result = ["marketplaces": [["name": "fixture-market", "plugins": [["id": "sample@fixture-market", "name": "sample", "installed": false]]]]]
            }
            client.handle(["id": id, "result": result])
        }
        chat.client = client
        let parsedArguments = try CommandWords.parse("add name 'path with space' \"$()\"")
        precondition(parsedArguments == ["add", "name", "path with space", "$()"] )
        do { _ = try CommandWords.parse("'unterminated"); preconditionFailure() } catch {}
        chat.handleSlash("/model")
        precondition(chat.showModelChoices && chat.modelChoices.map(\.id) == ["test-model"])
        chat.handleSlash("/effort high"); precondition(chat.reasoningEffort == "high")
        chat.handleSlash("/effort auto"); precondition(chat.reasoningEffort == nil)
        chat.handleSlash("/mcp login example")
        precondition(requests.last?["method"] as? String == "mcpServer/oauth/login")
        precondition((requests.last?["params"] as? JSON)?["name"] as? String == "example")
        chat.handleSlash("/mcp reload")
        precondition(requests.last?["method"] as? String == "config/mcpServer/reload")
        chat.handleSlash("/plugins install sample")
        precondition(requests[requests.count - 2]["method"] as? String == "plugin/list")
        precondition((requests[requests.count - 2]["params"] as? JSON)?["cwds"] as? [String] == [chat.cwd])
        precondition(requests.last?["method"] as? String == "plugin/install")
        let installParams = requests.last?["params"] as? JSON
        precondition(installParams?["pluginName"] as? String == "sample")
        precondition(installParams?["remoteMarketplaceName"] as? String == "fixture-market")
        precondition(installParams?["marketplacePath"] == nil)
        precondition(UUID(uuidString: installParams?["installAttemptId"] as? String ?? "") != nil)
        let beforeRemove = requests.count
        chat.handleSlash("/plugins remove sample")
        precondition(chat.pendingNativeAction != nil)
        precondition(requests.count == beforeRemove, "Uninstall must wait for confirmation")
        chat.pendingNativeAction?.perform()
        precondition(requests.last?["method"] as? String == "plugin/uninstall")
        precondition((requests.last?["params"] as? JSON)?["pluginId"] as? String == "sample")
        chat.handleSlash("/skills disable /tmp/SKILL.md")
        precondition(requests.last?["method"] as? String == "skills/config/write")
        precondition((requests.last?["params"] as? JSON)?["enabled"] as? Bool == false)
        chat.handleSlash("/experimental sample on")
        precondition(requests.last?["method"] as? String == "experimentalFeature/enablement/set")
        chat.handleSlash("/config-set model_reasoning_effort \"high\"")
        chat.pendingNativeAction?.perform()
        precondition(requests.last?["method"] as? String == "config/value/write")
        precondition((requests.last?["params"] as? JSON)?["value"] as? String == "high")
        chat.handleSlash("/raw"); precondition(chat.expandedTools)
        chat.handleSlash("/focus"); precondition(chat.focusedConversation)
        chat.target = "claude"
        chat.handleSlash("/effort medium"); precondition(chat.claudeEffort == "medium" && chat.reasoningEffort == nil)
        chat.handleSlash("/plan"); precondition(chat.claudePermissionMode == "plan")
        chat.handleSlash("/plan"); precondition(chat.claudePermissionMode == "auto")
        chat.busy = true
        chat.handleSlash("/effort low"); precondition(chat.claudeEffort == "medium")
        precondition(Set(PultCommand.list(for: "codex").map(\.name)).count == PultCommand.list(for: "codex").count)
        chat.claudeCommands = [PultCommand(name: "custom-skill", detail: "fixture")]
        precondition(chat.matchingCommands("/custom").map(\.name) == ["custom-skill"])
        chat.busy = false
        chat.runInlineCLI("/usr/bin/printf", ["%s", "literal $(touch /tmp/should-not-exist) | text"])
        let deadline = Date().addingTimeInterval(5)
        while chat.nativeCLIIsRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!chat.nativeCLIIsRunning)
        precondition(chat.items.last?.output == "literal $(touch /tmp/should-not-exist) | text")
        precondition(chat.items.last?.exitCode == 0)
        chat.runInlineCLI("/not/a/real/executable", [])
        precondition(chat.items.last?.exitCode == 1 && !chat.nativeCLIIsRunning)
        print("PASS: actual subprocess output streaming, literal shell syntax, launch failure recovery")
        print("PASS: quoted arguments; API routing; model picker; effort isolation; plugin confirmation; skill enablement; config values; plan; focus; dynamic skills")
        print("Registered Codex: \(PultCommand.list(for: "codex").count), Claude: \(PultCommand.list(for: "claude").count)")
    }
}
