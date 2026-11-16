import Foundation
import CryptoKit

enum TeamProject {
    static func verify(_ folder: URL, repository: String) throws {
        guard let slug = TeamRepository.slug(repository) else { throw TeamRoomError("Подключи репозиторий GitHub") }
        let root = try ProjectGit.run(["rev-parse", "--show-toplevel"], at: folder).text
        guard URL(fileURLWithPath: root).standardizedFileURL == folder.standardizedFileURL else { throw TeamRoomError("Выбери корень репозитория") }
        let remote = try ProjectGit.run(["remote", "get-url", "origin"], at: folder).text
        guard TeamRepository.slug(remote)?.lowercased() == slug.lowercased() else { throw TeamRoomError("Origin этой папки отличается от репозитория команды") }
    }

    static func clone(_ repository: String, into parent: URL) throws -> URL {
        guard let slug = TeamRepository.slug(repository) else { throw TeamRoomError("Неверный адрес GitHub") }
        let destination = parent.appendingPathComponent(String(slug.split(separator: "/").last!))
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw TeamRoomError("Папка уже существует. Выбери её кнопкой «Папка проекта»") }
        try ProjectGit.run(["clone", "--", "https://github.com/" + slug + ".git", destination.path], at: parent)
        return destination
    }

    static func prepare(_ task: TeamTask, folder: URL, repository: String, room: String) throws -> URL {
        try verify(folder, repository: repository)
        let refs = try ProjectGit.run(["ls-remote", "--symref", "origin", "HEAD"], at: folder).text
        guard let line = refs.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }),
              let ref = line.split(separator: "\t").first.map(String.init)?.dropFirst(5), ref.hasPrefix("refs/heads/") else { throw TeamRoomError("В репозитории пока нет основной ветки. Сначала загрузи исходный код") }
        try ProjectGit.run(["fetch", "origin", String(ref)], at: folder)
        return try makeWorktree(task, folder: folder, room: room)
    }

    static func makeWorktree(_ task: TeamTask, folder: URL, room: String, root: URL? = nil) throws -> URL {
        let branch = "pult/task-" + task.id.uuidString.lowercased()
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pult/Worktrees/" + room)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let directory = base.appendingPathComponent(task.id.uuidString)
        if FileManager.default.fileExists(atPath: directory.path) {
            let actual = try ProjectGit.run(["branch", "--show-current"], at: directory).text
            guard actual == branch else { throw TeamRoomError("Рабочая папка занята другой веткой") }
            return directory
        }
        let exists = try ProjectGit.run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], at: folder, allowFailure: true).code == 0
        if !exists { try ProjectGit.run(["update-ref", "refs/pult/bases/" + task.id.uuidString.lowercased(), "FETCH_HEAD"], at: folder) }
        try ProjectGit.run(exists ? ["worktree", "add", directory.path, branch] : ["worktree", "add", "-b", branch, directory.path, "FETCH_HEAD"], at: folder)
        return directory
    }

    static func excluded(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        return parts.contains { $0 == ".env" || $0.hasPrefix(".env.") && $0 != ".env.example" || [".ssh", ".aws", "node_modules", ".build"].contains($0) || $0.hasSuffix(".pem") || $0.hasSuffix(".key") || $0 == "credentials.json" }
    }

    static func changedFiles(_ folder: URL) throws -> [String] {
        let data = try ProjectGit.run(["ls-files", "-z", "--modified", "--others", "--exclude-standard"], at: folder).data
        let deleted = try ProjectGit.run(["ls-files", "-z", "--deleted"], at: folder).data
        return Array(Set((data + deleted).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })).filter { !excluded($0) }.sorted()
    }

    static func baseRef(_ folder: URL) throws -> String {
        let branch = try ProjectGit.run(["branch", "--show-current"], at: folder).text
        guard branch.hasPrefix("pult/task-"), UUID(uuidString: String(branch.dropFirst(10))) != nil else { throw TeamRoomError("Это не ветка задачи Пульта") }
        let ref = "refs/pult/bases/" + String(branch.dropFirst(10))
        _ = try ProjectGit.run(["rev-parse", "--verify", ref], at: folder)
        return ref
    }

    static func preview(_ folder: URL) throws -> String {
        let files = try changedFiles(folder)
        let base = try baseRef(folder)
        let diff = try ProjectGit.run(["diff", "--no-ext-diff", "--no-textconv", base, "--", ".", ":(exclude)**/.env", ":(exclude).env", ":(exclude)**/*.pem", ":(exclude)**/*.key"], at: folder).text
        var newFiles = ""
        for file in files {
            let tracked = try ProjectGit.run(["ls-files", "--error-unmatch", "--", file], at: folder, allowFailure: true).code == 0
            if !tracked, let bytes = try? Data(contentsOf: folder.appendingPathComponent(file)), let text = String(data: bytes.prefix(24000), encoding: .utf8) {
                newFiles += "\n\nНовый файл: " + file + "\n" + text + (bytes.count > 24000 ? "\n[Обрезано; открой файл для полного просмотра]" : "")
            }
        }
        return "Файлы к публикации:\n" + files.joined(separator: "\n") + "\n\n" + String(diff.prefix(160000)) + newFiles + "\n\n.env, ключи и служебные папки исключены. Проверь содержимое файлов перед отправкой."
    }

    static func fingerprint(_ folder: URL) throws -> String {
        var hash = SHA256()
        hash.update(data: try ProjectGit.run(["rev-parse", "HEAD"], at: folder).data)
        for file in try changedFiles(folder) {
            hash.update(data: Data((file + "\u{0}").utf8))
            let url = folder.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path), let input = try? FileHandle(forReadingFrom: url) {
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk) }
            } else { hash.update(data: Data("deleted".utf8)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func commitAndPush(_ task: TeamTask, folder: URL, repository: String, expectedFiles: [String], expectedFingerprint: String) throws -> String {
        try verify(folder, repository: repository)
        let branch = "pult/task-" + task.id.uuidString.lowercased()
        guard try ProjectGit.run(["branch", "--show-current"], at: folder).text == branch else { throw TeamRoomError("Ветка задачи изменилась") }
        let files = try changedFiles(folder)
        guard files == expectedFiles, try fingerprint(folder) == expectedFingerprint else { throw TeamRoomError("Код изменился после просмотра. Открой изменения повторно") }
        let committed = try ProjectGit.run(["diff", "--name-only", "-z", try baseRef(folder) + "...HEAD"], at: folder).data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !committed.contains(where: excluded) else { throw TeamRoomError("В коммитах ветки найдены .env, ключи или служебные файлы. Убери их из истории ветки перед push") }
        let staged = try ProjectGit.run(["diff", "--cached", "--name-only", "-z"], at: folder).data
        guard staged.isEmpty else { throw TeamRoomError("Есть заранее подготовленный коммит. Разбери его с агентом перед публикацией") }
        if !files.isEmpty {
            try ProjectGit.run(["add", "--"] + files, at: folder)
            try ProjectGit.run(["commit", "-m", String(task.title.prefix(160))], at: folder)
        }
        try ProjectGit.run(["push", "--set-upstream", "origin", branch], at: folder)
        return branch
    }

    static func createPR(_ task: TeamTask, branch: String, repository: String, token: String, session: URLSession = .shared, done: @escaping (Result<String, Error>) -> Void) {
        guard let slug = TeamRepository.slug(repository), !token.isEmpty else { done(.failure(TeamRoomError("Укажи GitHub-токен с доступом к Pull requests в настройках команды"))); return }
        func request(_ path: String, method: String = "GET", body: [String: String]? = nil, completion: @escaping (Result<Any, Error>) -> Void) {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/" + slug + path)!)
            req.httpMethod = method; req.timeoutInterval = 30
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Pult", forHTTPHeaderField: "User-Agent")
            if let body = body { req.httpBody = try? JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            session.dataTask(with: req) { data, response, error in
                if let error = error { completion(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data = data, let json = try? JSONSerialization.jsonObject(with: data) else {
                    completion(.failure(TeamRoomError("GitHub API: код \((response as? HTTPURLResponse)?.statusCode ?? 0). Ветка сохранена; можно повторить создание PR."))); return
                }
                completion(.success(json))
            }.resume()
        }
        request("") { result in
            guard case .success(let json) = result, let repo = json as? [String: Any], let base = repo["default_branch"] as? String else {
                if case .failure(let error) = result { done(.failure(error)) } else { done(.failure(TeamRoomError("GitHub не вернул основную ветку"))) }; return
            }
            let owner = slug.split(separator: "/")[0]
            let query = (String(owner) + ":" + branch).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            request("/pulls?state=open&head=" + query) { existing in
                if case .failure(let error) = existing { done(.failure(error)); return }
                if case .success(let json) = existing, let rows = json as? [[String: Any]], let link = rows.first?["html_url"] as? String, TeamRepository.validPR(link, repository: repository) { done(.success(link)); return }
                request("/pulls", method: "POST", body: ["title": String(task.title.prefix(160)), "head": branch, "base": base, "body": "Задача Пульта: " + task.id.uuidString + "\n\n" + task.detail + "\n\nРезультат:\n" + task.result]) { result in
                    switch result {
                    case .success(let json):
                        if let link = (json as? [String: Any])?["html_url"] as? String, TeamRepository.validPR(link, repository: repository) { done(.success(link)) }
                        else { done(.failure(TeamRoomError("GitHub не вернул ссылку на PR"))) }
                    case .failure(let error): done(.failure(error))
                    }
                }
            }
        }
    }
}
