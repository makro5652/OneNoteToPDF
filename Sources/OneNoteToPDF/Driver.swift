import AppKit
import ApplicationServices

struct SectionRow: Identifiable {
    let id: Int          // Zeilenindex in OneNotes Abschnittsliste
    let name: String
    let level: Int
    let isGroup: Bool
    let path: [String]   // Gruppen + Abschnittsname
    var selected = true
}

struct PageRow {
    let title: String
    let level: Int       // 0 = Hauptseite, 1 = Unterseite, …
}

enum DriverError: LocalizedError {
    case notRunning, noWindow, noOutline(String), selectFailed(String), menu, noDialog, timeout(String)
    var errorDescription: String? {
        switch self {
        case .notRunning: return "OneNote läuft nicht. Bitte OneNote starten und ein Notizbuch öffnen."
        case .noWindow: return "Kein OneNote-Fenster gefunden."
        case .noOutline(let n): return "„\(n)“ nicht gefunden. Ist die Seitenleiste in OneNote sichtbar (Ansicht → Navigation einblenden)?"
        case .selectFailed(let n): return "„\(n)“ konnte nicht ausgewählt werden."
        case .menu: return "Menüpunkt „Datei → Als PDF speichern“ nicht gefunden."
        case .noDialog: return "Der Speichern-Dialog ist nicht erschienen."
        case .timeout(let w): return "Zeitüberschreitung: \(w)"
        }
    }
}

/// Steuert Microsoft OneNote (Mac) über die Bedienungshilfen-API.
final class OneNoteDriver: @unchecked Sendable {
    static let bundleID = "com.microsoft.onenote.mac"
    private let stagedLock = NSLock()
    private var staged: [URL] = []

    /// Löscht übrig gebliebene Zwischendateien im Home-Ordner (z. B. nach Abbruch oder Fehler).
    func cleanupStaging() {
        stagedLock.lock(); defer { stagedLock.unlock() }
        for u in staged { try? FileManager.default.removeItem(at: u) }
        staged = []
    }

    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }
    private func axApp() throws -> AXUIElement {
        guard let a = app else { throw DriverError.notRunning }
        return AXUIElementCreateApplication(a.processIdentifier)
    }
    private func windows() throws -> [AXUIElement] { try axApp().attr("AXWindows") as? [AXUIElement] ?? [] }
    private func mainWindow() throws -> AXUIElement {
        for attempt in 0..<20 {
            if let w = try windows().first(where: { $0.ident != "save-panel" && $0.role == "AXWindow" }) { return w }
            if attempt == 2 { app?.unhide(); app?.activate(options: [.activateAllWindows]) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Log.write("Kein Hauptfenster; Fenster: \(((try? windows()) ?? []).map { "\($0.role)/\($0.ident)/\($0.label)" })")
        throw DriverError.noWindow
    }
    private func savePanel() -> AXUIElement? { try? windows().first { $0.ident == "save-panel" } }

    func notebookName() throws -> String { try mainWindow().label }

    private func outline(_ title: String) throws -> AXUIElement {
        let w = try mainWindow()
        guard let o = w.find(where: { $0.role == "AXOutline" && $0.label == title }) else { throw DriverError.noOutline(title) }
        return o
    }

    private func rows(_ o: AXUIElement) -> [AXUIElement] {
        (o.attr("AXRows") as? [AXUIElement]) ?? o.kids.filter { $0.role == "AXRow" }
    }
    private func level(_ row: AXUIElement) -> Int { (row.attr("AXDisclosureLevel") as? NSNumber)?.intValue ?? 0 }
    private func triangle(_ row: AXUIElement) -> AXUIElement? { row.find(depth: 4) { $0.role == "AXDisclosureTriangle" } }

    private func expandAll(_ o: AXUIElement) {
        for _ in 0..<12 {
            var changed = false
            for row in rows(o) {
                guard let tri = triangle(row) else { continue }
                let open = (row.attr("AXDisclosing") as? NSNumber)?.boolValue
                    ?? ((tri.attr("AXValue") as? NSNumber)?.intValue == 1)
                if !open { tri.press(); changed = true; Thread.sleep(forTimeInterval: 0.15) }
            }
            if !changed { break }
        }
    }

    // MARK: Abschnitte

    func readSections(expand: Bool) throws -> [SectionRow] {
        let o = try outline("Liste der Abschnitte")
        if expand { expandAll(o) }
        let rs = rows(o)
        let base = rs.map(level).min() ?? 0
        var stack: [String] = []
        var out: [SectionRow] = []
        for (i, r) in rs.enumerated() {
            let name = r.find(depth: 6) { $0.ident == "ONMUXSectionItemView" }?.label ?? r.label
            let lv = level(r) - base
            stack = Array(stack.prefix(max(lv, 0)))
            stack.append(name)
            out.append(SectionRow(id: i, name: name, level: lv, isGroup: triangle(r) != nil, path: stack))
        }
        return out
    }

    func selectSection(index: Int, name: String) throws {
        let o = try outline("Liste der Abschnitte")
        var rs = rows(o)
        var idx = index
        func rowName(_ r: AXUIElement) -> String { r.find(depth: 6) { $0.ident == "ONMUXSectionItemView" }?.label ?? r.label }
        if idx >= rs.count || rowName(rs[idx]) != name {
            guard let found = rs.firstIndex(where: { rowName($0) == name }) else { throw DriverError.selectFailed(name) }
            idx = found
        }
        rs = rows(o)
        guard o.set("AXSelectedRows", [rs[idx]] as CFArray) else { throw DriverError.selectFailed(name) }
        Thread.sleep(forTimeInterval: 0.6)
    }

    // MARK: Seiten

    func readPages(expand: Bool) throws -> [PageRow] {
        let o = try outline("Liste der Seiten")
        if expand { expandAll(o) }
        return rows(o).map { r in
            let raw = r.find(depth: 6) { $0.ident == "ONMUXPageItemView" }?.label ?? r.label
            var title = raw
            var lv = 0
            if let m = raw.range(of: ", Ebene \\d+$", options: .regularExpression) {
                lv = Int(raw[m].filter(\.isNumber)).map { $0 - 1 } ?? 0
                title = String(raw[raw.startIndex..<m.lowerBound])
            }
            return PageRow(title: title, level: max(lv, 0))
        }
    }

    func selectPage(index: Int, title: String) throws {
        let o = try outline("Liste der Seiten")
        let rs = rows(o)
        guard index < rs.count, o.set("AXSelectedRows", [rs[index]] as CFArray) else { throw DriverError.selectFailed(title) }
    }

    /// Wartet, bis die Seitenliste nach einem Abschnittswechsel stabil ist.
    func settlePages() {
        var last: [String] = []
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = ((try? readPages(expand: false)) ?? []).map(\.title)
            if now == last && !now.isEmpty { return }
            last = now
        }
    }

    // MARK: Speichern

    private func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func key(_ code: CGKeyCode, cmd: Bool = false, shift: Bool = false) {
        guard let pid = app?.processIdentifier else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            var f: CGEventFlags = []
            if cmd { f.insert(.maskCommand) }
            if shift { f.insert(.maskShift) }
            e.flags = f
            e.postToPid(pid)
            usleep(25_000)
        }
    }

    private func type(_ s: String) {
        guard let pid = app?.processIdentifier else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e.flags = []
                e.postToPid(pid)
            }
            usleep(8_000)
        }
    }

    private func pressSaveAsPDF() -> Bool {
        guard let a = try? axApp(), let barObj = a.attr("AXMenuBar") else { return false }
        let bar = barObj as! AXUIElement
        for top in bar.kids where ["Datei", "File"].contains(top.label) {
            for menu in top.kids {
                for item in menu.kids where item.role == "AXMenuItem" {
                    let t = item.label
                    if t.hasPrefix("Als PDF speichern") || t.hasPrefix("Save as PDF") { return item.press() }
                }
            }
        }
        return false
    }

    /// Speichert die aktuell angezeigte Seite als PDF und verschiebt sie nach `final`.
    /// Der Dialog akzeptiert keine Pfade im Namensfeld (macOS ersetzt „/“ durch „:“). Deshalb wird über das
    /// Ort-Menü der Home-Ordner gewählt (nicht TCC-geschützt, wird vom Dialog gemerkt), nur der Dateiname
    /// eingetragen und „Sichern“ per AX gedrückt. Danach verschiebt die App die Datei.
    func savePageAsPDF(to final: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let staging = home.appendingPathComponent("OneNoteToPDF-\(UUID().uuidString.prefix(8)).pdf")
        stagedLock.lock(); staged.append(staging); stagedLock.unlock()
        app?.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.2)
        Log.write("== Speichern: \(staging.lastPathComponent) → \(final.path)")
        guard pressSaveAsPDF() else { throw DriverError.menu }
        guard waitFor(10, { savePanel() != nil }), let panel = savePanel() else {
            if let w = try? mainWindow() { Log.dump(w, max: 3) }
            throw DriverError.noDialog
        }
        Thread.sleep(forTimeInterval: 0.4)

        func fail(_ why: String) -> DriverError {
            Log.write("FEHLER: \(why)"); Log.dump(panel)
            if let cancel = panel.find(where: { $0.ident == "CancelButton" }) { cancel.press() }
            return .timeout(why)
        }

        // 1) Ordner: Home
        let homeName = home.lastPathComponent
        guard let popup = panel.find(where: { $0.role == "AXPopUpButton" && $0.ident == "where popup" }) else { throw fail("Ort-Menü nicht gefunden") }
        let current = popup.attr("AXValue") as? String ?? ""
        Log.write("Ort aktuell: „\(current)“, Ziel: „\(homeName)“")
        if current != homeName {
            popup.press()
            Thread.sleep(forTimeInterval: 0.4)
            let items = popup.kids.first(where: { $0.role == "AXMenu" })?.kids ?? []
            Log.write("Ort-Menü: \(items.map(\.label))")
            guard let item = items.first(where: { $0.label == homeName }), item.press() else { throw fail("Ordner „\(homeName)“ nicht im Ort-Menü") }
            Thread.sleep(forTimeInterval: 0.6)
            let now = popup.attr("AXValue") as? String ?? ""
            Log.write("Ort jetzt: „\(now)“")
            guard now == homeName else { throw fail("Ordnerwechsel fehlgeschlagen (Ort: \(now))") }
        }

        // 2) Name + Sichern
        guard let field = panel.find(where: { $0.ident == "saveAsNameTextField" }) else { throw fail("Namensfeld nicht gefunden") }
        field.set("AXFocused", kCFBooleanTrue)
        guard field.set("AXValue", staging.lastPathComponent as CFString) else { throw fail("Namensfeld nicht beschreibbar") }
        Thread.sleep(forTimeInterval: 0.2)
        Log.write("Namensfeld jetzt: \(field.attr("AXValue") as? String ?? "?")")
        guard let ok = panel.find(where: { $0.ident == "OKButton" }), ok.press() else { throw fail("Button „Sichern“ nicht drückbar") }

        // 3) Auf Datei warten, verschieben
        let fm = FileManager.default
        func size() -> Int { ((try? fm.attributesOfItem(atPath: staging.path)[.size]) as? Int) ?? 0 }
        let done = waitFor(20, { size() > 0 && savePanel() == nil })
        Log.write("Datei geschrieben: \(done) size=\(size()) Dialog offen: \(savePanel() != nil)")
        guard done else { throw fail("PDF wurde nicht in \(home.path) gefunden") }
        var prev = -1
        while prev != size() { prev = size(); Thread.sleep(forTimeInterval: 0.3) }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: staging, to: final)
        stagedLock.lock(); staged.removeAll { $0 == staging }; stagedLock.unlock()
    }
}
