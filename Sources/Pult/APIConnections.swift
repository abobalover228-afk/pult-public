import AppKit
import Foundation
import Security
import SwiftUI

struct APIProblem: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    static func http(_ code: Int) -> Self {
        let text: String
        switch code {
        case 401, 403: text = "API отклонил доступ. Проверь ключ и разрешение на модель."
        case 404: text = "API endpoint или модель не найдены. Проверь base URL (обычно с /v1) и модель."
        case 408, 504: text = "API не успел ответить. Повтори запрос вручную."
        case 413: text = "Запрос слишком большой. Уменьши вложения или начни новый диалог."
        case 429: text = "API ограничил запрос: квота, баланс или частота. Остаток неизвестен."
        case 300..<400: text = "API перенаправляет запрос. Укажи конечный base URL; ключ не пересылался на другой адрес."
        case 500...599: text = "Сервис API временно недоступен. Повтори позже."
        default: text = "API вернул HTTP \(code). Проверь настройки и поддержку Chat Completions."
        }
        return Self(message: text)
    }
}

struct APIConnection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var target: String { "api:" + id.uuidString }
    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.model.isEmpty, value.name.count <= 120, value.model.count <= 200,
              !value.model.contains(where: { $0.isNewline }) else { throw APIProblem(message: "Укажи название подключения и модель.") }
        _ = try value.endpoint()
        return value
    }
    func endpoint() throws -> URL {
        guard var components = URLComponents(string: baseURL), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw APIProblem(message: "Нужен HTTPS base URL без логина, пароля, query и #. HTTP разрешён только для localhost.")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.path = path
        guard let url = components.url else { throw APIProblem(message: "Некорректный base URL.") }
        return url
    }
}

protocol APIKeyVault {
    func read(_ id: UUID) throws -> String?
    func write(_ secret: String, for id: UUID) throws
    func delete(_ id: UUID) throws
}
struct KeychainVault: APIKeyVault {
    let service = "local.pult.api-connections"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func read(_ id: UUID) throws -> String? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw APIProblem(message: "Нет доступа к ключу в Keychain. Разблокируй связку ключей и разреши доступ Пульту.")
        }
        return secret
    }
    func write(_ secret: String, for id: UUID) throws {
        let q = query(id), values = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item.merge(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIProblem(message: "Не удалось сохранить API-ключ в Keychain. Настройки не изменены.") }
    }
    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIProblem(message: "Не удалось удалить ключ из Keychain.") }
    }
}

final class APIConnectionStore: ObservableObject {
    static let shared = APIConnectionStore()
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PultConnections")
    @Published private(set) var connections: [APIConnection] = []
    @Published private(set) var loadError: String?
    @Published private(set) var revision = 0
    let file: URL
    let vault: APIKeyVault
    init(file: URL = APIConnectionStore.directory.appendingPathComponent("connections.json"), vault: APIKeyVault = KeychainVault()) {
        self.file = file; self.vault = vault
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                connections = try JSONDecoder().decode([APIConnection].self, from: Data(contentsOf: file))
                guard Set(connections.map(\.id)).count == connections.count else { throw APIProblem(message: "duplicate") }
                connections = try connections.map { try $0.validated() }
            } catch { loadError = "Не удалось прочитать API-настройки. Файл сохранён без изменений; проверь connections.json."; connections = [] }
        }
    }
    func connection(target: String) -> APIConnection? { connections.first { $0.target == target } }
    private func persist(_ rows: [APIConnection]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(rows)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func save(_ connection: APIConnection, newKey: String) throws {
        guard loadError == nil else { throw APIProblem(message: loadError!) }
        let connection = try connection.validated()
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains(where: { $0.isNewline || $0 == "\r" }), key.count <= 16384 else { throw APIProblem(message: "API-ключ должен быть одной строкой.") }
        let old = try vault.read(connection.id)
        guard !key.isEmpty || old?.isEmpty == false else { throw APIProblem(message: "Введи API-ключ. Он сохранится только в Keychain.") }
        let activeKey = key.isEmpty ? (old ?? "") : key
        if !activeKey.isEmpty, [connection.name, connection.model, connection.baseURL].contains(where: { $0.contains(activeKey) }) { throw APIProblem(message: "API-ключ должен находиться только в поле API-ключа, не в названии, URL или модели.") }
        var rows = connections.filter { $0.id != connection.id }; rows.append(connection)
        if !key.isEmpty { try vault.write(key, for: connection.id) }
        do { try persist(rows) }
        catch {
            if !key.isEmpty { if let old { try? vault.write(old, for: connection.id) } else { try? vault.delete(connection.id) } }
            throw APIProblem(message: "Не удалось сохранить настройки на диск. Проверь доступ к папке приложения.")
        }
        connections = rows; revision += 1
    }
    func remove(_ connection: APIConnection) throws {
        guard loadError == nil else { throw APIProblem(message: loadError!) }
        let old = try vault.read(connection.id)
        try vault.delete(connection.id)
        let rows = connections.filter { $0.id != connection.id }
        do { try persist(rows) }
        catch { if let old { try? vault.write(old, for: connection.id) }; throw APIProblem(message: "Не удалось удалить настройки с диска.") }
        connections = rows; revision += 1
    }
}

struct APIResult {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
}
final class CompatibleAPIClient: NSObject, URLSessionTaskDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func request(connection: APIConnection, key: String, messages: [JSON]) throws -> URLRequest {
        guard !key.isEmpty, !key.contains(where: { $0.isNewline || $0 == "\r" }) else { throw APIProblem(message: "API-ключ отсутствует или некорректен. Измени подключение.") }
        let connection = try connection.validated()
        var request = URLRequest(url: try connection.endpoint())
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": connection.model, "messages": messages, "stream": false])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    static func parse(data: Data, status: Int) throws -> APIResult {
        guard (200..<300).contains(status) else { throw APIProblem.http(status) }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let choice = (value["choices"] as? [JSON])?.first, let message = choice["message"] as? JSON else {
            throw APIProblem(message: "API вернул ответ в другом формате. Требуется совместимость с /chat/completions.")
        }
        if let tools = message["tool_calls"] as? [JSON], !tools.isEmpty { throw APIProblem(message: "Модель запросила инструменты. В API-чате Пульта поддерживаются текст и изображения, без выполнения инструментов.") }
        let text = message["content"] as? String ?? (message["content"] as? [JSON])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIProblem(message: "API вернул пустой ответ или отказ. Проверь модель и поддержку изображений.") }
        if choice["finish_reason"] as? String == "length" { throw APIProblem(message: "Ответ API обрезан по лимиту модели. Уточни запрос; автоматического повторного списания не было.") }
        let usage = value["usage"] as? JSON
        return APIResult(text: text, inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int)
    }
    func send(connection: APIConnection, key: String, messages: [JSON], completion: @escaping (Result<APIResult, APIProblem>) -> Void) {
        do {
            let request = try Self.request(connection: connection, key: key, messages: messages)
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.dataTask(with: request) { [weak self] data, response, error in
                let result: Result<APIResult, APIProblem>
                if let error = error as? URLError {
                    result = .failure(APIProblem(message: error.code == .cancelled ? "Запрос остановлен. API мог уже начать обработку." : error.code == .timedOut ? "API не ответил за 2 минуты. Повтори вручную." : "Не удалось связаться с API. Проверь сеть, HTTPS-сертификат и base URL."))
                } else if let response = response as? HTTPURLResponse, let data {
                    do {
                        let response = try Self.parse(data: data, status: response.statusCode)
                        result = .success(APIResult(text: response.text.replacingOccurrences(of: key, with: "[API key hidden]"), inputTokens: response.inputTokens, outputTokens: response.outputTokens))
                    }
                    catch { result = .failure(error as? APIProblem ?? APIProblem(message: "Не удалось разобрать ответ API.")) }
                } else { result = .failure(APIProblem(message: "Не получен HTTP-ответ от API.")) }
                self?.session?.finishTasksAndInvalidate(); self?.session = nil; self?.task = nil
                DispatchQueue.main.async { completion(result) }
            }
            task?.resume()
        } catch { completion(.failure(error as? APIProblem ?? APIProblem(message: "Не удалось подготовить запрос API."))) }
    }
    func cancel() { task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil }
}

struct APIStoredMessage: Codable {
    var role: String
    var text: String
    var images: [String]
    static func capture(_ items: [Item]) -> [Self] {
        items.compactMap { item in
            guard item.kind == .user || item.kind == .agent else { return nil }
            return Self(role: item.kind == .user ? "user" : "assistant", text: item.text, images: item.images)
        }
    }
    func wire() throws -> JSON {
        guard !images.isEmpty else { return ["role": role, "content": text] }
        var content: [JSON] = [["type": "text", "text": text]]
        for path in images {
            let url = URL(fileURLWithPath: path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 20_000_000,
                  let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                throw APIProblem(message: "Вложение недоступно, слишком велико или не является изображением. Удали его из запроса.")
            }
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]])
        }
        return ["role": role, "content": content]
    }
}
struct APIConversation: Codable {
    var id: UUID
    var connectionID: UUID
    var connectionName: String
    var directory: String
    var date: Date
    var messages: [APIStoredMessage]
}
enum APIHistory {
    static var directory = APIConnectionStore.directory.appendingPathComponent("history")
    static func save(_ conversation: APIConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(conversation.id.uuidString + ".json")
        try JSONEncoder().encode(conversation).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func threads() -> [ThreadInfo] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).compactMap { file in
            guard let value = try? JSONDecoder().decode(APIConversation.self, from: Data(contentsOf: file)) else { return nil }
            return ThreadInfo(id: "api:" + value.id.uuidString, path: file.path, title: String((value.messages.first?.text ?? "API-диалог").prefix(120)), date: value.date, account: value.connectionName + " · API", cwd: value.directory)
        }
    }
}
