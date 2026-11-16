import PullScanCore
import SwiftUI
import UniformTypeIdentifiers

/** The backup zip, for the system "save to Files" sheet. */
struct BackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    var onClose: () -> Void

    @State private var exporting: BackupFile?
    @State private var importing = false
    @State private var pendingImport: Backup.Contents?
    @State private var confirmReset = false
    @State private var message: String?

    static let autoAddChoices = [0, 1, 2, 3, 5]   // seconds; 0 = off

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Settings").font(.title3.bold()).foregroundStyle(.white)
                    Spacer()
                    Button("Done", action: onClose)
                }
                .padding(.bottom, 12)

                Heading("Auto-add")
                Note("Add the detected card after holding it this long, unless you tap ✓ or ✕ first. " +
                     "Only matches of \(Fmt.pct(CardLock.confident)) or more are added automatically.")
                Picker("Auto-add", selection: $app.autoAddSeconds) {
                    ForEach(Self.autoAddChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)

                Heading("✓ / ✕ buttons").padding(.top, 20)
                Note("Which side of the scan screen, for the thumb holding the phone.")
                Picker("Buttons", selection: $app.buttonsLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)

                Heading("Collection data").padding(.top, 20)
                Note("Export saves a .zip of CSV files (collection.csv, settings.csv) that you can copy to " +
                     "another phone, iPhone or Android, and import there, or open in a spreadsheet. There's no " +
                     "account or cloud copy: the collection is only on this phone (Refresh prices sends just the " +
                     "card ids to the price sites).")
                HStack(spacing: 8) {
                    Button("Export") { exporting = BackupFile(data: app.exportBackup()) }
                    Button("Import") { importing = true }
                    Button("Reset", role: .destructive) { confirmReset = true }.disabled(app.collection.isEmpty)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
                if let message { Text(message).font(.caption).foregroundStyle(Color.holoGreen) }

                Heading("About").padding(.top, 20)
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                Note("PullScan \(version) · github.com/YourAmaryllis/PullScan\n" +
                     "Free for noncommercial use (PolyForm Noncommercial 1.0.0).")
                Note(Disclaimer.text).padding(.top, 8)
            }
            .padding(16)
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .zip, defaultFilename: "pullscan-backup-\(utcStamp().prefix(10)).zip") { result in
            if case .success = result { message = "Exported \(app.cardCount) cards" }
            if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingImport = try Backup.import(Data(contentsOf: url))
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
        }
        .alert("Reset collection?", isPresented: $confirmReset) {
            Button("Delete all", role: .destructive) {
                app.replaceCollection([:])
                log.info("collection reset")
                message = "Collection reset"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all \(app.cardCount) cards from the collection on this phone. Export first if you might want them back.")
        }
        .alert(importTitle, isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
               presenting: pendingImport) { imp in
            let n = imp.collection.values.reduce(0, +)
            Button("Replace") {
                app.replaceCollection(imp.collection)
                app.applyImportedSettings(imp.settings)
                log.info("import replace \(n) cards")
                message = "Imported \(n) cards"
            }
            Button("Add to current") {
                app.replaceCollection(app.collection.merging(imp.collection, uniquingKeysWith: +))
                log.info("import add \(n) cards")
                message = "Added \(n) cards"
            }
            Button("Cancel", role: .cancel) {}
        } message: { imp in
            let unknown = imp.collection.keys.filter { app.byId[$0] == nil }.count
            Text("\(imp.collection.count) different cards" +
                 (unknown > 0 ? " (\(unknown) not in this app's card list; kept, but not shown)" : "") +
                 ". Replace the current collection (\(app.cardCount) cards), or add to it?")
        }
    }

    private var importTitle: String { "Import \(pendingImport?.collection.values.reduce(0, +) ?? 0) cards?" }
}

struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).foregroundStyle(.white) }
}
