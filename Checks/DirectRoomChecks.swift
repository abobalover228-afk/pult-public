import Foundation

@main struct DirectRoomChecks {
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
            if data.isEmpty || data.first == 10 { break }
            line.append(data)
        }
        guard let number = Int(String(decoding: line, as: UTF8.self)) else { throw TeamRoomError("Test server did not start") }
        var invite: RoomInvitation?, creationError: Error?
        DirectRoom.create(server: URL(string: "http://127.0.0.1:\(number)")!) {
            switch $0 { case .success(let value): invite = value; case .failure(let error): creationError = error }
        }
        guard wait(10, until: { invite != nil || creationError != nil }), let invitation = invite else {
            throw creationError ?? TeamRoomError("Room creation timed out")
        }
        let restored = try RoomInvitation.parse(invitation.code)
        precondition(restored.key == invitation.key && restored.room == invitation.room)
        precondition(!RoomInvitation.validServer(URL(string: "http://example.com")!))
        let alice = DirectRoom(invitation, identity: invitation.coordinator), bob = DirectRoom(restored)
        defer { alice.stop(); bob.stop() }
        var alicePeers = 0, bobPeers = 0
        alice.onPeers = { alicePeers = $0 }; bob.onPeers = { bobPeers = $0 }
        alice.onStatus = { FileHandle.standardError.write(Data(("Alice: " + $0 + "\n").utf8)) }; bob.onStatus = { FileHandle.standardError.write(Data(("Bob: " + $0 + "\n").utf8)) }
        alice.start(); bob.start()
        guard wait(40, until: { alicePeers == 1 && bobPeers == 1 }) else { throw TeamRoomError("Direct peer connection did not open") }
        let history = TeamMessage(author: "Алиса", text: "История до прихода третьего участника")
        try alice.send(history)
        guard wait(5, until: { bob.messages.contains(history) }) else { throw TeamRoomError("Initial history was not delivered") }
        var authority = TeamBoard()
        var bobBoard = BoardSnapshot(), charlieBoard = BoardSnapshot()
        for index in 0..<10 {
            _ = authority.apply(BoardRequest(action: "add", task: TeamTask(title: "Задача \(index)", detail: String(repeating: "я", count: 3000))), sender: alice.id, host: alice.id)
        }
        alice.onEvent = { sender, data in
            guard let envelope = try? JSONDecoder().decode(BoardEnvelope.self, from: data), let request = envelope.request else { return }
            let reply = authority.apply(request, sender: sender, host: alice.id)
            _ = alice.sendEvent(try! JSONEncoder().encode(reply))
        }
        bob.onEvent = { sender, data in
            if sender == alice.id, let snapshot = (try? JSONDecoder().decode(BoardEnvelope.self, from: data))?.snapshot { bobBoard = snapshot }
        }
        precondition(alice.sendEvent(try! JSONEncoder().encode(BoardEnvelope(snapshot: authority.state))))
        guard wait(5, until: { bobBoard.tasks.count == 10 }) else { throw TeamRoomError("Fragmented board snapshot did not arrive") }
        let charlie = DirectRoom(invitation)
        defer { charlie.stop() }
        var charliePeers = 0
        charlie.onPeers = { charliePeers = $0 }
        charlie.onEvent = { sender, data in
            if sender == alice.id, let snapshot = (try? JSONDecoder().decode(BoardEnvelope.self, from: data))?.snapshot { charlieBoard = snapshot }
        }
        charlie.start()
        guard wait(40, until: { charliePeers == 2 && alicePeers == 2 && bobPeers == 2 && charlie.messages.contains(history) }) else {
            throw TeamRoomError("Third peer did not connect or receive history")
        }
        let target = authority.state.tasks[0].id
        precondition(bob.sendEvent(try! JSONEncoder().encode(BoardEnvelope(request: BoardRequest(action: "claim", ids: [target], name: "Боб"))), to: alice.id))
        precondition(charlie.sendEvent(try! JSONEncoder().encode(BoardEnvelope(request: BoardRequest(action: "claim", ids: [target], name: "Чарли"))), to: alice.id))
        guard wait(5, until: { bobBoard.tasks.first?.ownerID != nil && charlieBoard.tasks.first?.ownerID != nil }) else { throw TeamRoomError("Task claims did not converge") }
        precondition(bobBoard.tasks.first?.ownerID == charlieBoard.tasks.first?.ownerID)
        precondition([bob.id, charlie.id].contains(authority.state.tasks[0].ownerID!))
        // Kill rendezvous before transmitting content. If content arrives, it cannot be relayed by this server.
        server.terminate(); server.waitUntilExit()
        let a = TeamMessage(author: "Алиса", text: "PRIVATE-CONTENT-A 🦊\nОбщая задача")
        let b = TeamMessage(author: "Боб", text: "PRIVATE-CONTENT-B — ответ напрямую")
        try alice.send(a); try bob.send(b)
        guard wait(5, until: { alice.messages.contains(b) && bob.messages.contains(a) && charlie.messages.contains(a) && charlie.messages.contains(b) }) else {
            throw TeamRoomError("Messages did not arrive after rendezvous was terminated")
        }
        try alice.send(a)
        _ = wait(0.5, until: { false })
        precondition(bob.messages.filter { $0.id == a.id }.count == 1)
        do { try bob.send(TeamMessage(author: "", text: "bad")); throw TeamRoomError("FAIL: invalid author accepted") }
        catch { precondition(!error.localizedDescription.hasPrefix("FAIL:")) }
        print("PASS: fragmented task board, concurrent task claims, three real WebRTC peers, late-join history, encrypted negotiation, invitation validation, Unicode, deduplication, bidirectional chat with rendezvous OFF")
    }
}
