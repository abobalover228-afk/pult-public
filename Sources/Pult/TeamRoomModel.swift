import AppKit
import SwiftUI

final class TeamRoomModel: ObservableObject {
    static let shared = TeamRoomModel()
    @Published var project = UserDefaults.standard.string(forKey: "team.project") ?? ""
    @Published var name = UserDefaults.standard.string(forKey: "team.name") ?? ""
    @Published var server = UserDefaults.standard.string(forKey: "team.rendezvous") ?? (Bundle.main.object(forInfoDictionaryKey: "PultRendezvousURL") as? String ?? "")
    @Published var code = ""
    @Published var invitation = ""
    @Published var messages: [TeamMessage] = []
    @Published var draft = ""
    @Published var status = "Создай комнату или вставь приглашение от кента"
    @Published var working = false
    @Published var connected = false
    @Published var peers = 0
    @Published var board = BoardSnapshot()
    @Published var boardReady = false
    @Published var selected: Set<UUID> = []
    @Published var repository = ""
    @Published var taskTitle = ""
    @Published var taskDetail = ""
    @Published var pendingClaims = false
    @Published var running: [UUID: UUID] = [:]
    @Published var publishing: Set<UUID> = []
    private var room: DirectRoom?
    private var canonical = TeamBoard()
    private var generation = UUID()
    private let queue = DispatchQueue(label: "pult.team.project", qos: .utility)
    private var pending: [UUID: (BoardRequest, ([TeamTask]) -> Void)] = [:]
    private var outbox: [UUID: BoardRequest] = [:]
    private var paths: [String: String] = [:]
    private var poll: Timer?
    var isHost: Bool { room?.id == room?.invitation.coordinator && room != nil }
    var identity: String { room?.id ?? "" }
    var hasSavedRoom: Bool { Secrets.read("PULT_TEAM_INVITATION") != nil }
    var canClaim: Bool { connected && boardReady && !pendingClaims && !working && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !project.isEmpty && !board.repository.isEmpty }
    private var cacheURL: URL? {
        guard let room = room else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pult/Rooms/" + room.invitation.room + ".json")
    }

    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Выбери корень локального Git-репозитория"
        if panel.runModal() == .OK, let url = panel.url {
            project = url.path; UserDefaults.standard.set(project, forKey: "team.project")
            queue.async {
                let remote = try? ProjectGit.run(["remote", "get-url", "origin"], at: url).text
                DispatchQueue.main.async { if let remote = remote, TeamRepository.slug(remote) != nil { self.repository = remote } }
            }
        }
    }

    func create() {
        guard !working, !connected, let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        working = true; status = "Создаю приглашение…"
        let token = generation
        DirectRoom.create(server: url, createToken: Secrets.read("PULT_ROOM_CREATE_TOKEN")) { [weak self] result in
            guard let self = self, self.generation == token else { return }
            self.working = false
            switch result {
            case .success(let invite):
                UserDefaults.standard.set(url.absoluteString, forKey: "team.rendezvous")
                UserDefaults.standard.set(invite.coordinator, forKey: "team.identity." + invite.room)
                self.enter(invite)
            case .failure(let error): self.status = error.localizedDescription
            }
        }
    }
    func join() {
        guard !working, !connected else { return }
        do { enter(try RoomInvitation.parse(code)) } catch { status = error.localizedDescription }
    }
    func restoreRoom() {
        guard let saved = Secrets.read("PULT_TEAM_INVITATION"), !connected else { return }
        code = saved; join()
    }
    private func enter(_ invite: RoomInvitation) {
        generation = UUID(); room?.stop(); messages = []; peers = 0; selected = []
        let key = "team.identity." + invite.room
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        let room = DirectRoom(invite, identity: id); self.room = room
        connected = true; invitation = invite.code; canonical = TeamBoard(); board = BoardSnapshot()
        pending = [:]; pendingClaims = false; publishing = []
        _ = Secrets.write("PULT_TEAM_INVITATION", invite.code)
        outbox = [:]
        if let data = UserDefaults.standard.data(forKey: "team.outbox." + invite.room), let operations = try? JSONDecoder().decode([BoardRequest].self, from: data) {
            for operation in operations { outbox[operation.id] = operation }
        }
        if let url = cacheURL, let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(BoardSnapshot.self, from: data), cached.tasks.count <= 100, cached.tasks.allSatisfy(\.valid) { board = cached }
        canonical.state = board; repository = board.repository; boardReady = isHost
        paths = UserDefaults.standard.dictionary(forKey: "team.paths." + invite.room) as? [String: String] ?? [:]
        room.onStatus = { [weak self] in self?.status = $0 }
        room.onPeers = { [weak self] in self?.peers = $0 }
        room.onMessages = { [weak self] in self?.messages = $0 }
        room.onEvent = { [weak self] sender, data in self?.receive(sender, data) }
        room.onPeerOpen = { [weak self] peer in
            guard let self = self else { return }
            if self.isHost { self.transmit(BoardEnvelope(snapshot: self.board), to: peer) }
            else if peer == invite.coordinator { self.request(BoardRequest(action: "sync")) }
        }
        room.start()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, !self.isHost else { return }
            if !self.request(BoardRequest(action: "sync")) { self.boardReady = false }
            for operation in Array(self.outbox.values) where self.pending[operation.id] == nil { self.request(operation) }
        }
        if invite.coordinator == nil { status = "Старое приглашение: для доски создай новую комнату" }
    }
    private func saveOutbox() {
        guard let room = room, let data = try? JSONEncoder().encode(Array(outbox.values)) else { return }
        UserDefaults.standard.set(data, forKey: "team.outbox." + room.invitation.room)
    }
    func reconnect() {
        guard running.isEmpty, let invite = try? RoomInvitation.parse(invitation) else { status = "Сначала останови агентов задач"; return }
        enter(invite)
    }
    func leave() {
        guard running.isEmpty && publishing.isEmpty else { status = "Агенты ещё работают. Останови их в главном чате перед выходом"; return }
        generation = UUID(); room?.stop(); room = nil; poll?.invalidate(); poll = nil
        invitation = ""; code = ""; connected = false; working = false; peers = 0
        boardReady = false; pending = [:]; pendingClaims = false; board = BoardSnapshot(); selected = []
        status = "Ты вышел из комнаты"
    }
    func send() {
        guard let room = room else { return }
        do {
            try room.send(TeamMessage(author: name.trimmingCharacters(in: .whitespacesAndNewlines), text: draft))
            UserDefaults.standard.set(name, forKey: "team.name"); draft = ""
        } catch { status = error.localizedDescription }
    }
    private func transmit(_ envelope: BoardEnvelope, to peer: String? = nil) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        _ = room?.sendEvent(data, to: peer)
    }
    private func receive(_ sender: String, _ data: Data) {
        guard let envelope = try? JSONDecoder().decode(BoardEnvelope.self, from: data), let room = room else { return }
        if isHost, let request = envelope.request {
            let reply = canonical.apply(request, sender: sender, host: identity)
            accept(reply); transmit(reply, to: sender)
            transmit(BoardEnvelope(snapshot: board))
        } else if sender == room.invitation.coordinator { accept(envelope) }
    }
    private func accept(_ envelope: BoardEnvelope) {
        if let snapshot = envelope.snapshot, snapshot.revision >= board.revision,
           snapshot.tasks.count <= 100, snapshot.tasks.allSatisfy(\.valid), Set(snapshot.tasks.map(\.id)).count == snapshot.tasks.count {
            board = snapshot; boardReady = true
            if !snapshot.repository.isEmpty { repository = snapshot.repository }
            selected = selected.intersection(Set(snapshot.tasks.filter { $0.status == .available }.map(\.id)))
            if let url = cacheURL, let bytes = try? JSONEncoder().encode(board) {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url, options: .atomic)
                } catch { status = "Доска получена, но не сохранена: " + error.localizedDescription }
            }
        }
        if let response = envelope.response, let operation = pending.removeValue(forKey: response) {
            outbox[response] = nil; saveOutbox()
            if operation.0.action == "claim" { pendingClaims = false }
            if let error = envelope.error { status = error }
            else { operation.1(board.tasks.filter { operation.0.ids.contains($0.id) }) }
        }
    }
    @discardableResult private func request(_ operation: BoardRequest, done: @escaping ([TeamTask]) -> Void = { _ in }) -> Bool {
        guard let room = room, let host = room.invitation.coordinator else { status = "Для доски нужно новое приглашение"; return false }
        if operation.action == "update" {
            for old in Array(outbox.values) where old.task?.id == operation.task?.id && old.id != operation.id {
                outbox[old.id] = nil; pending[old.id] = nil
            }
            outbox[operation.id] = operation; saveOutbox()
        }
        pending[operation.id] = (operation, done)
        if isHost {
            accept(canonical.apply(operation, sender: identity, host: host))
            transmit(BoardEnvelope(snapshot: board)); return true
        }
        guard let data = try? JSONEncoder().encode(BoardEnvelope(request: operation)), room.sendEvent(data, to: host) else {
            pending[operation.id] = nil; boardReady = false; status = "Создатель комнаты недоступен. Назначение не подтверждено"; return false
        }
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.generation == token, self.pending.removeValue(forKey: operation.id) != nil else { return }
            if operation.action == "claim" { self.pendingClaims = false }
            self.boardReady = false; self.status = "Нет подтверждения доски. Агенты не запущены; перепроверь назначение после восстановления связи"
        }
        return true
    }
    func addTask(title: String? = nil, detail: String? = nil) {
        let title = (title ?? taskTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail ?? taskDetail
        guard !title.isEmpty else { return }
        request(BoardRequest(action: "add", task: TeamTask(title: title, detail: detail))) { [weak self] _ in self?.taskTitle = ""; self?.taskDetail = "" }
    }
    func taskFrom(_ message: TeamMessage) {
        addTask(title: String(message.text.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "Задача"), detail: String(message.text.prefix(8000)))
    }
    func connectRepository() {
        guard TeamRepository.slug(repository) != nil else { status = "Вставь HTTPS-адрес репозитория GitHub"; return }
        request(BoardRequest(action: "repository", repository: repository)) { _ in self.status = "Репозиторий подключён: " + self.board.repository }
    }
    func cloneProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "В какую папку скачать репозиторий?"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let repo = board.repository.isEmpty ? repository : board.repository
        work("Скачиваю репозиторий…") { try TeamProject.clone(repo, into: parent).path } done: {
            self.project = $0; UserDefaults.standard.set($0, forKey: "team.project"); self.status = "Проект скачан"
        }
    }
    func pullProject() {
        guard running.isEmpty else { status = "Сначала дождись завершения задач"; return }
        let folder = URL(fileURLWithPath: project), repo = board.repository
        work("Обновляю проект…") {
            try TeamProject.verify(folder, repository: repo)
            guard try ProjectGit.run(["status", "--porcelain"], at: folder).text.isEmpty else { throw TeamRoomError("Есть незакоммиченные изменения. Обновление остановлено") }
            return try ProjectGit.run(["pull", "--ff-only", "--no-rebase", "--no-autostash"], at: folder).text
        } done: { self.status = $0 }
    }
    private func work<T>(_ message: String, operation: @escaping () throws -> T, done: @escaping (T) -> Void) {
        guard !working else { return }; working = true; status = message
        let token = generation
        queue.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.working = false
                switch result { case .success(let value): done(value); case .failure(let error): self.status = error.localizedDescription }
            }
        }
    }
    func claim(_ workspace: Workspace) {
        guard canClaim, !selected.isEmpty else { return }
        pendingClaims = true
        let operation = BoardRequest(action: "claim", ids: Array(selected), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if !request(operation, done: { tasks in self.launch(tasks, workspace: workspace) }) { pendingClaims = false }
    }
    func launch(_ tasks: [TeamTask], workspace: Workspace) {
        guard let room = room, !working else { return }
        let own = tasks.filter { $0.ownerID == identity && !running.values.contains($0.id) && $0.status != .done }
        guard !own.isEmpty else { return }
        working = true; let token = generation, repo = board.repository, folder = URL(fileURLWithPath: project), roomID = room.invitation.room
        queue.async {
            for task in own {
                do {
                    let path = try TeamProject.prepare(task, folder: folder, repository: repo, room: roomID)
                    DispatchQueue.main.async {
                        guard self.generation == token else { return }
                        self.paths[task.id.uuidString] = path.path
                        UserDefaults.standard.set(self.paths, forKey: "team.paths." + roomID)
                        let chat = workspace.newChat(select: true)
                        chat.cwd = path.path; chat.customTitle = task.title
                        self.running[chat.sessionID] = task.id
                        var update = task; update.status = .working; update.result = ""
                        self.request(BoardRequest(action: "update", task: update))
                        let prompt = "Задача команды: \(task.title)\n\n\(task.detail)\n\nРаботай только в своей папке \(path.path), ветка \(task.branch ?? ""). Не делай push, merge и не создавай PR: пользователь отправит результат кнопкой Пульта. Проверь результат и сообщи, что изменено и как проверено. Если обнаружишь дополнительные отдельные задачи, добавь в конце блок ```pult-tasks с JSON-массивом объектов {\"title\":\"…\",\"detail\":\"…\"} (до 5 задач)."
                        chat.send(prompt)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.generation == token else { return }
                        var failed = task; failed.status = .failed; failed.result = String(error.localizedDescription.prefix(2000))
                        self.request(BoardRequest(action: "update", task: failed)); self.status = failed.result
                    }
                }
            }
            DispatchQueue.main.async { if self.generation == token { self.working = false } }
        }
    }
    func agentEvent(_ chat: Chat, _ event: ChatEvent) {
        guard let id = running[chat.sessionID], var task = board.tasks.first(where: { $0.id == id }), task.ownerID == identity else { return }
        switch event {
        case .needsApproval, .needsAnswer: task.status = .needsAnswer
        case .finished(_, let failed):
            task.status = failed ? .failed : .review; task.result = String(chat.lastAnswer.prefix(2000))
            running[chat.sessionID] = nil
            if !failed { extractTasks(chat.lastAnswer) }
        }
        request(BoardRequest(action: "update", task: task))
    }
    func refreshAgent(_ chat: Chat) {
        guard let id = running[chat.sessionID], var task = board.tasks.first(where: { $0.id == id }), task.status == .needsAnswer, chat.status == .working else { return }
        task.status = .working
        request(BoardRequest(action: "update", task: task))
    }
    private func extractTasks(_ answer: String) {
        guard let start = answer.range(of: "```pult-tasks"), let end = answer.range(of: "```", range: start.upperBound..<answer.endIndex) else { return }
        struct Proposal: Decodable { let title: String; let detail: String }
        let text = String(answer[start.upperBound..<end.lowerBound])
        guard text.utf8.count <= 40000, let rows = try? JSONDecoder().decode([Proposal].self, from: Data(text.utf8)) else { return }
        for row in rows.prefix(5) where !board.tasks.contains(where: { $0.title == row.title }) { addTask(title: row.title, detail: row.detail) }
    }
    func openTask(_ task: TeamTask, workspace: Workspace) {
        if let id = running.first(where: { $0.value == task.id })?.key, let chat = workspace.chats.first(where: { $0.sessionID == id }) { workspace.activate(chat) }
    }
    func complete(_ task: TeamTask) { request(BoardRequest(action: "complete", ids: [task.id])) }
    func release(_ task: TeamTask) { request(BoardRequest(action: "release", ids: [task.id])) }
    func folder(_ task: TeamTask) -> URL? { paths[task.id.uuidString].map { URL(fileURLWithPath: $0) } }
    func preview(_ task: TeamTask, done: @escaping (String, [String], String) -> Void) {
        guard let path = folder(task), !running.values.contains(task.id) else { return }
        work("Проверяю изменения…") {
            (try TeamProject.preview(path), try TeamProject.changedFiles(path), try TeamProject.fingerprint(path))
        } done: { done($0.0, $0.1, $0.2) }
    }
    func publish(_ task: TeamTask, files: [String], fingerprint: String) {
        guard let folder = folder(task), !publishing.contains(task.id), !running.values.contains(task.id), task.ownerID == identity else { return }
        guard let token = Secrets.read("PULT_GITHUB_TOKEN"), !token.isEmpty else { status = "Сначала сохрани GitHub-токен в настройках команды"; return }
        publishing.insert(task.id); let repo = board.repository, generation = generation
        queue.async {
            do {
                let branch = try TeamProject.commitAndPush(task, folder: folder, repository: repo, expectedFiles: files, expectedFingerprint: fingerprint)
                TeamProject.createPR(task, branch: branch, repository: repo, token: token) { result in
                    DispatchQueue.main.async {
                        guard self.generation == generation else { return }
                        self.publishing.remove(task.id)
                        switch result {
                        case .success(let link):
                            var update = task; update.pullRequest = link; update.status = .review
                            self.request(BoardRequest(action: "update", task: update)); self.status = "PR создан: " + link
                        case .failure(let error): self.status = error.localizedDescription
                        }
                    }
                }
            } catch { DispatchQueue.main.async { if self.generation == generation { self.publishing.remove(task.id); self.status = error.localizedDescription } } }
        }
    }
}
