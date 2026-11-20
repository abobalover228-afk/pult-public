import Foundation
import CryptoKit
import WebRTC

struct TeamMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let author: String
    let text: String
    var valid: Bool { !author.isEmpty && author.count <= 80 && !text.isEmpty && text.utf8.count <= 16_000 }
}

struct TeamRoomError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

struct RoomInvitation: Codable {
    let server: URL
    let room: String
    let access: String
    let key: Data
    var coordinator: String? = nil
    var code: String { server.appendingPathComponent("join").absoluteString + "#" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    static func parse(_ code: String) throws -> RoomInvitation {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded: String
        if value.hasPrefix("pult-room:") { encoded = String(value.dropFirst(10)) }
        else if let url = URL(string: value), ["https", "http", "pult"].contains(url.scheme ?? ""), let fragment = url.fragment { encoded = fragment }
        else { throw TeamRoomError("Неверная ссылка приглашения.") }
        guard value.count < 4000,
              let data = Data(base64Encoded: encoded),
              let invitation = try? JSONDecoder().decode(Self.self, from: data), invitation.key.count == 32,
              invitation.room.range(of: #"^[A-Za-z0-9_-]{20,80}$"#, options: .regularExpression) != nil,
              invitation.access.range(of: #"^[A-Za-z0-9_-]{20,80}$"#, options: .regularExpression) != nil,
              (invitation.coordinator == nil || UUID(uuidString: invitation.coordinator!) != nil),
              validServer(invitation.server) else { throw TeamRoomError("Неверный код приглашения.") }
        return invitation
    }
    static func validServer(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil,
              parts.password == nil, parts.query == nil, parts.fragment == nil, parts.host != nil,
              !parts.path.contains("..") else { return false }
        return parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(parts.host!))
    }
}

private struct Negotiation: Codable {
    let kind: String
    var sdp: String? = nil
    var candidate: String? = nil
    var mid: String? = nil
    var line: Int32? = nil
}

private struct RoomPacket: Codable {
    var messages: [TeamMessage] = []
    var event: Data? = nil
}

final class DirectRoom: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    let id: String
    let invitation: RoomInvitation
    var onEvent: ((String, Data) -> Void)?
    var onPeerOpen: ((String) -> Void)?
    var onMessages: (([TeamMessage]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPeers: ((Int) -> Void)?
    private(set) var messages: [TeamMessage] = []
    private var peers: [String: DirectPeer] = [:]
    private var cursor = 0
    private var stopped = false
    private var polling: URLSessionDataTask?
    private var operations: [UUID: URLSessionDataTask] = [:]
    private let session: URLSession
    private var retry: DispatchWorkItem?

    private let peerKey: String?

    /// peerKey закрепляет наш ID на сервере комнат: другой участник не сможет войти под ним.
    init(_ invitation: RoomInvitation, identity: String? = nil, peerKey: String? = nil) {
        self.id = identity ?? UUID().uuidString
        self.peerKey = peerKey
        self.invitation = invitation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 35
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
        super.init()
    }

    static func create(server: URL, createToken: String? = nil, done: @escaping (Result<RoomInvitation, Error>) -> Void) {
        guard RoomInvitation.validServer(server) else { done(.failure(TeamRoomError("Нужен HTTPS-адрес службы знакомства."))); return }
        var request = URLRequest(url: server.appendingPathComponent("v1/rooms"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = createToken { request.setValue(token, forHTTPHeaderField: "X-Pult-Create-Token") }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<RoomInvitation, Error>
            if let error = error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode == 201, let data = data,
                    let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                    let room = value["room"], let access = value["access"] {
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                result = .success(RoomInvitation(server: server, room: room, access: access, key: key, coordinator: UUID().uuidString))
            } else if (response as? HTTPURLResponse)?.statusCode == 403 {
                result = .failure(TeamRoomError("Создание комнат доступно владельцу сервера. Для входа используй приглашение."))
            } else { result = .failure(TeamRoomError("Не удалось создать комнату. Проверь адрес службы знакомства.")) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    private func request(_ action: String, body: [String: Any]? = nil, done: @escaping (Result<[String: Any], Error>) -> Void) -> URLSessionDataTask {
        var url = invitation.server.appendingPathComponent("v1/rooms/" + invitation.room + "/" + action)
        if action == "events" { url = URL(string: url.absoluteString + "?after=\(cursor)")! }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + invitation.access, forHTTPHeaderField: "Authorization")
        request.setValue(id, forHTTPHeaderField: "X-Pult-Peer")
        if let key = peerKey { request.setValue(key, forHTTPHeaderField: "X-Pult-Peer-Key") }
        if let body = body {
            request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let operation = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                self.operations[operation] = nil
                if let error = error { done(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data, data.count <= 1_000_000,
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    done(.failure(TeamRoomError("Служба знакомства недоступна (\(code))."))); return
                }
                done(.success(value))
            }
        }
        operations[operation] = task; task.resume(); return task
    }

    func start() {
        onStatus?("Ищем участников…")
        _ = request("join", body: [:]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                self.cursor = value["cursor"] as? Int ?? 0
                for peer in value["peers"] as? [String] ?? [] { self.addPeer(peer) }
                self.onStatus?("Комната открыта. Ждём прямого соединения.")
                self.poll()
            case .failure(let error): self.onStatus?(error.localizedDescription)
            }
        }
    }

    private func poll() {
        guard !stopped else { return }
        polling = request("events") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                for event in value["events"] as? [[String: Any]] ?? [] {
                    guard let sender = event["sender"] as? String, sender != self.id else { continue }
                    switch event["kind"] as? String {
                    case "join": self.addPeer(sender)
                    case "leave":
                        // Existing direct channels survive loss of rendezvous or its membership timer.
                        if self.peers[sender]?.open != true { self.peers[sender]?.close(); self.peers[sender] = nil }
                    case "signal":
                        guard let box = event["box"] as? String, let bytes = Data(base64Encoded: box),
                              let sealed = try? AES.GCM.SealedBox(combined: bytes),
                              let data = try? AES.GCM.open(sealed, using: SymmetricKey(data: self.invitation.key),
                                                         authenticating: self.aad(sender, self.id)),
                              let signal = try? JSONDecoder().decode(Negotiation.self, from: data) else { continue }
                        self.addPeer(sender, offer: false)
                        self.peers[sender]?.receive(signal)
                    default: break
                    }
                }
                self.cursor = value["cursor"] as? Int ?? self.cursor
                self.poll()
            case .failure:
                self.onStatus?(self.openCount > 0 ? "Прямая связь работает; служба знакомства недоступна." : "Нет связи со службой знакомства. Повторяем…")
                let retry = DispatchWorkItem { [weak self] in self?.poll() }
                self.retry = retry; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: retry)
            }
        }
    }

    private func aad(_ sender: String, _ recipient: String) -> Data { Data((invitation.room + "|" + sender + "|" + recipient).utf8) }

    private func signal(_ signal: Negotiation, to peer: String) {
        guard !stopped, let data = try? JSONEncoder().encode(signal),
              let sealed = try? AES.GCM.seal(data, using: SymmetricKey(data: invitation.key), authenticating: aad(id, peer)),
              let box = sealed.combined else { return }
        _ = request("signal", body: ["recipient": peer, "box": box.base64EncodedString()]) { [weak self] result in
            if case .failure = result { self?.onStatus?("Не удалось обменяться параметрами подключения. Переподключись к комнате.") }
        }
    }

    private func addPeer(_ peer: String, offer: Bool = true) {
        guard peer != id, peers[peer] == nil, peers.count < 7 else { return }
        onStatus?("Устанавливаем прямой канал…")
        let connection = DirectPeer(factory: Self.factory)
        peers[peer] = connection
        connection.onSignal = { [weak self] signal in self?.signal(signal, to: peer) }
        connection.onOpen = { [weak self, weak connection] in
            guard let self = self else { return }
            self.onPeers?(self.openCount); self.onStatus?("Прямое соединение · содержимое идёт между ПК")
            _ = connection?.send(RoomPacket(messages: Array(self.messages.suffix(100))))
            self.onPeerOpen?(peer)
        }
        connection.onPacket = { [weak self] packet in
            self?.merge(packet.messages)
            if let event = packet.event { self?.onEvent?(peer, event) }
        }
        connection.onClosed = { [weak self] in
            guard let self = self else { return }
            self.onPeers?(self.openCount)
            if self.openCount == 0 { self.onStatus?("Прямое соединение прервано. Переподключись к комнате.") }
        }
        connection.onFailed = { [weak self] in self?.onStatus?("Прямое соединение не установлено. Сеть может блокировать P2P; пересылка через сервер выключена.") }
        if offer && id < peer { connection.offer() }
    }

    private var openCount: Int { peers.values.filter(\.open).count }

    private func merge(_ incoming: [TeamMessage]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.prefix(100).filter { $0.valid && !known.contains($0.id) }
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in fresh { byID[message.id] = message }
        messages = Array(byID.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }.suffix(1000))
        onMessages?(messages)
    }

    func send(_ message: TeamMessage) throws {
        guard message.valid else { throw TeamRoomError("Укажи имя до 80 символов и сообщение до 16 КБ.") }
        guard openCount > 0 else { throw TeamRoomError("Пока нет прямого соединения с участниками.") }
        let delivered = peers.values.filter { $0.open && $0.send(RoomPacket(messages: [message])) }.count
        guard delivered > 0 else { throw TeamRoomError("Не удалось передать сообщение. Текст остался в поле ввода.") }
        merge([message])
        onStatus?("Передано в прямой канал: \(delivered) из \(openCount) участников")
    }

    @discardableResult func sendEvent(_ data: Data, to recipient: String? = nil) -> Bool {
        guard data.count <= 1_500_000 else { return false }
        return peers.filter { recipient == nil || $0.key == recipient }.values.filter { $0.open && $0.send(RoomPacket(event: data)) }.count > 0
    }

    func stop() {
        guard !stopped else { return }
        _ = request("leave", body: [:]) { _ in }
        stopped = true; retry?.cancel(); polling?.cancel()
        peers.values.forEach { $0.close() }; peers = [:]
        session.finishTasksAndInvalidate(); operations = [:]
        onPeers?(0)
    }
}

private final class DirectPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private var connection: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var pending: [RTCIceCandidate] = []
    private var hasRemote = false
    private var announcedOpen = false
    private struct Fragment: Codable { let id: UUID; let index: Int; let count: Int; let data: Data }
    private var fragments: [UUID: (Date, [Int: Data], Int)] = [:]
    private var timeout: DispatchWorkItem?
    var open: Bool { channel?.readyState == .open }
    var onSignal: ((Negotiation) -> Void)?
    var onOpen: (() -> Void)?
    var onPacket: ((RoomPacket) -> Void)?
    var onClosed: (() -> Void)?
    var onFailed: (() -> Void)?

    init(factory: RTCPeerConnectionFactory) {
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // No TURN server: the content path must be direct, or the connection fails.
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"])]
        connection = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let item = DispatchWorkItem { [weak self] in if self?.open != true { self?.onFailed?() } }
        timeout = item; DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: item)
    }

    func offer() {
        let config = RTCDataChannelConfiguration(); config.isOrdered = true
        channel = connection.dataChannel(forLabel: "pult-room-v1", configuration: config); channel?.delegate = self
        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            guard let sdp = sdp else { return }
            DispatchQueue.main.async { self?.setLocal(sdp, kind: "offer") }
        }
    }

    private func setLocal(_ sdp: RTCSessionDescription, kind: String) {
        connection.setLocalDescription(sdp) { [weak self] error in
            DispatchQueue.main.async {
                if error == nil { self?.onSignal?(Negotiation(kind: kind, sdp: sdp.sdp)) } else { self?.onFailed?() }
            }
        }
    }

    func receive(_ signal: Negotiation) {
        if signal.kind == "candidate", let text = signal.candidate, !text.contains(" typ relay "), text.utf8.count < 4096, let line = signal.line {
            let candidate = RTCIceCandidate(sdp: text, sdpMLineIndex: line, sdpMid: signal.mid)
            if hasRemote { connection.add(candidate) { _ in } } else if pending.count < 100 { pending.append(candidate) }
            return
        }
        guard ["offer", "answer"].contains(signal.kind), let text = signal.sdp, text.utf8.count < 32_000 else { return }
        connection.setRemoteDescription(RTCSessionDescription(type: signal.kind == "offer" ? .offer : .answer, sdp: text)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, error == nil else { self?.onFailed?(); return }
                self.hasRemote = true
                for candidate in self.pending { self.connection.add(candidate) { _ in } }; self.pending = []
                if signal.kind == "offer" {
                    self.connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
                        guard let sdp = sdp else { return }
                        DispatchQueue.main.async { self?.setLocal(sdp, kind: "answer") }
                    }
                }
            }
        }
    }

    func send(_ packet: RoomPacket) -> Bool {
        guard open else { return false }
        if packet.messages.count > 1 {
            return packet.messages.allSatisfy { send(RoomPacket(messages: [$0])) }
        }
        guard let data = try? JSONEncoder().encode(packet), data.count <= 2_000_000,
              (channel?.bufferedAmount ?? 0) + UInt64(data.count * 2) < 4_000_000 else { return false }
        let id = UUID(), count = (data.count + 11999) / 12000
        for index in 0..<count {
            let part = data.subdata(in: index * 12000..<min(data.count, (index + 1) * 12000))
            guard let bytes = try? JSONEncoder().encode(Fragment(id: id, index: index, count: count, data: part)),
                  channel?.sendData(RTCDataBuffer(data: bytes, isBinary: true)) == true else { return false }
        }
        return true
    }
    func close() { timeout?.cancel(); channel?.delegate = nil; channel?.close(); connection.delegate = nil; connection.close() }
    private func notifyOpen() {
        guard open, !announcedOpen else { return }
        announcedOpen = true; timeout?.cancel(); onOpen?()
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            if dataChannel.readyState == .open { self?.notifyOpen() }
            else if dataChannel.readyState == .closed { self?.onClosed?() }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.data.count <= 20_000, let fragment = try? JSONDecoder().decode(Fragment.self, from: buffer.data),
              fragment.count > 0, fragment.count <= 167, fragment.index >= 0, fragment.index < fragment.count,
              fragment.data.count <= 12000 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fragments = self.fragments.filter { Date().timeIntervalSince($0.value.0) < 30 }
            guard self.fragments[fragment.id] != nil || self.fragments.count < 8 else { return }
            var entry = self.fragments[fragment.id] ?? (Date(), [:], fragment.count)
            guard entry.2 == fragment.count else { return }
            entry.1[fragment.index] = fragment.data; self.fragments[fragment.id] = entry
            guard entry.1.count == fragment.count else { return }
            self.fragments[fragment.id] = nil
            var bytes = Data()
            for i in 0..<fragment.count { bytes.append(entry.1[i]!) }
            guard bytes.count <= 2_000_000, let packet = try? JSONDecoder().decode(RoomPacket.self, from: bytes), packet.messages.count <= 100 else { return }
            self.onPacket?(packet)
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !candidate.sdp.contains(" typ relay ") else { return }
        DispatchQueue.main.async { [weak self] in self?.onSignal?(Negotiation(kind: "candidate", candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex)) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { DispatchQueue.main.async { [weak self] in self?.onFailed?() } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in self?.channel = dataChannel; dataChannel.delegate = self; self?.notifyOpen() }
    }
}
