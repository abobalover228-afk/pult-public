import AppKit

let output = CommandLine.arguments[1]
let copper = NSColor(srgbRed: 0.91, green: 0.55, blue: 0.36, alpha: 1)
let white = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1)
func stroke(_ points: [NSPoint], _ color: NSColor, _ width: CGFloat) {
    let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }; color.setStroke(); path.stroke()
}
func make(_ kind: String, size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.21, alpha: 1), ending: NSColor(srgbRed: 0.055, green: 0.065, blue: 0.085, alpha: 1))!.draw(in: tile, angle: -90)
    let outline = NSBezierPath(roundedRect: NSRect(x: 89, y: 89, width: 846, height: 846), xRadius: 182, yRadius: 182)
    NSColor.white.withAlphaComponent(0.13).setStroke(); outline.lineWidth = 4; outline.stroke()
    if kind == "Pult" {
        let window = NSBezierPath(roundedRect: NSRect(x: 218, y: 275, width: 588, height: 474), xRadius: 58, yRadius: 58)
        white.withAlphaComponent(0.85).setStroke(); window.lineWidth = 28; window.stroke()
        stroke([NSPoint(x: 219,y: 638), NSPoint(x: 805,y: 638)], white.withAlphaComponent(0.35), 20)
        stroke([NSPoint(x: 324,y: 546), NSPoint(x: 410,y: 470), NSPoint(x: 324,y: 394)], copper, 42)
        stroke([NSPoint(x: 510,y: 400), NSPoint(x: 680,y: 400)], white, 34)
        copper.setFill(); NSBezierPath(ovalIn: NSRect(x: 264,y: 682,width: 25,height: 25)).fill()
    } else {
        let dial = NSBezierPath(); dial.appendArc(withCenter: NSPoint(x: 512,y: 465), radius: 260, startAngle: 205, endAngle: -25, clockwise: true)
        white.withAlphaComponent(0.87).setStroke(); dial.lineWidth = 36; dial.lineCapStyle = .round; dial.stroke()
        for angle in stride(from: 0.0, through: 180.0, by: 45.0) {
            let a = angle * .pi / 180
            stroke([NSPoint(x: 512+cos(a)*198,y: 465+sin(a)*198), NSPoint(x: 512+cos(a)*218,y: 465+sin(a)*218)], white.withAlphaComponent(0.5), 16)
        }
        stroke([NSPoint(x: 512,y: 465),NSPoint(x: 648,y: 615)],copper,42)
        copper.setFill(); NSBezierPath(ovalIn: NSRect(x: 470,y: 423,width: 84,height: 84)).fill()
        stroke([NSPoint(x: 372,y: 285),NSPoint(x: 652,y: 285)],white.withAlphaComponent(0.65),26)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for kind in ["Pult","Limits"] {
    let dir = URL(fileURLWithPath: output).appendingPathComponent(kind + ".iconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for size in [16,32,128,256,512] {
        try make(kind,size: size).write(to: dir.appendingPathComponent("icon_\(size)x\(size).png"))
        try make(kind,size: size*2).write(to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    try make(kind,size: 1024).write(to: URL(fileURLWithPath: output).appendingPathComponent(kind + ".png"))
}
print("Generated Pult and Limits icon family")
