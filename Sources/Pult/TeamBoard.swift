import Foundation

enum TeamTaskStatus: String, Codable, CaseIterable {
    case available, working, needsAnswer, review, done, failed
    var label: String {
        switch self {
        case .available: return "Свободна"
        case .working: return "В работе"
        case .needsAnswer: return "Нужен ответ"
        case .review: return "На проверке"
        case .done: return "Готова"
        case .failed: return "Ошибка"
        }
    }
}

struct TeamTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var status: TeamTaskStatus = .available
    var ownerID: String? = nil
    var ownerName: String? = nil
    var branch: String? = nil
    var result: String = ""
    var pullRequest: String? = nil
    var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 && detail.utf8.count <= 8000 && result.utf8.count <= 8000 }
}

struct BoardSnapshot: Codable, Equatable {
    var revision = 0
    var tasks: [TeamTask] = []
    var repository = ""
}

struct BoardRequest: Codable {
    var id = UUID()
    var action: String
    var ids: [UUID] = []
    var name = ""
    var task: TeamTask? = nil
    var repository: String? = nil
}

struct BoardEnvelope: Codable {
    var request: BoardRequest? = nil
    var snapshot: BoardSnapshot? = nil
    var response: UUID? = nil
    var error: String? = nil
}

// Only the room creator changes canonical state. Claims are all-or-nothing.
struct TeamBoard {
    var state = BoardSnapshot()
    private var receipts: [UUID: (String, BoardEnvelope)] = [:]
    mutating func apply(_ request: BoardRequest, sender: String, host: String) -> BoardEnvelope {
        if let receipt = receipts[request.id] {
            guard receipt.0 == sender else { return BoardEnvelope(response: request.id, error: "Чужой запрос") }
            var reply = receipt.1; reply.snapshot = state; return reply
        }
        var error: String?
        let indices = state.tasks.indices.filter { request.ids.contains(state.tasks[$0].id) }
        switch request.action {
        case "sync": break
        case "repository":
            if sender != host { error = "Репозиторий подключает создатель комнаты" }
            else if state.tasks.contains(where: { $0.ownerID != nil }) && request.repository != state.repository { error = "Нельзя менять репозиторий, пока есть назначенные задачи" }
            else if let repo = request.repository, repo.isEmpty || TeamRepository.slug(repo) != nil { state.repository = repo }
            else { error = "Нужен адрес репозитория GitHub без токена" }
        case "add":
            if var task = request.task, task.valid, state.tasks.count < 100,
               !state.tasks.contains(where: { $0.id == task.id }) {
                task.status = .available; task.ownerID = nil; task.ownerName = nil
                task.branch = nil; task.result = ""; task.pullRequest = nil
                state.tasks.append(task)
            } else { error = "Неверная задача или доска заполнена (100 задач)" }
        case "claim":
            if request.ids.isEmpty || indices.count != Set(request.ids).count || request.name.isEmpty || request.name.count > 80 || indices.contains(where: { state.tasks[$0].status != .available }) {
                error = "Кто-то уже взял задачу. Обнови выбор."
            } else {
                for i in indices {
                    state.tasks[i].ownerID = sender; state.tasks[i].ownerName = request.name
                    state.tasks[i].status = .working
                    state.tasks[i].branch = "pult/task-" + state.tasks[i].id.uuidString.lowercased()
                }
            }
        case "update":
            if let task = request.task, task.valid, let i = state.tasks.firstIndex(where: { $0.id == task.id }), state.tasks[i].ownerID == sender,
               task.status != .available, task.status != .done,
               task.pullRequest == nil || TeamRepository.validPR(task.pullRequest!, repository: state.repository) {
                state.tasks[i].status = task.status; state.tasks[i].result = task.result
                state.tasks[i].pullRequest = task.pullRequest
            } else { error = "Обновить задачу может только исполнитель" }
        case "complete":
            if indices.count != 1 || state.tasks[indices[0]].status != .review || (sender != host && state.tasks[indices[0]].ownerID != sender) { error = "Сначала проверь результат задачи" }
            else { state.tasks[indices[0]].status = .done }
        case "release":
            if indices.count != 1 || state.tasks[indices[0]].ownerID != sender || state.tasks[indices[0]].pullRequest != nil || ![.failed, .review].contains(state.tasks[indices[0]].status) { error = "Освободить можно свою остановленную задачу без опубликованного PR" }
            else {
                let i = indices[0]; state.tasks[i].status = .available
                state.tasks[i].ownerID = nil; state.tasks[i].ownerName = nil
            }
        default: error = "Неизвестное действие"
        }
        if error == nil && request.action != "sync" { state.revision += 1 }
        let reply = BoardEnvelope(snapshot: state, response: request.id, error: error)
        receipts[request.id] = (sender, reply)
        if receipts.count > 2000 { receipts = [request.id: (sender, reply)] }
        return reply
    }
}

enum TeamRepository {
    static func slug(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git@github.com:") { text = String(text.dropFirst(15)) }
        else if let url = URLComponents(string: text), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil { text = String(url.path.dropFirst()) }
        else { return nil }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        guard text.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              !text.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return text
    }
    static func validPR(_ value: String, repository: String) -> Bool {
        guard let slug = slug(repository), let url = URLComponents(string: value), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil else { return false }
        return url.path.range(of: "^/" + NSRegularExpression.escapedPattern(for: slug) + #"/pull/[0-9]+$"#, options: .regularExpression) != nil
    }
}
