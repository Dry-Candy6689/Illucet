import SwiftUI
import UIKit

struct StorageSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsFileDeletion = false

    var body: some View {
        Form {
            Section("Usage") {
                storageRow("Illucet documents", model.storage.appDocumentsBytes)
                storageRow("Temporary files", model.storage.temporaryBytes)
                storageRow("Free space", model.storage.availableBytes)
                    .accessibilityIdentifier("storage.usage.\(model.storageRefreshedAt?.formatted(.iso8601) ?? "pending")")

            }

            Section("Cleanup") {
                Button(role: .destructive) { model.clearDiagnostics() } label: {
                    HStack {
                        Text(model.isClearingDiagnostics ? "Clearing…" : "Clear activity logs")
                        Spacer()
                        if model.isClearingDiagnostics { ProgressView() }
                        else if model.didClearDiagnostics { Label("Cleared", systemImage: "checkmark").font(.caption) }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .disabled(model.isClearingDiagnostics)
                .accessibilityIdentifier("storage.clearLogs")
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                Button(role: .destructive) { confirmsFileDeletion = true } label: {
                    HStack {
                        brandedText(model.isDeletingIllucetFiles ? "Deleting…" : "Delete Illucet files")
                        Spacer()
                        if model.isDeletingIllucetFiles { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .disabled(!model.canDeleteIllucetFiles)
                .accessibilityIdentifier("storage.deleteFiles")
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                if !model.protectedTemporaryJobIDs.isEmpty || !model.packagingBatchIDs.isEmpty {
                    Text("Finish or cancel pending downloads before deleting all files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    model.clearTemporaryFiles()
                } label: {
                    Label(
                        "Clear unused temporary files",
                        systemImage: "trash"
                    )
                }
                Picker("Auto-clean after", selection: Binding(
                    get: { model.settings.automaticallyCleanTemporaryFiles ? model.settings.autoCleanupDays : 0 },
                    set: { days in
                        model.settings.automaticallyCleanTemporaryFiles = days > 0
                        if days > 0 { model.settings.autoCleanupDays = days }
                    }
                )) {
                    Text("Off").tag(0)
                    ForEach(cleanupDayOptions, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .accessibilityIdentifier("storage.autoCleanup")
                Picker(
                    "Minimum free-space reserve",
                    selection: $model.settings.minimumFreeSpaceReserveBytes
                ) {
                    ForEach(reserveOptions, id: \.self) { bytes in
                        Text(byteString(bytes))
                            .tag(bytes)
                    }
                }
            }

            Section {
                HStack {
                    LabeledContent(
                        "Selected folder",
                        value: model.filesFolderName ?? "None"
                    )
                    .accessibilityIdentifier("storage.filesFolder")
                    if model.filesFolderName != nil {
                        Button {
                            model.beginFilesFolderAliasEditing()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Rename Files folder")
                        .accessibilityIdentifier(
                            "storage.renameFilesFolder"
                        )
                    }
                }
                Button("Select folder") {
                    model.requestFilesFolderPicker(from: .settings)
                }
                Button("Test folder access") {
                    model.testFilesFolder()
                }
            } header: {
                Text("Files folder")
            }
        }
        .refreshable { await model.refreshStorage() }
        .settingsFormBackground()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshStorage() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshStorage() } }
        }
        .filesFolderImporter(model: model, source: .settings)
        .confirmationDialog("Delete Illucet files?", isPresented: $confirmsFileDeletion,
            titleVisibility: .visible) {
            Button("Delete files", role: .destructive) {
                Task { await model.deleteIllucetFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            brandedText("Deletes files stored inside Illucet and unused temporary files. Keeps settings, History, Photos and external folders.")
        }
        .appAlertPresenter(model: model)
    }

    private func storageRow(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent { Text(byteString(bytes)) } label: { brandedText(title) }
    }

    private var reserveOptions: [Int64] {
        [
            536_870_912,
            1_073_741_824,
            2_147_483_648,
            5_368_709_120,
        ]
    }

    private var cleanupDayOptions: [Int] {
        Array(Set([1, 2, 3, 4, 5, 6, 7, 14, 21, 30, 60, 90, model.settings.autoCleanupDays])).sorted()
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}
