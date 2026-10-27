import Foundation
import PDFKit

/// Fügt die Einzelseiten-PDFs zu einem Dokument mit verschachtelten Lesezeichen zusammen.
final class PDFAssembler {
    let doc = PDFDocument()
    private let root = PDFOutline()
    private var nodes: [String: PDFOutline] = [:]
    private var pageStack: [(level: Int, node: PDFOutline)] = []
    private var lastSection = "\u{0}"

    init() { doc.outlineRoot = root }

    /// Hängt `pdf` an und legt Lesezeichen an. Gibt die Zahl der Seiten zurück.
    @discardableResult
    func append(pdf: Data, sectionPath: [String], title: String, level: Int) -> Int {
        guard let src = PDFDocument(data: pdf), src.pageCount > 0 else { return 0 }
        let start = doc.pageCount
        for i in 0..<src.pageCount {
            if let p = src.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) }
        }
        guard let first = doc.page(at: start) else { return 0 }
        let dest = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).height))

        var parent = root
        for k in 1...max(sectionPath.count, 1) where !sectionPath.isEmpty {
            let key = sectionPath[0..<k].joined(separator: "\u{1}")
            if let existing = nodes[key] {
                parent = existing
            } else {
                let o = PDFOutline()
                o.label = sectionPath[k - 1]
                o.destination = dest
                parent.insertChild(o, at: parent.numberOfChildren)
                nodes[key] = o
                parent = o
            }
        }
        let sectionKey = sectionPath.joined(separator: "\u{1}")
        if sectionKey != lastSection { pageStack = []; lastSection = sectionKey }

        while let top = pageStack.last, top.level >= level { pageStack.removeLast() }
        let container = pageStack.last?.node ?? parent
        let o = PDFOutline()
        o.label = title.isEmpty ? "Ohne Titel" : title
        o.destination = dest
        container.insertChild(o, at: container.numberOfChildren)
        pageStack.append((level, o))
        return src.pageCount
    }

    func write(to url: URL) -> Bool { doc.write(to: url) }
}
