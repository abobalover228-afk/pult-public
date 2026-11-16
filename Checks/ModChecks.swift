import AppKit
import Foundation

@main struct ModChecks {
    @MainActor static func main() throws {
        let suite = "pult-mod-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var sample = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Examples/starter.pult"))) as! [String: Any]
        sample["settings"] = ["language": "Русский"]
        let mod = try PultMod.decode(JSONSerialization.data(withJSONObject: sample))
        let store = ModStore(directory: directory, defaults: defaults)
        try store.save(mod); store.themeID = mod.id
        store.set("English", key: "language", mod: mod)
        let restored = ModStore(directory: directory, defaults: defaults)
        precondition(restored.mods.count == 1 && restored.theme != nil)
        precondition(restored.commandList.contains { $0.name == "starter/explain" })
        precondition(restored.settings(for: mod)["language"] == "English")
        restored.toggle(mod.id, false)
        let disabled = ModStore(directory: directory, defaults: defaults)
        precondition(disabled.commandList.isEmpty && disabled.theme == nil)
        disabled.toggle(mod.id, true)
        precondition(disabled.theme != nil && disabled.settings(for: mod)["language"] == "English")
        func reject(_ object: [String: Any]) throws {
            do { _ = try PultMod.decode(JSONSerialization.data(withJSONObject: object)); preconditionFailure("Invalid mod accepted") }
            catch is ModError {}
        }
        var invalid = sample; invalid["id"] = "../../escape"; try reject(invalid)
        invalid = sample; invalid["permissions"] = ["unknown"]; try reject(invalid)
        invalid = sample; invalid["commands"] = [["name": "run", "title": "run", "shell": "echo SHOULD_NOT_RUN"]]; try reject(invalid)
        invalid = sample; invalid["theme"] = ["accent": "bad"]; try reject(invalid)
        let loaded = try PultMod.decode(Data(contentsOf: directory.appendingPathComponent("starter.pult")))
        precondition(loaded.id == mod.id)
        print("PASS: .pult validation, path traversal rejection, undeclared shell rejection, namespaced commands, installation, persisted enable/theme/settings and disable/re-enable")
    }
}
