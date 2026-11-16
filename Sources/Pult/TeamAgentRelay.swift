import Foundation

struct TeamAgentMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var type = "pult-agent-message-v1"
    var from: UUID
    var to: UUID
    var text: String
    var valid: Bool {
        type == "pult-agent-message-v1" && from != to &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 8000
    }

    static func proposals(in answer: String, from: UUID) -> [Self] {
        guard let start = answer.range(of: "```pult-agent"),
              let end = answer.range(of: "```", range: start.upperBound..<answer.endIndex) else { return [] }
        let data = Data(answer[start.upperBound..<end.lowerBound].utf8)
        struct Proposal: Decodable { var to: UUID; var text: String }
        guard data.count <= 32_000, let proposals = try? JSONDecoder().decode([Proposal].self, from: data) else { return [] }
        return proposals.prefix(3).map { Self(from: from, to: $0.to, text: $0.text) }.filter(\.valid)
    }
}

struct TeamAgentRelay {
    private var seen: Set<UUID> = []
    private var order: [UUID] = []
    private var inbox: [UUID: [TeamAgentMessage]] = [:]
    private var turns: [UUID: Int] = [:]
    var queued: Int { inbox.values.reduce(0) { $0 + $1.count } }

    mutating func accept(_ message: TeamAgentMessage, sender: String, board: BoardSnapshot) -> Bool {
        guard message.valid, !seen.contains(message.id),
              let source = board.tasks.first(where: { $0.id == message.from }), source.ownerID == sender,
              ![.done, .failed, .available].contains(source.status),
              let target = board.tasks.first(where: { $0.id == message.to }), target.ownerID != nil,
              ![.done, .failed, .available].contains(target.status) else { return false }
        seen.insert(message.id); order.append(message.id)
        if order.count > 2000 { seen.remove(order.removeFirst()) }
        return true
    }
    @discardableResult mutating func enqueue(_ message: TeamAgentMessage) -> Bool {
        guard inbox[message.to, default: []].count < 16 else { return false }
        inbox[message.to, default: []].append(message)
        return true
    }
    mutating func take(for task: UUID) -> [TeamAgentMessage] {
        guard turns[task, default: 0] < 8, let messages = inbox.removeValue(forKey: task), !messages.isEmpty else { return [] }
        turns[task, default: 0] += 1
        return messages
    }
    mutating func resume() { turns = [:] }
    mutating func clearInbox() { inbox = [:] }
}
