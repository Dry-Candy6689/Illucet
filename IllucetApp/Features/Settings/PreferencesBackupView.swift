import SwiftUI
import UniformTypeIdentifiers

struct PreferencesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PreferencesBackup.BackupError.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PreferencesBackupView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var document = PreferencesDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingBackup: PreferencesBackup?
    @State private var confirmingImport = false
    @State private var busy = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            Section {
                Button("Save preferences", systemImage: "square.and.arrow.up.fill") {
                    do {
                        document = PreferencesDocument(data: try PreferencesBackup(settings: model.settings, presets: model.quickStartPresets).encoded())
                        exporting = true
                    } catch { model.alert = .error(error) }
                }
                .accessibilityIdentifier("preferences.export")
                if let savedAt = model.lastPreferencesExportAt {
                    LabeledContent("Last saved", value: savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("preferences.lastSaved")
                }
                Button("Import preferences", systemImage: "square.and.arrow.down.fill") { importing = true }
                    .accessibilityIdentifier("preferences.import")
            } footer: {
                Text("Includes settings and Quick Start presets. Accounts, downloads, history, and folder access stay on this device.")
            }
            if busy { ProgressView("Importing preferences…") }
            if let resultMessage { Text(resultMessage).foregroundStyle(.secondary).accessibilityIdentifier("preferences.result") }
        }
        .disabled(busy)
        .settingsFormBackground()
        .navigationTitle("Save & restore preferences")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Illucet-Preferences") { result in
            do {
                if try model.completePreferencesExport(result) { resultMessage = "Preferences saved." }
            } catch { model.alert = .error(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: PreferencesBackup.maximumBytes + 1) ?? Data()
                pendingBackup = try PreferencesBackup.decode(data)
                confirmingImport = true
            } catch { model.alert = .error(error) }
        }
        .alert("Replace preferences?", isPresented: $confirmingImport) {
            Button("Import") {
                guard let backup = pendingBackup else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false; pendingBackup = nil }
                    do {
                        try await model.importPreferences(backup)
                        resultMessage = "Preferences imported."
                    } catch { model.alert = .error(error) }
                }
            }
            Button("Cancel", role: .cancel) { pendingBackup = nil }
        } message: {
            Text("Replace your current settings and Quick Start presets with this backup?")
        }
    }
}

extension IllucetAppModel {
    @discardableResult
    func completePreferencesExport(_ result: Result<URL, Error>, at date: Date = .now) throws -> Bool {
        if case .failure(let error) = result {
            if (error as? CocoaError)?.code == .userCancelled { return false }
            throw error
        }
        lastPreferencesExportAt = date
        snapshot.lastPreferencesExportAt = date
        scheduleSave()
        return true
    }

    func importPreferences(_ backup: PreferencesBackup) async throws {
        guard !startupState.blocksInteraction else { throw PersistenceError.stateNotLoaded }
        // Validate again at the mutation boundary, including programmatic callers.
        let validated = try PreferencesBackup.decode(backup.encoded())
        var importedSettings = validated.settings
        importedSettings.clipboard?.explained = settings.clipboard?.explained ?? false
        saveTask?.cancel()
        let updated = IllucetAppPersistedState(
            settings: importedSettings, jobs: jobs, batches: batches,
            downloadArchive: downloadArchive, history: history, recentLinks: recentLinks,
            quickStartPresets: validated.presets, firstRunState: firstRunState,
            updateStatus: updateStatus
        ).applying(to: snapshot)
        try await persistence.save(updated)
        settings = importedSettings
        quickStartPresets = validated.presets
        snapshot.settings = importedSettings
        snapshot.quickStartPresets = validated.presets
        settingsChanged()
    }
}
