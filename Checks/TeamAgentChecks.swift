import Foundation

@main struct TeamAgentChecks {
    static func main() throws {
        let a = TeamTask(title: "API", detail: "", status: .working, ownerID: "alice")
        let b = TeamTask(title: "UI", detail: "", status: .review, ownerID: "bob")
        var board = BoardSnapshot(tasks: [a, b])
        let message = TeamAgentMessage(from: a.id, to: b.id, text: "Какой формат ответа? 🦊")
        var relay = TeamAgentRelay()
        precondition(!relay.accept(message, sender: "mallory", board: board))
        precondition(relay.accept(message, sender: "alice", board: board))
        precondition(!relay.accept(message, sender: "alice", board: board))
        precondition(relay.enqueue(message))
        precondition(relay.take(for: a.id).isEmpty)
        precondition(relay.take(for: b.id) == [message])
        for _ in 0..<7 {
            precondition(relay.enqueue(message))
            precondition(relay.take(for: b.id).count == 1)
        }
        precondition(relay.enqueue(message))
        precondition(relay.take(for: b.id).isEmpty && relay.queued == 1)
        relay.resume()
        precondition(relay.take(for: b.id).count == 1 && relay.queued == 0)
        for _ in 0..<16 { precondition(relay.enqueue(message)) }
        precondition(!relay.enqueue(message) && relay.queued == 16)
        relay.clearInbox(); precondition(relay.queued == 0)
        board.tasks[1].status = .done
        precondition(!relay.accept(TeamAgentMessage(from: a.id, to: b.id, text: "late"), sender: "alice", board: board))
        precondition(!TeamAgentMessage(from: a.id, to: a.id, text: "loop").valid)
        precondition(!TeamAgentMessage(from: a.id, to: b.id, text: String(repeating: "я", count: 4001)).valid)
        let answer = "Ответ\n```pult-agent\n[{\"to\":\"\(b.id)\",\"text\":\"Формат JSON\"}]\n```"
        let proposals = TeamAgentMessage.proposals(in: answer, from: a.id)
        precondition(proposals.count == 1 && proposals[0].to == b.id && proposals[0].text == "Формат JSON")
        precondition(TeamAgentMessage.proposals(in: "```pult-agent\nnot-json\n```", from: a.id).isEmpty)
        let roundtrip = try JSONDecoder().decode(TeamAgentMessage.self, from: JSONEncoder().encode(message))
        precondition(roundtrip == message)
        print("PASS: sender ownership, replay rejection, addressed inbox, 8-turn budget, resume, queue bounds, disabled inbox clearing, completed-task rejection, self-loop rejection, UTF-8 limits and agent output parsing")
    }
}
