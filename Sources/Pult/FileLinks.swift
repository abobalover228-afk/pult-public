import AppKit
import Foundation

enum LocalFileLink {
    struct Target: Equatable { let path: String; let line: Int?; let column: Int? }
    static func target(_ url: URL, directory: String) -> Target? {
        if let scheme = url.scheme, scheme != "file" { return nil }
        let raw = url.isFileURL ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        let expression = try! NSRegularExpression(pattern: #"^(.*?):([0-9]+)(?::([0-9]+))?$"#)
        let range = NSRange(raw.startIndex..., in: raw)
        var path = raw; var line: Int?; var column: Int?
        if let match = expression.firstMatch(in: raw, range: range), let pathRange = Range(match.range(at: 1), in: raw) {
            path = String(raw[pathRange])
            if let r = Range(match.range(at: 2), in: raw) { line = Int(raw[r]) }
            if let r = Range(match.range(at: 3), in: raw) { column = Int(raw[r]) }
        }
        if let fragment = url.fragment, fragment.hasPrefix("L") { line = Int(fragment.dropFirst().prefix(while: { $0.isNumber })) }
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
        return Target(path: resolved, line: line, column: column)
    }
    static func open(_ url: URL, directory: String) -> Bool {
        guard let target = target(url, directory: directory) else { return false }
        guard FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert(); alert.messageText = "Файл не найден"; alert.informativeText = target.path; alert.runModal(); return true
        }
        if let line = target.line {
            for (bundle, scheme) in [("com.todesktop.230313mzl4w4u92", "cursor"), ("com.microsoft.VSCode", "vscode"), ("com.visualstudio.code.oss", "vscode")] {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
                    var parts = URLComponents(); parts.scheme = scheme; parts.host = "file"; parts.path = target.path + ":\(line):\(target.column ?? 1)"
                    if let link = parts.url { NSWorkspace.shared.open(link); return true }
                }
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: target.path)); return true
    }
}
