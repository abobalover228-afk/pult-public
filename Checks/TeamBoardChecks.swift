import Foundation

@main struct TeamBoardChecks {
    static func main() throws {
        var host = TeamBoard()
        _ = host.apply(BoardRequest(action: "repository", repository: "https://github.com/test/project"), sender: "alice", host: "alice")
        let task = TeamTask(title: "Общая задача", detail: "Проверить гонку")
        _ = host.apply(BoardRequest(action: "add", task: task), sender: "alice", host: "alice")
        let claim = BoardRequest(action: "claim", ids: [task.id], name: "Алиса")
        let first = host.apply(claim, sender: "alice", host: "alice")
        precondition(first.error == nil && host.state.tasks[0].ownerID == "alice")
        let retry = host.apply(claim, sender: "alice", host: "alice")
        precondition(first.snapshot == retry.snapshot && first.response == retry.response && retry.error == nil && host.state.revision == 3)
        let loser = host.apply(BoardRequest(action: "claim", ids: [task.id], name: "Боб"), sender: "bob", host: "alice")
        precondition(loser.error != nil && host.state.tasks[0].ownerID == "alice")
        var update = host.state.tasks[0]; update.status = .review; update.result = "Проверено"
        precondition(host.apply(BoardRequest(action: "update", task: update), sender: "bob", host: "alice").error != nil)
        precondition(host.apply(BoardRequest(action: "update", task: update), sender: "alice", host: "alice").error == nil)
        precondition(host.apply(BoardRequest(action: "complete", ids: [task.id]), sender: "bob", host: "alice").error != nil)
        precondition(host.apply(BoardRequest(action: "complete", ids: [task.id]), sender: "alice", host: "alice").error == nil)
        precondition(host.state.tasks[0].status == .done)
        let second = TeamTask(title: "Вторая", detail: "")
        _ = host.apply(BoardRequest(action: "add", task: second), sender: "bob", host: "alice")
        precondition(host.apply(BoardRequest(action: "claim", ids: [task.id, second.id], name: "Боб"), sender: "bob", host: "alice").error != nil)
        precondition(host.state.tasks[1].ownerID == nil)
        precondition(host.apply(BoardRequest(action: "repository", repository: "https://github.com/test/project"), sender: "bob", host: "alice").error != nil)
        precondition(host.apply(BoardRequest(action: "repository", repository: "https://github.com/test/project"), sender: "alice", host: "alice").error == nil)
        precondition(TeamRepository.slug("git@github.com:test/project.git") == "test/project")
        precondition(TeamRepository.slug("https://secret@github.com/test/project") == nil)
        precondition(TeamRepository.slug("https://github.com/test/project?token=secret") == nil)
        precondition(TeamRepository.validPR("https://github.com/test/project/pull/42", repository: host.state.repository))
        precondition(!TeamRepository.validPR("https://github.com/other/project/pull/42", repository: host.state.repository))
        let restored = try JSONDecoder().decode(BoardSnapshot.self, from: JSONEncoder().encode(host.state))
        precondition(restored == host.state)
        print("PASS: atomic claims, retry deduplication, ownership, all-or-nothing batch claims, review, GitHub validation and board persistence")
    }
}
