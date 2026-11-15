// Автообновление: Пульт следит за своим репозиторием на GitHub, подтягивает новые коммиты,
// пересобирается из исходников и перезапускается. Сборка локальная — подпись и права не слетают.
import AppKit
import Foundation

final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var available = 0                    // сколько новых коммитов на GitHub
    @Published var notes: [String] = []
    @Published var status = ""
    @Published var working = false
    @Published var remote = ""
    @Published var auto = UserDefaults.standard.object(forKey: "updateAuto") as? Bool ?? false {
        didSet { UserDefaults.standard.set(auto, forKey: "updateAuto") }
    }
    private var timer: Timer?

    @Published var source: String = UserDefaults.standard.string(forKey: "updateSource") ?? (Bundle.main.object(forInfoDictionaryKey: "PultSource") as? String) ?? homeDir + "/Documents/pult-public"
    func setSource(_ path: String) {
        guard !working else { return }
        guard FileManager.default.fileExists(atPath: path + "/.git"), FileManager.default.fileExists(atPath: path + "/build.sh") else { status = "Выбери git-клон Пульта с build.sh."; return }
        source = path; UserDefaults.standard.set(path, forKey: "updateSource")
        timer?.invalidate(); start()
    }
    var commit: String { (Bundle.main.object(forInfoDictionaryKey: "PultCommit") as? String) ?? "dev" }
    var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?" }
    var hasRepo: Bool { FileManager.default.fileExists(atPath: source + "/.git") }

    /// Команда в папке исходников; ответ на главном потоке: (код, вывод).
    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60, _ done: @escaping (Int32, String) -> Void) {
        let dir = source
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["GIT_TERMINAL_PROMPT"] = "0"
            env.merge(Proxy.shared.env) { _, new in new }
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { DispatchQueue.main.async { done(-1, error.localizedDescription) }; return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(p.terminationStatus, text) }
        }
    }
    private func git(_ args: [String], timeout: TimeInterval = 60, _ done: @escaping (Int32, String) -> Void) { run("/usr/bin/git", args, timeout: timeout, done) }

    func start() {
        guard hasRepo else { status = "Исходники не найдены: " + source; return }
        git(["remote", "get-url", "origin"]) { [weak self] code, out in
            self?.remote = code == 0 ? out : ""
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    func setRemote(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasRepo, !clean.isEmpty else { return }
        git(["remote", "remove", "origin"]) { [weak self] _, _ in
            self?.git(["remote", "add", "origin", clean]) { code, out in
                self?.remote = code == 0 ? clean : ""
                self?.status = code == 0 ? "Репозиторий привязан." : "Не удалось привязать: " + out
                if code == 0 { self?.check(manual: true) }
            }
        }
    }

    func check(manual: Bool = false) {
        guard hasRepo, !working else { return }
        guard !remote.isEmpty else { status = "GitHub не привязан — укажи адрес репозитория."; return }
        if manual { status = "Проверяю…" }
        git(["fetch", "--quiet", "origin"], timeout: 40) { [weak self] code, out in
            guard let self = self else { return }
            guard code == 0 else { if manual || self.status.isEmpty { self.status = "GitHub недоступен: " + String(out.suffix(160)) }; return }
            self.git(["rev-list", "--count", "HEAD..@{upstream}"]) { code, out in
                guard code == 0, let count = Int(out) else {
                    self.git(["rev-list", "--count", "HEAD..origin/main"]) { code, out in self.found(code == 0 ? Int(out) ?? 0 : 0, manual: manual, range: "HEAD..origin/main") }
                    return
                }
                self.found(count, manual: manual, range: "HEAD..@{upstream}")
            }
        }
    }

    private func found(_ count: Int, manual: Bool, range: String) {
        available = count
        guard count > 0 else { notes = []; status = "Установлена последняя версия · \(version) (\(commit))"; return }
        git(["log", "--format=%s", "-8", range]) { [weak self] _, out in
            guard let self = self else { return }
            self.notes = out.split(whereSeparator: \.isNewline).map(String.init)
            self.status = "Доступно обновление: \(count) " + (count == 1 ? "изменение" : "изменений")
            if self.auto, !manual { self.installWhenIdle() }
        }
    }

    /// Автоустановка не прерывает работу: ждём, пока все чаты освободятся.
    private func installWhenIdle() {
        guard auto, available > 0, !working else { return }
        if Workspace.shared.anyBusy { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.installWhenIdle() }; return }
        install()
    }

    /// Подтянуть коммиты, пересобрать, перезапустить.
    func install(pull: Bool = true) {
        guard hasRepo, !working else { return }
        guard !Workspace.shared.anyBusy else { status = "Дождись завершения активных чатов."; return }
        working = true; status = pull ? "Скачиваю обновление…" : "Пересобираю…"
        let build = { [weak self] in
            guard let self = self else { return }
            self.status = "Собираю новую версию… (около минуты)"
            self.run("/bin/zsh", [self.source + "/build.sh", "--install", Bundle.main.bundlePath], timeout: 900) { code, out in
                self.working = false
                guard code == 0 else { self.status = "Сборка не удалась — работает прежняя версия.\n" + String(out.suffix(400)); notifyMac("Пульт", "Обновление не собралось — осталась прежняя версия"); return }
                self.available = 0; self.status = "Обновлено. Перезапускаю…"
                self.relaunch()
            }
        }
        guard pull else { build(); return }
        git(["pull", "--ff-only", "--quiet"], timeout: 120) { [weak self] code, out in
            guard let self = self else { return }
            guard code == 0 else { self.working = false; self.status = "Не удалось подтянуть обновление (есть локальные правки?):\n" + String(out.suffix(300)); return }
            build()
        }
    }

    func relaunch() {
        let app = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", app]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
