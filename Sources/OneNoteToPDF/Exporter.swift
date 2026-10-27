import AppKit
import SwiftUI

enum ExportMode: String, CaseIterable, Identifiable {
    case pdf, claude
    var id: String { rawValue }
    var title: String { self == .pdf ? "Eine gemeinsame PDF" : "Paket für Claude-Projekt" }
}

@MainActor
final class Exporter: ObservableObject {
    @AppStorage("pageDelay") var pageDelay = 1.0
    @AppStorage("exportMode") var modeRaw = ExportMode.pdf.rawValue
    @AppStorage("useOCR") var useOCR = true

    @Published var trusted = OneNoteDriver.isTrusted(prompt: false)
    @Published var notebook = ""
    @Published var sections: [SectionRow] = []
    @Published var busy = false
    @Published var status = ""
    @Published var progress = 0.0
    @Published var log: [String] = []
    @Published var resultURL: URL?
    @Published var resultIsPackage = false
    @Published var errorText: String?

    private let driver = OneNoteDriver()
    private var task: Task<Void, Never>?

    var mode: ExportMode {
        get { ExportMode(rawValue: modeRaw) ?? .pdf }
        set { modeRaw = newValue.rawValue; objectWillChange.send() }
    }
    var selectedLeafCount: Int { sections.filter { $0.selected && !$0.isGroup }.count }

    func requestAccess() {
        _ = OneNoteDriver.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func recheckAccess() { trusted = OneNoteDriver.isTrusted(prompt: false) }

    func openClaudeProjects() { NSWorkspace.shared.open(URL(string: "https://claude.ai/projects")!) }

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

    /// Fragt das Ziel ab: bei „PDF“ eine Datei, bei „Claude-Paket“ den Ordner, in dem das Paket-Verzeichnis angelegt wird.
    private func askTarget(limit: Int?) -> URL? {
        if mode == .pdf {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = (limit == nil ? notebook : "Probelauf \(notebook)") + ".pdf"
            panel.message = "Speicherort der fertigen PDF-Datei"
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Hier anlegen"
        panel.message = "In welchem Ordner soll das Paket für das Claude-Projekt angelegt werden?"
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        let base = ClaudePackage.safeName("\(limit == nil ? "" : "Probelauf ")\(notebook) – Claude-Paket", limit: 90)
        var url = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)", isDirectory: true); n += 1
        }
        return url
    }

    func export(limit: Int?) {
        let chosen = sections.filter { $0.selected && !$0.isGroup }
        guard !chosen.isEmpty, let target = askTarget(limit: limit) else { return }

        errorText = nil
        resultURL = nil
        log = []
        progress = 0
        busy = true

        Log.reset()
        let d = driver
        let delay = pageDelay
        let mode = self.mode
        let ocr = useOCR
        let nbName = notebook
        let stamp = Int(Date().timeIntervalSince1970)
        let tmp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/OneNoteToPDF/Export-\(stamp)", isDirectory: true)

        task = Task.detached { [weak self] in
            func ui(_ f: @escaping @MainActor (Exporter) -> Void) { Task { @MainActor in if let s = self { f(s) } } }
            // Bildschirm und System während des Exports wach halten (sonst liefert macOS keine Fenster mehr).
            let awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "OneNote-Export läuft")
            // Alle Zwischendateien am Ende immer entfernen (Erfolg, Fehler, Abbruch).
            defer {
                ProcessInfo.processInfo.endActivity(awake)
                try? FileManager.default.removeItem(at: tmp)
                d.cleanupStaging()
            }
            let assembler = PDFAssembler()
            var parts: [PagePart] = []

            /// Bei Abbruch/Fehler: bisher fertige Seiten nicht verwerfen, sondern als „… (unvollständig)“ sichern.
            func savePartial() -> (url: URL, text: String)? {
                guard !parts.isEmpty else { return nil }
                if mode == .pdf {
                    let name = target.deletingPathExtension().lastPathComponent + " (unvollständig).pdf"
                    let url = target.deletingLastPathComponent().appendingPathComponent(name)
                    return assembler.write(to: url) ? (url, url.lastPathComponent) : nil
                }
                let url = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + " (unvollständig)", isDirectory: true)
                guard (try? ClaudePackage.build(notebook: nbName, parts: parts, into: url, ocr: false, complete: false, cancellable: false,
                                                progress: { m in ui { $0.status = m } })) != nil else { return nil }
                return (url, url.lastPathComponent)
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
                            let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
                            if mode == .pdf {
                                let data = try Data(contentsOf: file)
                                assembler.append(pdf: data, sectionPath: s.path, title: p.title, level: p.level)
                            }
                            parts.append(PagePart(sectionIndex: s.id, sectionPath: s.path, title: p.title, level: p.level, file: file, bytes: bytes))
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

                guard !parts.isEmpty else {
                    ui { $0.errorText = "Es wurde keine Seite gespeichert." }
                    ui { $0.busy = false }
                    return
                }

                if mode == .pdf {
                    ui { $0.status = "Schreibe PDF …" }
                    guard assembler.write(to: target) else {
                        ui { $0.errorText = "PDF konnte nicht geschrieben werden: \(target.path)" }
                        ui { $0.busy = false }
                        return
                    }
                    let pc = assembler.doc.pageCount
                    ui {
                        $0.resultURL = target; $0.resultIsPackage = false
                        $0.progress = 1
                        $0.note(failed == 0 ? "Fertig: \(counter) Seiten → \(pc) PDF-Seiten." : "Fertig mit \(failed) Fehlern: \(pc) PDF-Seiten.")
                        $0.busy = false
                    }
                } else {
                    ui { $0.status = "Erstelle Paket für das Claude-Projekt …"; $0.progress = 1 }
                    let r = try ClaudePackage.build(notebook: nbName, parts: parts, into: target, ocr: ocr, complete: true, cancellable: true,
                                                    progress: { m in ui { $0.status = m } })
                    ui {
                        $0.resultURL = r.folder; $0.resultIsPackage = true
                        $0.note("Fertig: \(r.pages) Seiten → \(r.pdfFiles) PDF- und \(r.textFiles) Textdateien" + (r.ocrPages > 0 ? " (\(r.ocrPages) Seiten per OCR)" : "") + (failed > 0 ? ", \(failed) Fehler" : "") + ".")
                        $0.busy = false
                    }
                }
            } catch is CancellationError {
                let part = savePartial()
                ui {
                    $0.resultURL = part?.url; $0.resultIsPackage = mode == .claude
                    $0.note(part == nil ? "Abgebrochen." : "Abgebrochen. Bisher fertige Seiten gesichert: \(part!.text)")
                    $0.busy = false
                }
            } catch {
                let part = savePartial()
                let m = error.localizedDescription + (part == nil ? "" : "\nBisher fertige Seiten wurden gesichert: \(part!.url.path)")
                ui { $0.resultURL = part?.url; $0.resultIsPackage = mode == .claude; $0.errorText = m; $0.busy = false }
            }
        }
    }
}
