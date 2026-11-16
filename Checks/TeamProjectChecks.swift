import Foundation

struct TeamRoomError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

final class GitHubStub: URLProtocol {
    static var posts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url!.host == "api.github.com")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
        var object: Any = ["default_branch": "main"]
        if request.url!.path.hasSuffix("/pulls") {
            if request.httpMethod == "POST" {
                Self.posts += 1
                let body: Data
                if let data = request.httpBody { body = data }
                else {
                    let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
                    body = data
                }
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: String]
                precondition(json["head"]!.hasPrefix("pult/task-") && json["base"] == "main")
                object = ["html_url": "https://github.com/test/project/pull/42"]
            } else { object = Self.posts > 0 ? [["html_url": "https://github.com/test/project/pull/42"]] : [] }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 201 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct TeamProjectChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pult-project-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("remote.git"), source = root.appendingPathComponent("source")
        try ProjectGit.run(["init", "--bare", bare.path])
        try ProjectGit.run(["init", "--initial-branch=main", source.path])
        try ProjectGit.run(["config", "user.name", "Pult Test"], at: source)
        try ProjectGit.run(["config", "user.email", "pult-test@example.invalid"], at: source)
        try Data("original".utf8).write(to: source.appendingPathComponent("code.txt"))
        try ProjectGit.run(["add", "code.txt"], at: source)
        try ProjectGit.run(["commit", "-m", "initial"], at: source)
        try ProjectGit.run(["remote", "add", "origin", "https://github.com/test/project.git"], at: source)
        // Push is redirected to a temporary bare repository; no GitHub writes occur.
        try ProjectGit.run(["config", "url." + bare.path + ".pushInsteadOf", "https://github.com/test/project.git"], at: source)
        try ProjectGit.run(["push", "origin", "main"], at: source)
        try ProjectGit.run(["fetch", bare.path, "main"], at: source)
        try TeamProject.verify(source, repository: "https://github.com/test/project")
        let first = TeamTask(title: "Первая", detail: "Изоляция"), second = TeamTask(title: "Вторая", detail: "")
        let a = try TeamProject.makeWorktree(first, folder: source, room: "test", root: root.appendingPathComponent("worktrees"))
        let b = try TeamProject.makeWorktree(second, folder: source, room: "test", root: root.appendingPathComponent("worktrees"))
        precondition(a != b)
        try Data("changed".utf8).write(to: a.appendingPathComponent("code.txt"))
        try Data("local-only".utf8).write(to: a.appendingPathComponent(".env"))
        try Data("local-only".utf8).write(to: a.appendingPathComponent("private.pem"))
        try Data("new".utf8).write(to: a.appendingPathComponent("new.txt"))
        let untouched = try String(contentsOf: b.appendingPathComponent("code.txt"), encoding: .utf8)
        precondition(untouched == "original")
        let files = try TeamProject.changedFiles(a), digest = try TeamProject.fingerprint(a)
        precondition(files == ["code.txt", "new.txt"])
        let preview = try TeamProject.preview(a)
        precondition(preview.contains("changed") && preview.contains("new.txt") && !preview.contains("local-only"))
        try Data("changed after review".utf8).write(to: a.appendingPathComponent("code.txt"))
        do { _ = try TeamProject.commitAndPush(first, folder: a, repository: "https://github.com/test/project", expectedFiles: files, expectedFingerprint: digest); preconditionFailure("stale review accepted") }
        catch { precondition(error.localizedDescription.contains("после просмотра")) }
        let branch = try TeamProject.commitAndPush(first, folder: a, repository: "https://github.com/test/project", expectedFiles: files, expectedFingerprint: TeamProject.fingerprint(a))
        let remoteContent = try ProjectGit.run(["show", branch + ":code.txt"], at: bare).text
        precondition(remoteContent == "changed after review")
        let remoteSecret = try ProjectGit.run(["cat-file", "-e", branch + ":.env"], at: bare, allowFailure: true).code
        precondition(remoteSecret != 0)
        try ProjectGit.run(["add", "-f", ".env"], at: a)
        try ProjectGit.run(["commit", "-m", "bad local commit"], at: a)
        do { _ = try TeamProject.commitAndPush(first, folder: a, repository: "https://github.com/test/project", expectedFiles: TeamProject.changedFiles(a), expectedFingerprint: TeamProject.fingerprint(a)); preconditionFailure("secret commit accepted") }
        catch { precondition(error.localizedDescription.contains("найдены")) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GitHubStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            var completed = false, failure: Error?
            TeamProject.createPR(first, branch: branch, repository: "https://github.com/test/project", token: "test-placeholder", session: session) { result in
                DispatchQueue.main.async {
                    switch result { case .success(let url): precondition(url.hasSuffix("/pull/42")); case .failure(let error): failure = error }
                    completed = true
                }
            }
            let end = Date().addingTimeInterval(5)
            while !completed && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            if let error = failure { throw error }; precondition(completed)
        }
        precondition(GitHubStub.posts == 1)
        print("PASS: isolated worktrees, code preview, stale-content rejection, local commit/push, excluded secrets, committed-secret rejection, GitHub PR request and retry deduplication (mock API)")
    }
}
