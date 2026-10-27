import Foundation
import PDFKit
import Vision

/// Eine exportierte OneNote-Seite (als Einzel-PDF im Cache).
struct PagePart {
    let sectionIndex: Int
    let sectionPath: [String]
    let title: String
    let level: Int
    let file: URL
    let bytes: Int
}

struct PackageResult {
    let folder: URL
    let pdfFiles: Int
    let textFiles: Int
    let pages: Int
    let ocrPages: Int
}

/// Erzeugt einen Ordner, den man direkt als Wissen in ein claude.ai-Projekt ziehen kann:
/// pro Abschnitt eine PDF (ggf. in Teile gesplittet) und eine Markdown-Datei mit dem Text, dazu INDEX.md.
enum ClaudePackage {
    /// Grenzen, damit Claude jede PDF vollständig (auch als Bilder) lesen kann.
    static let maxPages = 80
    static let maxBytes = 20_000_000
    /// Seiten mit weniger Text gelten als „Bild/Handschrift“ und werden (optional) per OCR gelesen.
    static let minTextLength = 30

    static func safeName(_ s: String, limit: Int = 70) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        var t = s.components(separatedBy: bad).joined(separator: " ")
        t = t.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(".") { t = "_" + String(t.dropFirst()) }
        if t.count > limit { t = String(t.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Ohne Titel" : t
    }

    private struct Loaded {
        let part: PagePart
        let doc: PDFDocument
        var count: Int { doc.pageCount }
        var file = ""
        var start = 0       // 1-basiert in `file`
    }

    static func build(notebook: String, parts: [PagePart], into folder: URL, ocr: Bool, complete: Bool,
                      cancellable: Bool, progress: @escaping (String) -> Void) throws -> PackageResult {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var order: [Int] = []
        var groups: [Int: [PagePart]] = [:]
        for p in parts {
            if groups[p.sectionIndex] == nil { order.append(p.sectionIndex) }
            groups[p.sectionIndex, default: []].append(p)
        }

        var indexRows: [String] = []
        var pdfCount = 0, textCount = 0, pageTotal = 0, ocrTotal = 0
        let nbName = notebook.isEmpty ? "Notizbuch" : notebook

        for (n, si) in order.enumerated() {
            if cancellable { try Task.checkCancellation() }
            let secParts = groups[si] ?? []
            guard let first = secParts.first else { continue }
            let secTitle = first.sectionPath.joined(separator: " › ")
            let base = String(format: "%02d ", n + 1) + safeName(first.sectionPath.joined(separator: " – "))
            progress("Paket: Abschnitt „\(secTitle)“ …")

            var loaded: [Loaded] = secParts.compactMap { p in
                guard let d = PDFDocument(url: p.file), d.pageCount > 0 else { return nil }
                return Loaded(part: p, doc: d)
            }
            guard !loaded.isEmpty else { continue }

            // 1) PDFs in Teile aufteilen
            var chunks: [[Int]] = [[]]
            var cp = 0, cb = 0
            for (i, l) in loaded.enumerated() {
                if !chunks[chunks.count - 1].isEmpty && (cp + l.count > maxPages || cb + l.part.bytes > maxBytes) {
                    chunks.append([]); cp = 0; cb = 0
                }
                chunks[chunks.count - 1].append(i)
                cp += l.count; cb += l.part.bytes
            }
            var pdfNames: [String] = []
            for (k, idxs) in chunks.enumerated() {
                let name = chunks.count == 1 ? "\(base).pdf" : "\(base) (Teil \(k + 1)).pdf"
                let out = PDFDocument()
                for i in idxs {
                    loaded[i].file = name
                    loaded[i].start = out.pageCount + 1
                    for pi in 0..<loaded[i].count {
                        if let pg = loaded[i].doc.page(at: pi)?.copy() as? PDFPage { out.insert(pg, at: out.pageCount) }
                    }
                }
                guard out.write(to: folder.appendingPathComponent(name)) else {
                    throw DriverError.timeout("PDF „\(name)“ konnte nicht geschrieben werden.")
                }
                pdfNames.append(name)
                pdfCount += 1
            }

            // 2) Markdown mit Text
            var md = "# \(nbName) › \(secTitle)\n\n"
            md += "Quelle: OneNote-Notizbuch „\(nbName)“, Abschnitt „\(secTitle)“. "
            md += "Die zugehörige PDF (mit Handschrift, Bildern und Layout): " + pdfNames.map { "`\($0)`" }.joined(separator: ", ") + ".\n\n"
            var mdPages: [String] = []
            for l in loaded {
                var text = l.doc.string ?? ""
                text = clean(text)
                var note = ""
                if text.count < minTextLength {
                    if ocr {
                        var o: [String] = []
                        for pi in 0..<l.count {
                            if cancellable { try Task.checkCancellation() }
                            progress("OCR: „\(l.part.title)“ …")
                            if let pg = l.doc.page(at: pi) { o.append(recognize(pg)) }
                        }
                        let r = clean(o.joined(separator: "\n\n"))
                        if r.count > text.count {
                            text = r; note = "_(Text per Texterkennung aus Bild/Handschrift – kann Fehler enthalten; maßgeblich ist die PDF.)_"
                            ocrTotal += 1
                        }
                    }
                    if text.count < 3 { text = ""; note = "_(Kein Text erkannt – die Seite besteht vermutlich aus Handschrift oder Bildern. Siehe PDF.)_" }
                    else if note.isEmpty { note = "_(Wenig Text – ggf. zusätzlich Handschrift oder Bilder. Siehe PDF.)_" }
                }
                let hashes = String(repeating: "#", count: min(l.part.level, 2) + 2)
                let range = l.count == 1 ? "Seite \(l.start)" : "Seiten \(l.start)–\(l.start + l.count - 1)"
                md += "\(hashes) \(l.part.title.isEmpty ? "Ohne Titel" : l.part.title)\n"
                md += "_PDF: `\(l.file)`, \(range)_\n\n"
                if !text.isEmpty { md += text + "\n\n" }
                if !note.isEmpty { md += note + "\n\n" }
                mdPages.append("  - \(String(repeating: "  ", count: min(l.part.level, 2)))\(l.part.title.isEmpty ? "Ohne Titel" : l.part.title) – `\(l.file)`, \(range)")
                pageTotal += l.count
            }
            let mdName = "\(base).md"
            try md.write(to: folder.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
            textCount += 1

            indexRows.append("- **\(secTitle)** – \(loaded.count) Seiten: " + pdfNames.map { "`\($0)`" }.joined(separator: ", ") + ", `\(mdName)`")
            indexRows.append(contentsOf: mdPages)
        }

        // 3) INDEX.md
        let df = DateFormatter(); df.locale = Locale(identifier: "de_DE"); df.dateStyle = .long; df.timeStyle = .short
        var idx = "# \(nbName) – Paket für ein Claude-Projekt\n\n"
        idx += "Erstellt: \(df.string(from: Date())) · \(pageTotal) PDF-Seiten in \(pdfCount) PDF- und \(textCount) Textdateien"
        idx += complete ? "\n\n" : " · **UNVOLLSTÄNDIG** (Export wurde abgebrochen)\n\n"
        idx += """
        ## So nutzt du das Paket
        1. Auf claude.ai → **Projekte** → **Neues Projekt** erstellen.
        2. Unter **Projektwissen** alle Dateien dieses Ordners hineinziehen (PDFs und .md-Dateien).
        3. Optional als Projektanweisung einfügen:

        ```text
        Dieses Projekt enthält mein OneNote-Notizbuch „\(nbName)“. Pro Abschnitt gibt es eine PDF
        (mit Handschrift/Tafelbildern, die du als Bild lesen kannst) und eine .md-Datei mit dem Text.
        Handschriftliche Inhalte stehen nur in den PDFs; Texterkennung in den .md-Dateien kann Fehler enthalten.
        Nenne bei Bezügen auf das Notizbuch bitte Abschnitt und Seitentitel.
        ```

        ## Hinweise
        - Jede PDF hat höchstens \(maxPages) Seiten und ca. \(maxBytes / 1_000_000) MB; größere Abschnitte sind in „Teil 1, Teil 2 …“ aufgeteilt.
        - Seiten mit viel Handschrift sind nur in der PDF vollständig enthalten.
        - Das Projektwissen hat eine Größenbegrenzung. Bei sehr großen Notizbüchern nur die relevanten Abschnitte hochladen.

        ## Inhalt

        """
        idx += indexRows.joined(separator: "\n") + "\n"
        try idx.write(to: folder.appendingPathComponent("00 INDEX.md"), atomically: true, encoding: .utf8)
        textCount += 1

        return PackageResult(folder: folder, pdfFiles: pdfCount, textFiles: textCount, pages: pageTotal, ocrPages: ocrTotal)
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Texterkennung (Apple Vision) für eine PDF-Seite. Läuft ohne Netzwerk lokal auf dem Mac.
    private static func recognize(_ page: PDFPage) -> String {
        guard let ref = page.pageRef else { return "" }
        let box = ref.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return "" }
        let scale = 2200 / max(box.width, box.height)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        guard let img = ctx.makeImage() else { return "" }

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
