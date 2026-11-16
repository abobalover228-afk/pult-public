import Foundation
import Combine

struct TrashedChat: Codable, Identifiable {
    let id: String
    let path: String
    let title: String
    let date: Date
    let account: String
    let cwd: String
    var thread: ThreadInfo { ThreadInfo(id: id, path: path, title: title, date: date, account: account, cwd: cwd) }
    init(_ thread: ThreadInfo) {
        id = thread.id; path = thread.path; title = thread.title; date = thread.date; account = thread.account; cwd = thread.cwd
    }
}

final class ChatTrash: ObservableObject {
    static let shared = ChatTrash()
    @Published private(set) var entries: [TrashedChat]
    private let defaults: UserDefaults
    private let key = "pult.chatTrash.v1"
    var ids: Set<String> { Set(entries.map(\.id)) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([TrashedChat].self, from: $0) } ?? []
    }
    func move(_ threads: [ThreadInfo]) {
        let existing = ids
        entries += threads.filter { !existing.contains($0.id) }.map(TrashedChat.init)
        persist()
    }
    func restore(_ id: String) { entries.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) } }
}
