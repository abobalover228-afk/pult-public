import AppKit
import CryptoKit

final class Updater: ObservableObject {
    static let shared = Updater()
    static let official = "https://github.com/abobalover228-afk/pult-public"
    @Published var available = 0
    @Published var notes: [String] = []
    @Published var status = ""
    @Published var working = false
    @Published var remote = UserDefaults.standard.string(forKey: "updateRepo") ?? official
    @Published var auto = UserDefaults.standard.object(forKey: "updateAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "updateAuto") }
    }
    let source = (Bundle.main.object(forInfoDictionaryKey: "PultSource") as? String) ?? homeDir + "/Documents/pult"
    var commit: String { (Bundle.main.object(forInfoDictionaryKey: "PultCommit") as? String) ?? "dev" }
    var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }
    var hasRepo: Bool { FileManager.default.fileExists(atPath: source + "/.git") }
    private var timer: Timer?
    private var asset: URL?
    private var digest: String?
    private var releaseVersion = ""
    private var checking = false

    static func repository(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        guard let url = URLComponents(string: text), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return path
    }
    static func newer(_ candidate: String, than installed: String) -> Bool {
        let pattern = #"^\d+\.\d+\.\d+$"#
        guard candidate.range(of: pattern, options: .regularExpression) != nil else { return false }
        return candidate.compare(installed, options: .numeric) == .orderedDescending
    }
    private func http() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if Proxy.shared.enabled {
            config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Proxy.shared.port,
                                               "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Proxy.shared.port]
        }
        return URLSession(configuration: config)
    }
    func start() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.check() }
    }
    func setRemote(_ value: String) {
        guard !working else { return }
        guard let repo = Self.repository(value) else { status = "Нужен HTTPS-адрес GitHub: владелец/репозиторий."; return }
        remote = "https://github.com/" + repo
        UserDefaults.standard.set(remote, forKey: "updateRepo")
        available = 0; notes = []; asset = nil; digest = nil
        check(manual: true)
    }
    func check(manual: Bool = false) {
        guard !checking, !working, let repo = Self.repository(remote) else { return }
        checking = true
        if manual { status = "Проверяю GitHub Releases…" }
        let expectedRemote = remote
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/" + repo + "/releases?per_page=30")!)
        request.timeoutInterval = 25
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = http()
        session.dataTask(with: request) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                guard self.remote == expectedRemote else { self.check(manual: manual); return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    self.status = "Не удалось проверить релизы в " + repo; return
                }
                // «Последним» может быть релиз только для Windows: берём самый свежий, где есть Mac-архив.
                guard let release = releases.first(where: { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true
                        && (($0["assets"] as? [[String: Any]]) ?? []).contains(where: { $0["name"] as? String == "Pult-macOS.zip" }) }),
                      let tag = release["tag_name"] as? String else {
                    self.status = "В " + repo + " нет релиза с архивом Pult-macOS.zip"; return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Self.newer(version, than: self.version) else {
                    self.available = 0; self.notes = []; self.asset = nil
                    self.status = "Установлена актуальная версия · \(self.version). Репозиторий: \(repo)"; return
                }
                guard let assets = release["assets"] as? [[String: Any]],
                      let file = assets.first(where: { $0["name"] as? String == "Pult-macOS.zip" }),
                      let size = file["size"] as? Int, size > 0, size < 250_000_000,
                      let link = file["browser_download_url"] as? String,
                      link.hasPrefix("https://github.com/" + repo + "/releases/download/"),
                      let asset = URL(string: link), let digest = file["digest"] as? String,
                      digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                    self.status = "В релизе нет проверяемого архива Pult-macOS.zip."; return
                }
                self.asset = asset; self.digest = String(digest.dropFirst(7)); self.releaseVersion = version; self.available = 1
                self.notes = [release["name"] as? String ?? tag]
                self.status = "Доступна версия \(version) · \(repo)"
                if self.auto && !manual { self.installWhenIdle() }
            }
        }.resume()
    }
    private func installWhenIdle() {
        guard auto, available > 0, !working else { return }
        if Workspace.shared.anyBusy || TeamRoomModel.shared.connected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.installWhenIdle() }; return
        }
        install()
    }
    func install(pull: Bool = true) {
        guard pull else { status = "Локальная сборка доступна через build.sh в папке исходников."; return }
        guard !working, available > 0, let asset = asset, let digest = digest else { return }
        guard !Workspace.shared.anyBusy, !TeamRoomModel.shared.connected else { status = "Закончи работу агентов и выйди из общей комнаты перед обновлением."; return }
        working = true; status = "Скачиваю проверенный релиз…"
        let expectedVersion = releaseVersion
        let session = http()
        session.downloadTask(with: asset) { [weak self] location, response, error in
            defer { session.finishTasksAndInvalidate() }
            do {
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let location = location else { throw TeamRoomError("Не удалось скачать архив.") }
                let data = try Data(contentsOf: location, options: .mappedIfSafe)
                guard data.count < 250_000_000, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                    throw TeamRoomError("Контрольная сумма архива не совпала.")
                }
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("pult-update-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let archive = stage.appendingPathComponent("release.zip"); try data.write(to: archive)
                let unpack = Process(); unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unpack.arguments = ["-x", "-k", archive.path, stage.appendingPathComponent("unpacked").path]
                try unpack.run(); unpack.waitUntilExit()
                guard unpack.terminationStatus == 0 else { throw TeamRoomError("Не удалось распаковать релиз.") }
                let contents = FileManager.default.enumerator(at: stage.appendingPathComponent("unpacked"), includingPropertiesForKeys: nil)
                var candidate: URL?
                while let url = contents?.nextObject() as? URL {
                    if url.lastPathComponent == "Пульт.app" { candidate = url; break }
                }
                guard let app = candidate, let bundle = Bundle(url: app),
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
                      ["local.k.pult", "local.pultpublic.app"].contains(bundle.bundleIdentifier ?? ""),
                      FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Pult").path) else {
                    throw TeamRoomError("Архив не содержит ожидаемую версию Пульта.")
                }
                let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verify.arguments = ["--verify", "--deep", "--strict", app.path]
                try verify.run(); verify.waitUntilExit()
                guard verify.terminationStatus == 0 else { throw TeamRoomError("Подпись приложения не прошла проверку.") }
                // «Лимиты» из того же архива ставим, только если это наш бандл с целой подписью.
                var limits: URL?
                if let bundle = Bundle(url: app.deletingLastPathComponent().appendingPathComponent("Лимиты.app")), bundle.bundleIdentifier == "local.pultpublic.limits" {
                    let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    check.arguments = ["--verify", "--deep", "--strict", bundle.bundlePath]
                    try check.run(); check.waitUntilExit()
                    if check.terminationStatus == 0 { limits = bundle.bundleURL }
                }
                let verifiedLimits = limits
                DispatchQueue.main.async { self?.replace(with: app, limits: verifiedLimits) }
            } catch { DispatchQueue.main.async { self?.working = false; self?.status = error.localizedDescription } }
        }.resume()
    }
    private func replace(with candidate: URL, limits: URL? = nil) {
        guard !Workspace.shared.anyBusy, !TeamRoomModel.shared.connected else { working = false; status = "Обновление отложено: началась работа."; return }
        let target = URL(fileURLWithPath: Bundle.main.bundlePath)
        do {
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw TeamRoomError("Нет прав на папку приложения. Перенеси Пульт в ~/Applications.") }
            _ = try Self.replaceBundle(at: target, with: candidate)
            // «Лимиты» лежат рядом и выходят в том же архиве: без этого они навсегда остаются старыми.
            let installedLimits = target.deletingLastPathComponent().appendingPathComponent("Лимиты.app")
            if let limits = limits, FileManager.default.fileExists(atPath: installedLimits.path) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "local.pultpublic.limits").forEach { $0.terminate() }
                _ = try? Self.replaceBundle(at: installedLimits, with: limits)
            }
            working = false; available = 0; status = "Обновлено. Перезапускаю…"; relaunch()
        } catch { working = false; status = error.localizedDescription }
    }
    @discardableResult static func replaceBundle(at target: URL, with candidate: URL) throws -> URL {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: target.path + ".previous")
        let saved = fm.fileExists(atPath: backup.path) ? URL(fileURLWithPath: backup.path + "." + UUID().uuidString) : backup
        let incoming = target.deletingLastPathComponent().appendingPathComponent(".pult-incoming-" + UUID().uuidString + ".app")
        try fm.copyItem(at: candidate, to: incoming)
        try fm.moveItem(at: target, to: saved)
        do { try fm.moveItem(at: incoming, to: target) }
        catch { try? fm.moveItem(at: saved, to: target); throw error }
        return saved
    }
    func relaunch() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
