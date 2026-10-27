import AppKit
import SwiftUI

@MainActor
final class Exporter: ObservableObject {
    @AppStorage("pageDelay") var pageDelay = 1.0

    @Published var trusted = OneNoteDriver.isTrusted(prompt: false)
    @Published var notebook = ""
    @Published var sections: [SectionRow] = []
    @Published var busy = false
    @Published var status = ""
    @Published var progress = 0.0
    @Published var log: [String] = []
    @Published var resultURL: URL?
    @Published var errorText: String?

    private let driver = OneNoteDriver()
    private var task: Task<Void, Never>?

    var selectedLeafCount: Int { sections.filter { $0.selected && !$0.isGroup }.count }

    func requestAccess() {
        _ = OneNoteDriver.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func recheckAccess() { trusted = OneNoteDriver.isTrusted(prompt: false) }

    private func note(_ s: String) { log.append(s); status = s }

    // MARK: Struktur lesen

    func readStructure() {
        errorText = nil
        busy = true
        status = "Lese Abschnitte aus OneNote (Gruppen werden aufgeklappt) …"
        let d = driver
        task = Task {
            defer { busy = false }
            do {
                let (name, secs) = try await Task.detached { () -> (String, [SectionRow]) in
                    (try d.notebookName(), try d.readSections(expand: true))
                }.value
                notebook = name
                sections = secs
                status = "\(secs.filter { !$0.isGroup }.count) Abschnitte gefunden."
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func toggle(_ row: SectionRow, to on: Bool) {
        guard let i = sections.firstIndex(where: { $0.id == row.id }) else { return }
        sections[i].selected = on
        guard row.isGroup else { return }
        var j = i + 1
        while j < sections.count, sections[j].level > row.level { sections[j].selected = on; j += 1 }
    }

    func setAll(_ on: Bool) { for i in sections.indices { sections[i].selected = on } }

    // MARK: Export

    func cancel() { task?.cancel() }

    func export(limit: Int?) {
        let chosen = sections.filter { $0.selected && !$0.isGroup }
        guard !chosen.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (limit == nil ? notebook : "Probelauf \(notebook)") + ".pdf"
        panel.message = "Speicherort der fertigen PDF-Datei"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        errorText = nil
        resultURL = nil
        log = []
        progress = 0
        busy = true

        Log.reset()
        let d = driver
        let delay = pageDelay
        let stamp = Int(Date().timeIntervalSince1970)
        let tmp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/OneNoteToPDF/Export-\(stamp)", isDirectory: true)

        task = Task.detached { [weak self] in
            func ui(_ f: @escaping @MainActor (Exporter) -> Void) { Task { @MainActor in if let s = self { f(s) } } }
            // Alle Zwischendateien am Ende immer entfernen (Erfolg, Fehler, Abbruch).
            defer {
                try? FileManager.default.removeItem(at: tmp)
                d.cleanupStaging()
            }
            let assembler = PDFAssembler()
            /// Bei Abbruch/Fehler: bisher fertige Seiten nicht verwerfen, sondern als „… (unvollständig).pdf“ sichern.
            func savePartial() -> URL? {
                guard assembler.doc.pageCount > 0 else { return nil }
                let name = target.deletingPathExtension().lastPathComponent + " (unvollständig).pdf"
                let url = target.deletingLastPathComponent().appendingPathComponent(name)
                return assembler.write(to: url) ? url : nil
            }
            do {
                // Reste früherer Läufe entfernen
                let cacheRoot = tmp.deletingLastPathComponent()
                for old in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? [] where old != tmp {
                    try? FileManager.default.removeItem(at: old)
                }
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                var counter = 0
                var failed = 0
                var streak = 0

                // Seitenzahl vorab (für den Fortschrittsbalken)
                var plan: [(SectionRow, [PageRow])] = []
                var total = 0
                for s in chosen {
                    try Task.checkCancellation()
                    ui { $0.status = "Zähle Seiten in „\(s.name)“ …" }
                    try d.selectSection(index: s.id, name: s.name)
                    d.settlePages()
                    let pages = try d.readPages(expand: true)
                    plan.append((s, pages))
                    total += pages.count
                    if let limit, total >= limit { total = limit; break }
                }
                ui { $0.log.append("\(plan.count) Abschnitte, \(total) Seiten.") }

                outer: for (s, pages) in plan {
                    try Task.checkCancellation()
                    try d.selectSection(index: s.id, name: s.name)
                    d.settlePages()
                    for (i, p) in pages.enumerated() {
                        try Task.checkCancellation()
                        if let limit, counter >= limit { break outer }
                        counter += 1
                        let n = counter
                        ui { $0.status = "(\(n)/\(total)) \(s.name) › \(p.title)"; $0.progress = Double(n - 1) / Double(max(total, 1)) }
                        let file = tmp.appendingPathComponent(String(format: "%05d.pdf", n))
                        do {
                            try d.selectPage(index: i, title: p.title)
                            Thread.sleep(forTimeInterval: delay)
                            try d.savePageAsPDF(to: file)
                            let data = try Data(contentsOf: file)
                            assembler.append(pdf: data, sectionPath: s.path, title: p.title, level: p.level)
                            streak = 0
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failed += 1
                            streak += 1
                            let msg = "⚠︎ „\(s.name) › \(p.title)“: \(error.localizedDescription)"
                            Log.write(msg)
                            ui { $0.log.append(msg) }
                            if streak >= 3 { throw DriverError.timeout("3 Fehler in Folge – Abbruch. Details: ~/OneNoteToPDF/lauf.log") }
                        }
                    }
                }

                guard assembler.doc.pageCount > 0 else {
                    ui { $0.errorText = "Es wurde keine Seite gespeichert." }
                    ui { $0.busy = false }
                    return
                }
                ui { $0.status = "Schreibe PDF …" }
                guard assembler.write(to: target) else {
                    ui { $0.errorText = "PDF konnte nicht geschrieben werden: \(target.path)" }
                    ui { $0.busy = false }
                    return
                }
                let pc = assembler.doc.pageCount
                ui {
                    $0.resultURL = target
                    $0.progress = 1
                    $0.note(failed == 0 ? "Fertig: \(counter) Seiten → \(pc) PDF-Seiten." : "Fertig mit \(failed) Fehlern: \(pc) PDF-Seiten. ")
                    $0.busy = false
                }
            } catch is CancellationError {
                let part = savePartial()
                ui {
                    $0.resultURL = part
                    $0.note(part == nil ? "Abgebrochen." : "Abgebrochen. Bisher fertige Seiten gesichert: \(part!.lastPathComponent)")
                    $0.busy = false
                }
            } catch {
                let part = savePartial()
                let m = error.localizedDescription + (part == nil ? "" : "\nBisher fertige Seiten wurden gesichert: \(part!.path)")
                ui { $0.resultURL = part; $0.errorText = m; $0.busy = false }
            }
        }
    }
}
