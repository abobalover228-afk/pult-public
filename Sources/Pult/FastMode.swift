import Foundation
extension Chat {
    func handleFast(_ text:String) -> Bool {
        let parts=text.split(maxSplits:1,whereSeparator:{$0.isWhitespace})
        guard parts.first?.lowercased() == "/fast" else{return false}
        if isAPI { add(.note,"/fast недоступен для произвольного совместимого API: service tier зависит от провайдера. Запрос не отправлен.");return true }
        guard !busy,!nativeCLIIsRunning else{add(.note,"Меняй /fast после завершения работы.");return true}
        let arg=parts.count>1 ? parts[1].trimmingCharacters(in:.whitespacesAndNewlines).lowercased() : ""
        guard ["","on","off","status"].contains(arg) else{add(.note,"/fast [on|off|status]");return true}
        if arg != "status" { if target == "claude" { claudeFast = arg == "" ? !claudeFast : arg == "on" } else { codexFast = arg == "" ? !codexFast : arg == "on" } }
        let enabled=target == "claude" ? claudeFast : codexFast
        add(.note,"Fast \(enabled ? "запрошен" : "выключен") · \(target == "claude" ? "Claude" : "Codex"). Применяется со следующего сообщения. Доступность и дополнительный расход определяет провайдер; ускорение не гарантируется. Эта команда не запускает модель.")
        return true
    }
    var fastTurnOptions:JSON { ["serviceTier":codexFast ? "fast" : "default"] }
}
