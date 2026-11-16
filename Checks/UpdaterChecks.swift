import Foundation

@main struct UpdaterChecks {
    static func main() throws {
        precondition(Updater.repository("https://github.com/abobalover228-afk/pult-public.git") == "abobalover228-afk/pult-public")
        precondition(Updater.repository("https://github.com/name/repo.git --bad") == nil)
        precondition(Updater.repository("https://token@github.com/name/repo") == nil)
        precondition(Updater.repository("https://example.com/name/repo") == nil)
        precondition(Updater.newer("2.10.0", than: "2.9.0"))
        precondition(!Updater.newer("2.0.0", than: "2.1.0"))
        precondition(!Updater.newer("2.1.0", than: "2.1.0"))
        precondition(!Updater.newer("2.1.0-beta", than: "2.0.0"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pult-updater-check-" + UUID().uuidString)
        let target = root.appendingPathComponent("Pult.app"), candidate = root.appendingPathComponent("Candidate.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
        let backup = try Updater.replaceBundle(at: target, with: candidate)
        let old = try Data(contentsOf: backup.appendingPathComponent("version"))
        let new = try Data(contentsOf: target.appendingPathComponent("version"))
        precondition(old == Data("old".utf8) && new == Data("new".utf8))
        do { _ = try Updater.replaceBundle(at: target, with: root.appendingPathComponent("Missing.app")); preconditionFailure("Missing candidate accepted") }
        catch { let preserved = try Data(contentsOf: target.appendingPathComponent("version")); precondition(preserved == new) }
        print("PASS: official GitHub repository, token URL rejection, numeric versions downgrade protection, retained backup and failed-copy recovery")
    }
}
