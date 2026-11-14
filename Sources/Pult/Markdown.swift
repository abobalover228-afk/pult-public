// Markdown для ответов: заголовки, списки, цитаты, таблицы, блоки кода с подсветкой и «копировать».
import AppKit
import SwiftUI

enum MDBlock { case text(String), code(String, String) }

func mdBlocks(_ s: String) -> [MDBlock] {
    var out: [MDBlock] = [], text: [Substring] = [], code: [Substring] = []
    var lang: String? = nil
    for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            if let l = lang { out.append(.code(l, code.joined(separator: "\n"))); code = []; lang = nil }
            else {
                if !text.isEmpty { out.append(.text(text.joined(separator: "\n"))); text = [] }
                lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        } else if lang != nil { code.append(line) } else { text.append(line) }
    }
    if let l = lang { out.append(.code(l, code.joined(separator: "\n"))) }   // незакрытый блок при потоке
    if !text.isEmpty { out.append(.text(text.joined(separator: "\n"))) }
    return out
}

let keywords: Set<String> = ["fn", "let", "mut", "pub", "struct", "enum", "impl", "use", "mod", "match", "if", "else", "for", "while",
    "loop", "return", "async", "await", "self", "Self", "true", "false", "def", "class", "import", "from", "in", "and", "or", "not",
    "None", "const", "var", "func", "guard", "final", "static", "where", "type", "interface", "export", "function", "new", "try",
    "catch", "with", "as", "is", "elif", "lambda", "yield", "Some", "Ok", "Err", "trait", "dyn", "crate", "then", "fi", "do", "done", "echo"]

/// Простая подсветка: комментарии, строки, числа, ключевые слова.
func highlight(_ code: String) -> AttributedString {
    var out = AttributedString()
    for (n, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if n > 0 { out += AttributedString("\n") }
        var s = String(line)
        var comment = ""
        for marker in ["//", "# "] where !s.contains("\"") || marker == "//" {
            if let r = s.range(of: marker), s[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 {
                comment = String(s[r.lowerBound...]); s = String(s[..<r.lowerBound]); break
            }
        }
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("#") && comment.isEmpty { comment = s; s = "" }
        var word = "", inStr = false, quote: Character = "\""
        func flush() {
            guard !word.isEmpty else { return }
            var a = AttributedString(word)
            if keywords.contains(word) { a.foregroundColor = Color(red: 0.78, green: 0.55, blue: 0.95) }
            else if word.first?.isNumber == true { a.foregroundColor = Color(red: 0.95, green: 0.65, blue: 0.4) }
            out += a; word = ""
        }
        var str = ""
        for ch in s {
            if inStr {
                str.append(ch)
                if ch == quote { var a = AttributedString(str); a.foregroundColor = Color(red: 0.6, green: 0.85, blue: 0.5); out += a; str = ""; inStr = false }
            } else if ch == "\"" || ch == "'" { flush(); inStr = true; quote = ch; str = String(ch) }
            else if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch) }
            else { flush(); out += AttributedString(String(ch)) }
        }
        flush()
        if !str.isEmpty { var a = AttributedString(str); a.foregroundColor = Color(red: 0.6, green: 0.85, blue: 0.5); out += a }
        if !comment.isEmpty { var a = AttributedString(comment); a.foregroundColor = .gray; out += a }
    }
    return out
}

struct CodeBlockView: View {
    let lang: String
    let code: String
    @StateObject private var copied = Flag()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "код" : lang).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Button(copied.on ? "✓ скопировано" : "копировать") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    copied.on = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied.on = false }
                }.buttonStyle(.borderless).font(.system(size: 10.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlight(code)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(10).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
    }
}

final class Flag: ObservableObject { @Published var on = false }

func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Текстовый блок: строки по одной — заголовки, пункты, цитаты, таблицы (моноширинно), обычный текст.
struct TextBlockView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(groups().enumerated()), id: \.offset) { _, g in g }
        }
    }
    func groups() -> [AnyView] {
        var views: [AnyView] = []
        var table: [String] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table.filter { !$0.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty }
            let cells = rows.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
            let cols = cells.map(\.count).max() ?? 0
            views.append(AnyView(
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                Text(inline(c < row.count ? row[c] : "")).fontWeight(i == 0 ? .semibold : .regular)
                            }
                        }
                        if i == 0 { Divider().gridCellColumns(cols) }
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))))
            table = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { table.append(t); continue }
            flushTable()
            if t.isEmpty { views.append(AnyView(Spacer().frame(height: 2))); continue }
            if let h = t.range(of: #"^#{1,6}\s"#, options: .regularExpression) {
                let level = t[h].filter { $0 == "#" }.count
                views.append(AnyView(Text(inline(String(t[h.upperBound...]))).font(.system(size: level <= 2 ? 15 : 13.5, weight: .bold))
                    .padding(.top, 4)))
            } else if let b = t.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) {
                let marker = t[b].trimmingCharacters(in: .whitespaces)
                let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 14
                views.append(AnyView(HStack(alignment: .top, spacing: 6) {
                    Text(marker.first?.isNumber == true ? marker : "•").foregroundColor(.secondary)
                    Text(inline(String(t[b.upperBound...]))).textSelection(.enabled)
                }.padding(.leading, indent)))
            } else if t.hasPrefix(">") {
                views.append(AnyView(HStack(spacing: 8) {
                    Rectangle().fill(accent.opacity(0.6)).frame(width: 2)
                    Text(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))).foregroundColor(.secondary)
                }))
            } else if t.range(of: #"^(-{3,}|\*{3,})$"#, options: .regularExpression) != nil {
                views.append(AnyView(Divider().opacity(0.4)))
            } else {
                views.append(AnyView(Text(inline(raw)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)))
            }
        }
        flushTable()
        return views
    }
}

struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(mdBlocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .text(let t): TextBlockView(text: t)
                case .code(let l, let c): CodeBlockView(lang: l, code: c)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
