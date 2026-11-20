import AppKit
import Foundation
import WebKit

@main struct ModSDKChecks {
    static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    static func invoke(_ id: String, _ method: String, _ params: JSON = [:]) throws -> Any {
        var answer: Result<Any, Error>?
        ModPlatform.shared.call(id, method: method, params: params) { answer = $0 }
        precondition(wait(10) { answer != nil }, "API timed out: " + method)
        return try answer!.get()
    }
    static func check(_ value: @autoclosure () throws -> Bool) throws { let actual = try value(); precondition(actual) }
    static func reject(_ operation: () throws -> Any, line: UInt = #line) {
        do { _ = try operation(); preconditionFailure("Operation should have failed at test line \(line)") } catch {}
    }
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mod-sdk-" + UUID().uuidString)
        let project = root.appendingPathComponent("project"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { ModPlatform.shared.stopAll(); try? FileManager.default.removeItem(at: root) }
        let suite = "sdk-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModStore(directory: root.appendingPathComponent("Mods"), defaults: defaults)
        ModPlatform.shared.store = store
        let workspace = Workspace(connectImmediately: false); workspace.active.cwd = project.path
        ModPlatform.shared.workspaceOverride = workspace
        var manifest: JSON = ["format": 2, "id": "sdk-test", "name": "SDK test", "version": "1", "author": "checks",
            "permissions": ["chats.read", "chats.write", "files.read", "files.write", "secrets", "process"],
            "commands": [["name": "open", "title": "Open", "script": "await pult.call('ui.openPanel',{panel:'main'})"]],
            "panels": [["id": "main", "title": "Test", "html": "<p>Test</p>", "placement": "right"]],
            "files": ["asset.txt": "bundled resource"]]
        let mod = try PultMod.decode(JSONSerialization.data(withJSONObject: manifest)); try store.save(mod)
        precondition(store.activeMods.count == 1)
        let info = try invoke(mod.id, "app.info") as! JSON
        precondition(info["apiVersion"] as? Int == 2)
        try check(try String(contentsOfFile: (info["assetsPath"] as! String) + "/asset.txt", encoding: .utf8) == "bundled resource")
        _ = try invoke(mod.id, "storage.set", ["key": "nested", "value": ["null": NSNull(), "items": [1, 2]]])
        try check((try invoke(mod.id, "storage.get", ["key": "nested"]) as! JSON)["null"] is NSNull)
        _ = try invoke(mod.id, "secrets.set", ["key": "TEST_VALUE", "value": "only-in-env"])
        try check(try invoke(mod.id, "secrets.get", ["key": "TEST_VALUE"]) as? String == "only-in-env")
        let env = store.dataDirectory(mod.id).appendingPathComponent(".env")
        try check((try FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as! NSNumber).intValue == 0o600)
        _ = try invoke(mod.id, "files.write", ["path": "hello.txt", "text": "hello"])
        try check(try invoke(mod.id, "files.read", ["path": "hello.txt"]) as? String == "hello")
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: outside)
        for path in ["../outside/test", "escape/test", ".env", ".git/config", "auth.json", ".ENV", ".GiT/config", "Auth.JSON"] {
            reject { try invoke(mod.id, "files.write", ["path": path, "text": "must not write"]) }
        }
        let first = try invoke(mod.id, "chats.create", ["title": "one"]) as! JSON
        let second = try invoke(mod.id, "chats.create", ["title": "two"]) as! JSON
        precondition(first["id"] as! String != second["id"] as! String)
        let count = workspace.chats.count
        reject { try invoke(mod.id, "chats.create", ["cwd": outside.path]) }
        precondition(workspace.chats.count == count)
        reject { try invoke(mod.id, "chats.send", ["text": "!touch should-not-run"]) }
        reject { try invoke(mod.id, "network.fetch", ["url": "https://example.com"]) }
        reject { try invoke(mod.id, "team.send", ["text": "not authorized"]) }
        _ = try invoke(mod.id, "ui.openPanel", ["panel": "main"])
        precondition(store.rightPanelID == "sdk-test/main")

        manifest["id"] = "other-mod"; manifest["permissions"] = []
        let other = try PultMod.decode(JSONSerialization.data(withJSONObject: manifest)); try store.save(other)
        try check(try invoke(other.id, "storage.get", ["key": "nested"]) is NSNull)
        reject { try invoke(other.id, "secrets.get", ["key": "TEST_VALUE"]) }
        reject { try invoke(other.id, "chats.read") }

        let bridge = ModWebBridge(mod: mod)
        let web = bridge.make(html: "<html><body>SDK bridge</body></html>", script: "pult.call('storage.set',{key:'from-js',value:'bridge works'}).then(()=>window.sdkReady=true).catch(e=>window.sdkError=String(e));")
        var fromJS = false
        precondition(wait(12) {
            web.evaluateJavaScript("window.sdkReady===true") { value, _ in fromJS = value as? Bool == true }
            return fromJS
        })
        try check(try invoke(mod.id, "storage.get", ["key": "from-js"]) as? String == "bridge works")
        ModPlatform.shared.emit("sdk.test", ["value": "event"], modID: mod.id)
        bridge.dispose(web)

        let started = try invoke(mod.id, "process.start", ["id": "worker", "executable": "/usr/bin/python3", "arguments": ["-u", "-c", "import time; print('owned process',flush=True); time.sleep(30)"]]) as! JSON
        let pid = started["pid"] as! Int32
        var output = ""
        precondition(wait(5) { output = ((try? invoke(mod.id, "process.read", ["id": "worker"])) as? JSON)?["text"] as? String ?? ""; return output.contains("owned process") })
        store.toggle(mod.id, false)
        precondition(wait(5) { kill(pid, 0) != 0 })
        reject { try invoke(mod.id, "app.info") }
        precondition(store.rightPanelID == nil)

        store.toggle(mod.id, true)
        var altered = manifest; altered["id"] = mod.id; altered["permissions"] = []
        try JSONSerialization.data(withJSONObject: altered).write(to: root.appendingPathComponent("Mods/sdk-test.pult"))
        store.reload()
        precondition(!store.activeMods.contains { $0.id == mod.id })
        reject { try invoke(mod.id, "app.info") }

        let legacy = try PultMod.decode(Data(contentsOf: URL(fileURLWithPath: "Examples/starter.pult")))
        precondition(legacy.format == 1 && legacy.allPanels.count == 1)
        for name in ["native-team", "sdk-playground"] {
            try check(try PultMod.decode(Data(contentsOf: URL(fileURLWithPath: "Examples/" + name + ".pult"))).format == 2)
        }
        var invalid = manifest; invalid["files"] = ["../../escape": "bad"]
        reject { try PultMod.decode(JSONSerialization.data(withJSONObject: invalid)) }
        invalid = manifest; invalid["background"] = "while(true){}"
        reject { try PultMod.decode(JSONSerialization.data(withJSONObject: invalid)) }
        print("PASS: v1 compatibility, v2 manifests, real WebKit Promise bridge, missing permissions, revoked permissions, tampered-code quarantine, panel docking, independent chats, invalid-cwd rollback, scoped storage with JSON null, scoped .env secrets, symlink traversal protection, owned process output and stop-on-disable. No model calls.")
    }
}
