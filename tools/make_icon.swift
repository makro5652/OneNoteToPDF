import AppKit

// Erzeugt AppIcon.icns: Notizbuch-Seite mit Handschrift-Linie und PDF-Marke auf violettem Verlauf.
func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)

    // Hintergrund: Squircle mit Verlauf
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.43, green: 0.2, blue: 0.62, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    ctx.saveGState()
    squircle.addClip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.62, green: 0.34, blue: 0.82, alpha: 1).cgColor,
        NSColor(red: 0.30, green: 0.10, blue: 0.48, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Seite (leicht gedreht) mit umgeknickter Ecke
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -0.07)
    let page = CGRect(x: -215, y: -270, width: 430, height: 540)
    let fold: CGFloat = 105
    let path = NSBezierPath()
    path.move(to: CGPoint(x: page.minX, y: page.minY))
    path.line(to: CGPoint(x: page.maxX, y: page.minY))
    path.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.line(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.line(to: CGPoint(x: page.minX, y: page.maxY))
    path.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor.white.setFill(); path.fill()
    ctx.restoreGState()
    // Ecke
    let corner = NSBezierPath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(white: 0.84, alpha: 1).setFill(); corner.fill()

    // Textlinien
    NSColor(red: 0.74, green: 0.70, blue: 0.80, alpha: 1).setFill()
    for (i, w) in [300, 330, 250].enumerated() {
        NSBezierPath(roundedRect: CGRect(x: page.minX + 50, y: page.maxY - 120 - CGFloat(i) * 46, width: CGFloat(w), height: 18),
                     xRadius: 9, yRadius: 9).fill()
    }

    // Handschrift-Linie (Tafelbild-Tinte)
    let ink = NSBezierPath()
    ink.move(to: CGPoint(x: page.minX + 45, y: -55))
    ink.curve(to: CGPoint(x: page.minX + 150, y: -40), controlPoint1: CGPoint(x: page.minX + 70, y: 20), controlPoint2: CGPoint(x: page.minX + 105, y: 25))
    ink.curve(to: CGPoint(x: page.minX + 250, y: -50), controlPoint1: CGPoint(x: page.minX + 190, y: -85), controlPoint2: CGPoint(x: page.minX + 215, y: -80))
    ink.curve(to: CGPoint(x: page.maxX - 40, y: 0), controlPoint1: CGPoint(x: page.minX + 295, y: -10), controlPoint2: CGPoint(x: page.minX + 330, y: 35))
    ink.lineWidth = 26; ink.lineCapStyle = .round; ink.lineJoinStyle = .round
    NSColor(red: 0.16, green: 0.45, blue: 0.95, alpha: 1).setStroke(); ink.stroke()

    // PDF-Marke
    let badge = CGRect(x: page.minX + 35, y: page.minY + 40, width: 250, height: 120)
    NSColor(red: 0.89, green: 0.16, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: badge, xRadius: 26, yRadius: 26).fill()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 82, weight: .heavy), .foregroundColor: NSColor.white,
        .paragraphStyle: style, .kern: 4]
    ("PDF" as NSString).draw(in: CGRect(x: badge.minX, y: badge.minY + 12, width: badge.width, height: 100), withAttributes: attrs)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = render(size: base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: set + "/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/AppIcon-preview.png"))
