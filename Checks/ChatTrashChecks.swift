import Foundation

@main struct ChatTrashChecks {
    static func main() throws {
        let name = "pult-trash-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pult-trash-history-" + UUID().uuidString)
        try Data("original history".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let thread = ThreadInfo(id: UUID().uuidString, path: file.path, title: "Old chat", date: Date(), account: "test", cwd: "/tmp")
        let trash = ChatTrash(defaults: defaults)
        trash.move([thread]); trash.move([thread])
        precondition(trash.entries.count == 1)
        let reopened = ChatTrash(defaults: defaults)
        precondition(reopened.ids == Set([thread.id]) && reopened.entries[0].thread == thread)
        let original = try Data(contentsOf: file)
        precondition(original == Data("original history".utf8))
        reopened.restore(thread.id)
        precondition(ChatTrash(defaults: defaults).entries.isEmpty)
        precondition(FileManager.default.fileExists(atPath: file.path))
        print("PASS: trash persistence, duplicate removal, exact restoration and original history preserved")
    }
}
