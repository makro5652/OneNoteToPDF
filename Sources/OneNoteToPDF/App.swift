import SwiftUI
import AppKit

@main
struct OneNoteToPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var exporter = Exporter()

    var body: some Scene {
        WindowGroup("OneNote → PDF") {
            ContentView()
                .environmentObject(exporter)
                .frame(minWidth: 640, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test des Claude-Pakets ohne OneNote: OneNoteToPDF --selftest-package /Ausgabeordner
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-package"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            Task.detached { exit(PackageSelfTest.run(out: out)) }
            return
        }
        // Nur-Lese-Diagnose ohne Oberfläche: OneNoteToPDF --probe
        if CommandLine.arguments.contains("--probe") {
            let d = OneNoteDriver()
            do {
                print("Notizbuch:", try d.notebookName())
                let s = try d.readSections(expand: false)
                print("Sichtbare Abschnitte/Gruppen:", s.count)
                for r in s.prefix(25) { print(String(repeating: "  ", count: r.level) + (r.isGroup ? "▸ " : "• ") + r.name) }
                let p = try d.readPages(expand: false)
                print("Seiten im aktuellen Abschnitt:", p.count)
                for r in p.prefix(25) { print(String(repeating: "  ", count: r.level) + r.title) }
                exit(0)
            } catch { print("FEHLER:", error.localizedDescription); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
