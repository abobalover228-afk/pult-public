import Foundation

@main struct AgentRoomChecks {
    @MainActor static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    @MainActor static func main() throws {
        let server = Process(), port = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", "import sys; sys.path.insert(0,'signaling'); from server import create_server; s=create_server(port=0); print(s.server_address[1],flush=True); s.serve_forever()"]
        server.standardOutput = port; server.standardError = FileHandle.standardError
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        var line = Data()
        while true {
            let data = port.fileHandleForReading.readData(ofLength: 1)
            if data.isEmpty || data.first == 10 { break }; line.append(data)
        }
        guard let number = Int(String(decoding: line, as: UTF8.self)) else { throw TeamRoomError("Test server did not start") }
        var invite: RoomInvitation?, failure: Error?
        DirectRoom.create(server: URL(string: "http://127.0.0.1:\(number)")!) {
            switch $0 { case .success(let value): invite = value; case .failure(let error): failure = error }
        }
        guard wait(10, until: { invite != nil || failure != nil }), let invitation = invite else {
            throw failure ?? TeamRoomError("Room creation timed out")
        }
        let alice = DirectRoom(invitation, identity: invitation.coordinator), bob = DirectRoom(invitation)
        defer { alice.stop(); bob.stop() }
        let api = TeamTask(title: "API", detail: "", status: .working, ownerID: alice.id)
        let ui = TeamTask(title: "UI", detail: "", status: .working, ownerID: bob.id)
        let board = BoardSnapshot(tasks: [api, ui])
        var aRelay = TeamAgentRelay(), bRelay = TeamAgentRelay()
        var aPeers = 0, bPeers = 0, rejectedSpoof = false, delivered = 0
        alice.onPeers = { aPeers = $0 }; bob.onPeers = { bPeers = $0 }
        alice.onEvent = { sender, data in
            guard let message = try? JSONDecoder().decode(TeamAgentMessage.self, from: data), aRelay.accept(message, sender: sender, board: board) else { return }
            precondition(aRelay.enqueue(message)); delivered += 1
        }
        bob.onEvent = { sender, data in
            guard let message = try? JSONDecoder().decode(TeamAgentMessage.self, from: data) else { return }
            if bRelay.accept(message, sender: sender, board: board) { precondition(bRelay.enqueue(message)) }
            else if message.from == ui.id { rejectedSpoof = true }
        }
        alice.start(); bob.start()
        guard wait(40, until: { aPeers == 1 && bPeers == 1 }) else { throw TeamRoomError("WebRTC connection timed out") }
        server.terminate(); server.waitUntilExit()
        let question = TeamAgentMessage(from: api.id, to: ui.id, text: "Нужен контракт JSON 🦊")
        let bytes = try JSONEncoder().encode(question)
        precondition(alice.sendEvent(bytes, to: bob.id))
        precondition(alice.sendEvent(bytes, to: bob.id))
        let spoof = TeamAgentMessage(from: ui.id, to: api.id, text: "Поддельный автор")
        let forged = try JSONEncoder().encode(spoof)
        precondition(alice.sendEvent(forged))
        guard wait(5, until: { bRelay.queued == 1 && rejectedSpoof }) else { throw TeamRoomError("Agent question, deduplication or ownership check failed") }
        let incoming = bRelay.take(for: ui.id)
        precondition(incoming == [question])
        let output = "```pult-agent\n[{\"to\":\"\(api.id)\",\"text\":\"Используй {items: []}\"}]\n```"
        let reply = TeamAgentMessage.proposals(in: output, from: ui.id)[0]
        let response = try JSONEncoder().encode(reply)
        precondition(bob.sendEvent(response)); precondition(bob.sendEvent(response))
        guard wait(5, until: { delivered == 1 }) else { throw TeamRoomError("Agent reply was not delivered") }
        precondition(aRelay.take(for: api.id) == [reply])
        print("PASS: agent question → addressed inbox → parsed reply → original agent over real WebRTC with rendezvous OFF; duplicate events and forged task authors rejected. Model responses simulated; no paid API calls.")
    }
}
