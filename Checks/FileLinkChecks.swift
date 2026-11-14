import AppKit
@main struct Checks {
 static func main() {
  let a = LocalFileLink.target(URL(string: "/tmp/a.swift:12:3")!, directory: "/project")!
  precondition(a.path == "/tmp/a.swift" && a.line == 12 && a.column == 3)
  let b = LocalFileLink.target(URL(string: "src/main.swift:9")!, directory: "/project")!
  precondition(b.path == "/project/src/main.swift" && b.line == 9)
  precondition(LocalFileLink.target(URL(string: "https://example.com")!, directory: "/tmp") == nil)
  let c = LocalFileLink.target(URL(string: "file:///tmp/My%20File.txt#L5")!, directory: "/project")!
  precondition(c.path == "/tmp/My File.txt" && c.line == 5)
  print("PASS: absolute, relative, spaces, line/column, web-link isolation")
 }
}
