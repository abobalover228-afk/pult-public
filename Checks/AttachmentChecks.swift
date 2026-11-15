import Foundation
@main struct AttachmentChecks {
static func main() {
 let f = NSTemporaryDirectory() + "pult-att.txt"; try! "привет".write(toFile: f, atomically: true, encoding: .utf8)
 precondition(isImagePath("/a/B.PNG") && !isImagePath("/a/b.pdf"))
 precondition(attachedFilesNote([f], inline: false) == "\n\nПрикреплённые файлы:\n- " + f)
 precondition(attachedFilesNote([f], inline: true).contains("```\nпривет\n```"))
 precondition(attachedFilesNote(["/nope.bin"], inline: true).hasSuffix("- /nope.bin"))
 print("PASS: image detection, file paths, API inline text, missing file")
}
}
