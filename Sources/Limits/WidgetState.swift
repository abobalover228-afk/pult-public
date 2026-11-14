import AppKit
import Foundation
import CoreFoundation

struct ClaudeCacheSnapshot {
    let receivedAt: Double?
    let fresh: Bool
    let windows: [(String, Double, Double?)]
    let message: String
    static func parse(_ data: Data?, now: Double = Date().timeIntervalSince1970) -> Self {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Self(receivedAt: nil, fresh: false, windows: [], message: data == nil ? "Нет данных Claude Code" : "Кеш Claude повреждён")
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        let date = number(root["saved_at"])
        let rate = root["rate_limits"] as? [String: Any] ?? [:]
        var windows: [(String, Double, Double?)] = []
        for (key,title) in [("five_hour","5 часов"),("seven_day","неделя")] {
            guard let row = rate[key] as? [String: Any], let used = number(row["used_percentage"]), (0...100).contains(used) else { continue }
            let reset = number(row["resets_at"])
            if let reset, reset <= now { continue } // A passed reset never implies a fresh zero.
            windows.append((title,100-used,reset))
        }
        let fresh = date.map { now - $0 >= -30 && now - $0 <= 120 } == true && !windows.isEmpty
        let format = DateFormatter(); format.dateStyle = .short; format.timeStyle = .medium
        let stamp = date.map { format.string(from: Date(timeIntervalSince1970: $0)) } ?? "неизвестно"
        let message = windows.isEmpty ? "Квота недоступна · получено: \(stamp)" : (fresh ? "Получено от CLI: " : "УСТАРЕЛО · получено: ") + stamp
        return Self(receivedAt: date, fresh: fresh, windows: windows, message: message)
    }
}

final class HiddenWidgetAccounts: ObservableObject {
    static let shared = HiddenWidgetAccounts()
    @Published private(set) var keys: Set<String>
    private let defaults: UserDefaults
    private let setting = "hiddenWidgetAccounts.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; keys = Set(defaults.stringArray(forKey: setting) ?? []) }
    static func codex(home: String?, name: String) -> String {
        if let home { return "codex:" + URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL.path }
        return "remote:" + name
    }
    func contains(_ key: String) -> Bool { keys.contains(key) }
    func hide(_ key: String) { keys.insert(key); defaults.set(Array(keys).sorted(), forKey: setting) }
    func restoreAll() { keys = []; defaults.removeObject(forKey: setting) }
}

import SwiftUI
final class HideConfirmation: ObservableObject { @Published var value = false }
struct HideWidgetAccountButton: View {
    @ObservedObject var hidden: HiddenWidgetAccounts
    let key: String
    let name: String
    @StateObject private var confirming = HideConfirmation()
    var body: some View {
        Button("Скрыть в Лимитах") { confirming.value = true }
            .buttonStyle(.borderless).font(.caption)
            .confirmationDialog("Скрыть «\(name)» только в Лимитах?", isPresented: $confirming.value) {
                Button("Скрыть запись") { hidden.hide(key) }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Аккаунт останется в Пульте. Авторизация, история, CODEX_HOME, ключи и подписка сохранятся. Вернуть запись можно кнопкой «Вернуть скрытые записи».") }
    }
}
