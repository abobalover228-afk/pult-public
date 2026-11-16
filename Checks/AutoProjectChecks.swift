import Foundation

struct TeamRoomError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main struct AutoProjectChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pult-auto-project-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = "https://github.com/abobalover228-afk/pult-public"
        let folder = try TeamProject.automaticProject(repo, root: root)
        precondition(folder.path.hasSuffix("abobalover228-afk/pult-public"))
        let marker = folder.appendingPathComponent("local-user-file.txt")
        try Data("keep me".utf8).write(to: marker)
        let reopened = try TeamProject.automaticProject(repo, root: root)
        let data = try Data(contentsOf: marker)
        precondition(reopened == folder && data == Data("keep me".utf8))
        let selected = try TeamProject.automaticProject(repo, preferred: folder.path, root: root)
        precondition(selected == folder)
        let collision = root.appendingPathComponent("test/occupied")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let untouched = collision.appendingPathComponent("user.txt")
        try Data("untouched".utf8).write(to: untouched)
        do { _ = try TeamProject.automaticProject("https://github.com/test/occupied", root: root); preconditionFailure("Overwrote existing folder") }
        catch { let kept = try Data(contentsOf: untouched); precondition(kept == Data("untouched".utf8)) }
        print("PASS: real public clone into automatically created folders, correct origin, reuse without overwriting local files, manual checkout and occupied-folder protection")
    }
}
