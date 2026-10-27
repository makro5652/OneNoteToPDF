import AppKit
import PDFKit

/// Test des Claude-Pakets ohne OneNote: `OneNoteToPDF --selftest-package /Pfad/zum/Ausgabeordner`
enum PackageSelfTest {
    static func run(out: URL) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("onp-pkgtest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        func pdf(_ name: String, _ draw: (CGContext) -> Void) -> URL {
            let url = tmp.appendingPathComponent(name)
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
            return url
        }
        func text(_ ctx: CGContext, _ s: String, y: CGFloat = 760) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (s as NSString).draw(in: CGRect(x: 50, y: y - 80, width: 495, height: 100),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
        }
        func bitmapText(_ s: String) -> CGImage {
            let w = 1400, h = 200
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            (s as NSString).draw(at: CGPoint(x: 20, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            return c.makeImage()!
        }
        func part(_ sec: Int, _ path: [String], _ title: String, _ level: Int, _ url: URL) -> PagePart {
            PagePart(sectionIndex: sec, sectionPath: path, title: title, level: level, file: url,
                     bytes: ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0)
        }

        var parts: [PagePart] = []
        let zelle = ["Biologie", "Zelle: Bau/Funktion"]   // Sonderzeichen im Namen
        parts.append(part(0, zelle, "Mit Textebene", 0, pdf("a.pdf") { text($0, "Die Zelle ist die kleinste lebende Einheit. Mitochondrien produzieren ATP.") }))
        parts.append(part(0, zelle, "Nur Tinte (Tafelbild)", 1, pdf("b.pdf") { c in
            c.setStrokeColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.setLineWidth(6)
            c.move(to: CGPoint(x: 80, y: 500)); c.addCurve(to: CGPoint(x: 500, y: 520), control1: CGPoint(x: 200, y: 700), control2: CGPoint(x: 350, y: 300)); c.strokePath()
        }))
        parts.append(part(0, zelle, "Text nur als Bild", 0, pdf("c.pdf") { c in
            c.draw(bitmapText("Der Zellkern enthaelt die DNA und steuert den Stoffwechsel."), in: CGRect(x: 40, y: 600, width: 515, height: 75))
        }))
        for i in 1...90 {
            parts.append(part(1, ["Chemie"], "Seite \(i): Protolyse von HCl, H2SO4 und H3PO4 in Wasser", 0,
                              pdf("s\(i).pdf") { text($0, "Chemie Seite \(i): Saeuren geben Protonen an Wasser ab und bilden Oxonium-Ionen.") }))
        }

        do {
            try? fm.removeItem(at: out)
            let r = try ClaudePackage.build(notebook: "Testbuch", parts: parts, into: out, ocr: true, complete: true, cancellable: false,
                                            progress: { print("  …", $0) })
            print("OK: \(r.pages) Seiten, \(r.pdfFiles) PDF, \(r.textFiles) Text, OCR-Seiten: \(r.ocrPages)")
            for f in (try? fm.contentsOfDirectory(atPath: out.path))?.sorted() ?? [] {
                let sz = ((try? fm.attributesOfItem(atPath: out.appendingPathComponent(f).path))?[.size] as? Int) ?? 0
                print(String(format: "%8d  %@", sz, f))
            }
            return 0
        } catch {
            print("FEHLER:", error.localizedDescription)
            return 1
        }
    }
}
