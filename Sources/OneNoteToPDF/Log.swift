import Foundation
import ApplicationServices

/// Schreibt Diagnosezeilen nach ~/OneNoteToPDF/lauf.log
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OneNoteToPDF/lauf.log")
    private static let lock = NSLock()

    static func reset() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Baum eines Accessibility-Elements (ohne lange Listen) für die Fehlersuche.
    static func dump(_ e: AXUIElement, depth: Int = 0, max: Int = 9) {
        let role = e.role
        if role == "AXList" || role == "AXBrowser" || role == "AXOutline" { write(String(repeating: " ", count: depth) + role + " (übersprungen)"); return }
        write(String(repeating: " ", count: depth) + "\(role) id=\(e.ident) label=\(e.label.prefix(60)) focused=\((e.attr("AXFocused") as? NSNumber) ?? 0)")
        guard depth < max else { return }
        for k in e.kids { dump(k, depth: depth + 1, max: max) }
    }
}
