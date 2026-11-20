import Foundation
import Darwin

enum ProjectGit {
    struct Output { let code: Int32; let text: String; let data: Data }
    @discardableResult static func run(_ arguments: [String], at directory: URL? = nil, input: Data? = nil,
                                       environment: [String: String] = [:], allowFailure: Bool = false) throws -> Output {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pult-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let stdinURL = temporary.appendingPathComponent("input")
        try (input ?? Data()).write(to: stdinURL)
        let stdin = try FileHandle(forReadingFrom: stdinURL)
        defer { try? stdin.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"] + arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env.merge(["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=10"]) { _, new in new }
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Сетевым командам нужно больше 45 секунд: большой репозиторий клонируется минутами.
        let network = ["clone", "fetch", "pull", "push", "ls-remote"].contains(arguments.first ?? "")
        DispatchQueue.global().asyncAfter(deadline: .now() + (network ? 900 : 45), execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        let data = try Data(contentsOf: outputURL)
        let result = Output(code: process.terminationStatus, text: String(decoding: data.prefix(2_000_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), data: data)
        if result.code != 0 && !allowFailure {
            // Git's output can contain a credential-bearing URL from an existing configuration.
            let clean = result.text.replacingOccurrences(of: #"https?://[^\s/]*@"#, with: "https://***@", options: .regularExpression)
            throw TeamRoomError(String(clean.suffix(1500)).isEmpty ? "Git завершился с кодом \(result.code)" : String(clean.suffix(1500)))
        }
        return result
    }

}
