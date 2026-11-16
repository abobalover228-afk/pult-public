import Foundation

@main struct TeamRoomChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw TeamRoomError("FAIL: " + message) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pult-team-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appendingPathComponent("origin.git")
        _ = try TeamRoomGit.run(["init", "--bare", remote.path])
        let project = root.appendingPathComponent("project")
        _ = try TeamRoomGit.run(["clone", remote.path, project.path])
        try Data("project\n".utf8).write(to: project.appendingPathComponent("README.md"))
        _ = try TeamRoomGit.run(["add", "README.md"], at: project)
        _ = try TeamRoomGit.run(["-c", "user.name=Test", "-c", "user.email=test@pult.local", "commit", "-m", "Initial project"], at: project)
        _ = try TeamRoomGit.run(["push", "origin", "HEAD:refs/heads/main"], at: project)
        let before = try TeamRoomGit.run(["rev-parse", "HEAD"], at: project).text
        let first = try TeamRoomGit(cache: root.appendingPathComponent("alice.git"), remote: remote.path)
        let second = try TeamRoomGit(cache: root.appendingPathComponent("bob.git"), remote: remote.path)
        try require(try first.read().isEmpty, "new room is empty")
        let hello = TeamMessage(author: "Алиса", text: "Привет 🦊\n$(touch /tmp/should-not-run) `id` — просто текст")
        try first.send(hello)
        try first.send(hello)
        try require(try second.read() == [hello], "Unicode, multiline and idempotent delivery")
        let a = TeamMessage(author: "Алиса", text: "Делаю UI")
        let b = TeamMessage(author: "Боб", text: "Делаю сервер")
        let group = DispatchGroup(), lock = NSLock()
        var errors: [String] = []
        for (client, message) in [(first, a), (second, b)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try client.send(message) }
                catch { lock.lock(); errors.append(error.localizedDescription); lock.unlock() }
            }
        }
        group.wait()
        try require(errors.isEmpty, "concurrent sends: " + errors.joined(separator: "; "))
        let received = try first.read()
        try require(Set(received.map(\.id)) == Set([hello.id, a.id, b.id]), "concurrent sends retain both messages")
        try require(try second.read() == received, "clients converge")
        try require(try TeamRoomGit.run(["rev-parse", "HEAD"], at: project).text == before, "project HEAD unchanged")
        try require(try TeamRoomGit.run(["status", "--porcelain"], at: project).text.isEmpty, "project files/index unchanged")
        try require(try TeamRoomGit.run(["ls-remote", remote.path, "refs/heads/main"]).text.hasPrefix(before), "main unchanged")
        do { try first.send(TeamMessage(author: "", text: "bad")); throw TeamRoomError("FAIL: empty author accepted") }
        catch { try require(!error.localizedDescription.hasPrefix("FAIL"), "empty author rejected") }
        do { try first.send(TeamMessage(author: "A", text: String(repeating: "x", count: 16_001))); throw TeamRoomError("FAIL: oversized message accepted") }
        catch { try require(!error.localizedDescription.hasPrefix("FAIL"), "oversized message rejected") }
        try require(!TeamRoomGit.validRemote("https://token@example.com/repo"), "token URL rejected")
        try require(!TeamRoomGit.validRemote("ext::sh -c bad"), "external transport rejected")
        try require(TeamRoomGit.validRemote("git@github.com:team/project.git"), "SSH URL accepted")
        print("PASS: two clients, concurrent sends, retry deduplication, Unicode, project isolation, input limits and credential URL rejection")
    }
}
