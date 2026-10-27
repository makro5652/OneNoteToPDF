import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ex: Exporter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "book.pages").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("OneNote → PDF").font(.title.bold())
                    Text("Notizbuch inkl. Handschrift als eine PDF mit Lesezeichen").foregroundStyle(.secondary)
                }
            }
            accessBox
            if ex.trusted { sectionBox; exportBox }
            if let e = ex.errorText {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !ex.trusted { ex.recheckAccess() }
        }
    }

    private var accessBox: some View {
        GroupBox("1 · Berechtigung") {
            HStack {
                if ex.trusted {
                    Label("Bedienungshilfen erlaubt", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Die App muss OneNote steuern dürfen.", systemImage: "lock.fill")
                    Spacer()
                    Button("Systemeinstellungen öffnen") { ex.requestAccess() }
                }
                Spacer()
            }.padding(6)
        }
    }

    private var sectionBox: some View {
        GroupBox("2 · Abschnitte") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Öffne in OneNote das gewünschte Notizbuch (Seitenleiste sichtbar), dann:")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Abschnitte aus OneNote lesen") { ex.readStructure() }.disabled(ex.busy)
                    if !ex.sections.isEmpty {
                        Button("Alle") { ex.setAll(true) }.disabled(ex.busy)
                        Button("Keine") { ex.setAll(false) }.disabled(ex.busy)
                    }
                }
                if !ex.notebook.isEmpty { Text("Notizbuch: \(ex.notebook)").font(.headline) }
                if !ex.sections.isEmpty {
                    List {
                        ForEach(ex.sections) { row in
                            Toggle(isOn: Binding(get: { row.selected }, set: { ex.toggle(row, to: $0) })) {
                                HStack(spacing: 4) {
                                    Image(systemName: row.isGroup ? "folder" : "doc.text").foregroundStyle(.secondary)
                                    Text(row.name).fontWeight(row.isGroup ? .semibold : .regular)
                                }
                            }
                            .padding(.leading, CGFloat(row.level) * 18)
                        }
                    }
                    .frame(minHeight: 180)
                }
            }.padding(6)
        }
    }

    private var exportBox: some View {
        GroupBox("3 · Export") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Ergebnis", selection: Binding(get: { ex.mode }, set: { ex.mode = $0 })) {
                    ForEach(ExportMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(ex.busy)
                if ex.mode == .claude {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Erzeugt einen Ordner mit je einer PDF (Handschrift bleibt erhalten) und einer Textdatei pro Abschnitt, dazu ein Inhaltsverzeichnis. Große Abschnitte werden in Teile aufgeteilt. Den Ordner ziehst du anschließend in das Projektwissen auf claude.ai.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Texterkennung (OCR) für Seiten ohne Text – langsamer, Handschrift kann Fehler enthalten", isOn: $ex.useOCR)
                            .font(.caption)
                            .disabled(ex.busy)
                    }
                }
                HStack {
                    Button("Probelauf (3 Seiten)") { ex.export(limit: 3) }
                        .disabled(ex.busy || ex.selectedLeafCount == 0)
                    Button("Alles exportieren (\(ex.selectedLeafCount) Abschnitte)") { ex.export(limit: nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(ex.busy || ex.selectedLeafCount == 0)
                    if ex.busy { Button("Abbrechen") { ex.cancel() } }
                    if let url = ex.resultURL, !ex.busy {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        if ex.resultIsPackage {
                            Button("claude.ai/projects öffnen") { ex.openClaudeProjects() }
                        } else {
                            Button("Öffnen") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Text("Während des Exports bitte Maus und Tastatur nicht benutzen – OneNote bleibt im Vordergrund.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Wartezeit nach Seitenwechsel: \(ex.pageDelay, specifier: "%.1f") s")
                    Slider(value: $ex.pageDelay, in: 0.5...4, step: 0.5).frame(width: 160)
                }.font(.caption)
                if ex.busy || ex.progress > 0 { ProgressView(value: ex.progress) }
                if !ex.status.isEmpty { Text(ex.status).font(.callout).lineLimit(2).foregroundStyle(.secondary) }
                if !ex.log.isEmpty {
                    ScrollView {
                        Text(ex.log.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110).padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(6)
        }
    }
}
