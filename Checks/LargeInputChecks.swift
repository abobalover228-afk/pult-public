import Foundation
@main struct LargeInputChecks {
    static func main() throws {
        let small: JSON = ["input": [["type": "text", "text": "привет"]]]
        let unchanged = try CodexInput.prepare(small)["input"] as! [JSON]
        precondition(unchanged[0]["text"] as? String == "привет")
        let large = String(repeating: "🙂контекст\n", count: 150_000)
        let prepared = try CodexInput.prepare(["input": [["type": "text", "text": large, "text_elements": []], ["type": "localImage", "path": "/tmp/image.png"]]])
        let entries = prepared["input"] as! [JSON]
        let pointer = entries[0]["text"] as! String
        let path = String(pointer.split(separator: "\n")[0].split(separator: " ").last!)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let restored = try String(contentsOfFile: path, encoding: .utf8)
        precondition(restored == large)
        precondition(pointer.utf8.count < 2000 && entries[0]["text_elements"] == nil)
        precondition(entries[1]["path"] as? String == "/tmp/image.png")
        let repeated = try CodexInput.prepare(["input": (0..<10).map { _ in ["type": "text", "text": String(repeating: "x", count: 150_000)] }])["input"] as! [JSON]
        precondition(repeated.reduce(0) { $0 + ($1["text"] as! String).utf8.count } < 220_000)
        for entry in repeated.dropFirst() {
            let path = String((entry["text"] as! String).split(separator: "\n")[0].split(separator: " ").last!)
            try FileManager.default.removeItem(atPath: path)
        }
        print("PASS: oversized Unicode input, aggregate budget, lossless file content, small input and images")
    }
}
