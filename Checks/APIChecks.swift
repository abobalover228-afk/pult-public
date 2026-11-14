import AppKit
import Foundation

final class MemoryVault: APIKeyVault {
    var values: [UUID: String] = [:]
    var failWrites = false
    func read(_ id: UUID) throws -> String? { values[id] }
    func write(_ secret: String, for id: UUID) throws { if failWrites { throw APIProblem(message: "Keychain недоступен") }; values[id] = secret }
    func delete(_ id: UUID) throws { values.removeValue(forKey: id) }
}
final class MockAPIProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status,data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class FakeAPIChat: APIChatTransport {
    var completions: [(Result<APIResult,APIProblem>) -> Void] = []
    var requests: [[JSON]] = []
    var cancelled = false
    func send(connection: APIConnection, key: String, messages: [JSON], completion: @escaping (Result<APIResult,APIProblem>) -> Void) { requests.append(messages); completions.append(completion) }
    func cancel() { cancelled = true }
}

@main struct APIChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        APIHistory.directory = dir.appendingPathComponent("history")
        let vault = MemoryVault()
        let store = APIConnectionStore(file: dir.appendingPathComponent("connections.json"), vault: vault)
        var connection = APIConnection(name: "Demo", baseURL: "https://example.invalid/v1/", model: "demo")
        let secret = "offline-test-credential-only"
        try store.save(connection, newKey: secret)
        let disk = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!disk.contains(secret) && !disk.contains("apiKey"))
        let savedKey = try vault.read(connection.id); precondition(savedKey == secret)
        connection.name = "Edited"; try store.save(connection, newKey: "")
        precondition(store.connection(target: connection.target)?.name == "Edited")
        vault.failWrites = true
        precondition((try? store.save(connection, newKey: "replacement-test-key")) == nil)
        vault.failWrites = false
        let stillSaved = try String(contentsOf: store.file, encoding: .utf8); precondition(!stillSaved.contains("replacement-test-key"))
        precondition((try? store.save(APIConnection(name: "Empty", baseURL: "https://example.invalid/v1", model: "demo"), newKey: "")) == nil)
        let reloaded = APIConnectionStore(file: store.file, vault: vault)
        precondition(reloaded.connections.count == 1)
        let endpoint = try connection.endpoint().absoluteString; precondition(endpoint == "https://example.invalid/v1/chat/completions")
        for url in ["http://example.com/v1", "https://user:pass@example.com", "https://example.com?key=secret", "file:///tmp/a"] {
            var bad = connection; bad.baseURL = url; precondition((try? bad.validated()) == nil)
        }
        var local = connection; local.baseURL = "http://127.0.0.1:9000/v1"; _ = try local.validated()
        var leaked = connection; leaked.name = secret; precondition((try? store.save(leaked, newKey: secret)) == nil)
        let request = try CompatibleAPIClient.request(connection: connection, key: secret, messages: [["role":"user","content":"hello"]])
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
        precondition(!String(data: request.httpBody!, encoding: .utf8)!.contains(secret))
        precondition((try? CompatibleAPIClient.request(connection: connection, key: "a\nb", messages: [])) == nil)
        for status in [401,403,404,429,500,302] {
            do { _ = try CompatibleAPIClient.parse(data: Data(secret.utf8), status: status); preconditionFailure() }
            catch { precondition(!error.localizedDescription.contains(secret)) }
        }
        precondition((try? CompatibleAPIClient.parse(data: Data("{}".utf8), status: 200)) == nil)
        precondition((try? CompatibleAPIClient.parse(data: Data(#"{"choices":[{"message":{"content":"","tool_calls":[{}]}}]}"#.utf8), status:200)) == nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockAPIProtocol.self]
        MockAPIProtocol.handler = { request in
            precondition(request.url!.host == "example.invalid")
            return (200, Data(("{\"choices\":[{\"message\":{\"content\":\"hello " + secret + "\"}}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}").utf8))
        }
        let transport = CompatibleAPIClient(configuration: config)
        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectTask = redirectSession.dataTask(with: request)
        var forwarded = true
        transport.urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) { forwarded = $0 != nil }
        precondition(!forwarded); redirectTask.cancel(); redirectSession.invalidateAndCancel()

        var networkFinished = false
        transport.send(connection: connection, key: secret, messages: [["role":"user","content":"hello"]]) { result in
            guard case .success(let value) = result else { preconditionFailure("mock request failed") }
            precondition(!value.text.contains(secret) && value.inputTokens == 7)
            networkFinished = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !networkFinished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(networkFinished)
        let chat = Chat(connectImmediately: false); chat.apiConnectionStore = store
        let fake = FakeAPIChat(); chat.makeAPIClient = { fake }; chat.chooseAPI(connection)
        precondition(chat.isAPI && chat.selectedAPI?.id == connection.id)
        chat.add(.user, "early context"); chat.add(.agent, "earlier answer")
        chat.send("new message")
        precondition(chat.busy && fake.requests.count == 1 && fake.requests[0].count == 3)
        chat.send("queued")
        precondition(chat.pendingMessages.count == 1 && chat.pendingMessages[0].provider == connection.target)
        fake.completions[0](.success(APIResult(text: "answer", inputTokens: 1, outputTokens: 2)))
        precondition(fake.requests.count == 2 && chat.pendingMessages.isEmpty)
        chat.interrupt(); precondition(fake.cancelled && !chat.busy)
        fake.completions.last?(.success(APIResult(text: "late answer", inputTokens: nil, outputTokens: nil)))
        precondition(!chat.items.contains { $0.text == "late answer" })
        precondition(chat.handleAPISlash("/mcp") && chat.items.last?.kind == .error)
        chat.newChat(); chat.chooseAPI(connection); chat.send("failure case")
        fake.completions.last?(.failure(APIProblem.http(429)))
        precondition(!chat.busy && chat.queuePaused && chat.items.last?.kind == .error)
        precondition(!chat.items.last!.text.contains(secret))
        chat.target = "claude"; precondition(!chat.isAPI)
        chat.chooseAPI(connection)
        let previousContext = chat.queueContext; chat.apiConfigurationDidChange()
        precondition(chat.queueContext != previousContext && chat.queuePaused)
        vault.values.removeValue(forKey: connection.id)
        let requestsBefore = fake.requests.count
        chat.send("preserve draft on missing key")
        precondition(fake.requests.count == requestsBefore && chat.items.contains { $0.kind == .user && $0.text == "preserve draft on missing key" })
        precondition((try? APIStoredMessage(role: "user", text: "image", images: ["/missing/image.png"]).wire()) == nil)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let imagePath = dir.appendingPathComponent("attachment.png")
        try image.representation(using: .png, properties: [:])!.write(to: imagePath)
        let imageWire = try APIStoredMessage(role: "user", text: "image", images: [imagePath.path]).wire()
        precondition((imageWire["content"] as? [JSON])?.count == 2)
        precondition(!APIHistory.threads().isEmpty)
        try store.remove(connection); let removedKey = try vault.read(connection.id); precondition(store.connections.isEmpty && removedKey == nil)
        let broken = dir.appendingPathComponent("broken.json"); try Data("invalid".utf8).write(to: broken)
        let corrupt = APIConnectionStore(file: broken, vault: vault); precondition(corrupt.loadError != nil && (try? corrupt.save(connection,newKey:secret)) == nil)
        print("PASS: metadata CRUD, Keychain abstraction, secret exclusion and redaction, URL validation, auth request, mock HTTP, errors, connection routing, history context, queue identity, cancellation, stale callbacks, CLI separation, corrupt configuration")
    }
}
