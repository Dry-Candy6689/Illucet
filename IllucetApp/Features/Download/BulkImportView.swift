import SwiftUI
import UniformTypeIdentifiers

struct BulkImportView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var importingFile = false
    @State private var fileBusy = false
    @State private var exportingFailures = false
    @FocusState private var textFocused: Bool

    private var destinations: [ExportDestination] {
        let base: [ExportDestination] = [.appDocuments, .filesFolder]
        return model.bulkAssets.filter(\.selected).contains { $0.configuration.mode == .audioOnly && $0.metadata.sourceIdentity?.kind != .image }
            ? base : base + [.photos, .filesAndPhotos]
    }

    var body: some View {
        NavigationStack {
            List {
                if model.bulkImportStep == .input {
                    Section {
                        TextEditor(text: $model.bulkImportText)
                            .focused($textFocused)
                            .frame(minHeight: 180)
                            .font(.body.monospaced())
                            .accessibilityLabel("Text containing links")
                            .accessibilityIdentifier("bulk.text")
                        Button(action: pasteNoteText) {
                            Label("Paste text", systemImage: "doc.on.clipboard")
                        }
                        Button { importingFile = true } label: { Label("Choose text document", systemImage: "doc.text") }
                            .accessibilityIdentifier("bulk.file")
                    } header: { Text("Find links in your text") }
                    footer: { Text("Copy text from Apple Notes or import TXT, Markdown, CSV, HTML or RTF. Up to 500 links and 10 MiB.") }
                } else if model.bulkImportStep == .links {
                    Section {
                        ForEach($model.bulkLinks) { $link in
                            Toggle(isOn: $link.selected) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(link.site?.name ?? "Unsupported website").font(.subheadline.weight(.semibold))
                                    Text(link.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if link.duplicate { Text("Duplicate link").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .disabled(link.site == nil || link.duplicate || model.bulkImportBusy)
                        }
                    } header: { Text("\(model.bulkLinks.filter(\.selected).count) selected links") }
                    footer: { Text("Review links before analysis. Multi-item posts and playlists expand into selectable media.") }
                    Button("Analyze selected links") { model.analyzeBulkLinks() }
                        .disabled(model.bulkImportBusy || !model.bulkLinks.contains(where: \.selected))
                        .accessibilityIdentifier("bulk.analyze")
                } else {
                    if model.bulkAssets.count == 1, let site = model.bulkAssets.first?.site {
                        Section { SiteSourceLabel(site: site) }
                    }
                    Section {
                        Picker("Save to", selection: $model.bulkBaseConfiguration.destination) {
                            ForEach(destinations, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Continue if an item fails", isOn: $model.bulkBaseConfiguration.continuePlaylistOnError)
                        DisclosureGroup("Naming and duplicates") {
                            TextField("Filename pattern", text:$model.bulkBaseConfiguration.filenameTemplate)
                            Toggle("Skip previously completed items", isOn:$model.bulkSkipArchived)
                            Picker("Existing file", selection:Binding(get:{model.bulkBaseConfiguration.duplicateHandlingOverride ?? .addNumber},set:{model.bulkBaseConfiguration.duplicateHandlingOverride=$0})) {
                                ForEach(DuplicateHandling.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                    } header: { Text("Shared download options") }
                    footer: { Text("Best available media and original images. Open an item to adjust its available options. Completed items are skipped when already archived.") }
                    Section {
                        ForEach($model.bulkAssets) { $item in
                            HStack {
                                Button { item.selected.toggle() } label: {
                                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).frame(width: 44, height: 44)
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel(item.selected ? "Deselect \(item.metadata.title)" : "Select \(item.metadata.title)")
                                NavigationLink {
                                    BulkItemOptionsView(item: $item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.metadata.title).font(.subheadline).lineLimit(2)
                                        Text("\(item.site.name) · \(item.metadata.sourceIdentity?.kind.rawValue.capitalized ?? "Video")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: { Text("\(model.bulkAssets.filter(\.selected).count) selected items") }
                    Button { model.startImportedBatch() } label: {
                        Label("Queue selected downloads", systemImage: "arrow.down.circle.fill")
                    }.disabled(model.bulkImportBusy || !model.bulkAssets.contains(where: \.selected))
                        .accessibilityIdentifier("bulk.download")
                }
                if model.bulkImportBusy || fileBusy {
                    Section { HStack { ProgressView(); Text(model.bulkImportStep == .items ? "Preparing queue…" : "Reading media…") } }
                }
                if let message = model.bulkImportMessage {
                    Section { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if !model.bulkFailedLinks.isEmpty {
                    Button("Export failed links") { exportingFailures = true }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.bulkIndividualSource ? "Download options" : "Bulk import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.cancelBulkImport() }.disabled(model.bulkImportBusy && model.bulkImportStep == .items)
                }
                if model.bulkImportStep == .input {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Find links") {
                            textFocused = false
                            model.scanBulkLinks()
                        }
                        .disabled(model.bulkImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileBusy)
                        .accessibilityIdentifier("bulk.scan")
                    }
                }
                if model.bulkImportStep != .input && !model.bulkImportBusy {
                    ToolbarItem(placement: .topBarTrailing) { Button("Edit text") { model.bulkImportStep = .input } }
                }
            }
            .interactiveDismissDisabled(model.bulkImportBusy)
            .onChange(of: destinations, initial: true) { _, available in
                if !available.contains(model.bulkBaseConfiguration.destination) { model.bulkBaseConfiguration.destination = .appDocuments }
            }
            .fileExporter(isPresented:$exportingFailures,document:FailedLinkExport(urls:model.bulkFailedLinks),contentType:.plainText,defaultFilename:"Illucet failed links") { _ in }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: BulkLinkImport.fileTypes) { result in
                guard case let .success(url) = result else { return }
                fileBusy = true
                Task { @MainActor in
                    defer { fileBusy = false }
                    do {
                        let text = try await Task.detached { try BulkLinkImport.text(from: url) }.value
                        model.bulkImportText = text
                        model.scanBulkLinks()
                    } catch { model.bulkImportMessage = error.localizedDescription }
                }
            }
        }
        .filesFolderImporter(model: model, source: .bulkImport)
    }

    private func pasteNoteText() {
        let clipboard = UIPasteboard.general
        do {
            if let rtf = clipboard.data(forPasteboardType: UTType.rtf.identifier) {
                model.bulkImportText = try BulkLinkImport.text(from: rtf, fileExtension: "rtf")
            } else {
                model.bulkImportText = clipboard.string ?? clipboard.url?.absoluteString ?? ""
            }
            model.bulkImportMessage = nil
        } catch { model.bulkImportMessage = error.localizedDescription }
    }
}

struct BulkItemOptionsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Binding var item: BulkMediaItem
    private var availableModes: [DownloadMode] {
        let availability = SourceModeAvailability(analyzedMetadata: item.metadata)
        return DownloadMode.allCases.filter { availability.status(for: $0).permitsSelection }
    }
    private var resolutions: [Int] { FormatSelection.availableResolutions(in: item.metadata) }
    var body: some View {
        Form {
            Section { SiteSourceLabel(site: item.site); Text(item.metadata.title).font(.headline) }
            Section {
                Picker("Account use", selection: Binding(get: { item.configuration.enginePreferences?.accountAccess ?? .automatic }, set: {
                    var p = item.configuration.enginePreferences ?? .init(); p.accountAccess = $0; item.configuration.enginePreferences = p
                })) {
                    ForEach(AccountAccessPolicy.allCases) { Text($0.label).tag($0) }
                }
                Picker("Preferred account", selection: $item.configuration.accountID) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.accountProfiles.filter { $0.site == item.site }) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                Picker("Download engine", selection: Binding(get: { item.configuration.enginePreferences?.download ?? .automatic }, set: { var p = item.configuration.enginePreferences ?? .init(); p.download = $0; item.configuration.enginePreferences = p })) {
                    ForEach(DownloadEngineChoice.allCases) { Text($0.label).tag($0) }
                }
                if item.configuration.enginePreferences?.download == .aria2 {
                    Text(Aria2TransferPolicy.explanation).font(.caption).foregroundStyle(.secondary)
                }
                if item.metadata.sourceIdentity?.kind != .image {
                    Picker("Download", selection: $item.configuration.mode) {
                        ForEach(availableModes) { Text($0.rawValue).tag($0) }
                    }
                    if item.configuration.mode != .audioOnly, !resolutions.isEmpty {
                        Picker("Maximum quality", selection: $item.configuration.maximumResolution) {
                            Text("Best available").tag(Int?.none)
                            ForEach(resolutions, id: \.self) { Text("Up to \($0)p").tag(Optional($0)) }
                        }
                    }
                    Picker("File format", selection: $item.configuration.container) {
                        ForEach(OutputCapabilityMatrix.enabledContainers(for: item.configuration.mode, audioCodec: item.configuration.audioCodec, videoCodec: item.configuration.videoCodec)) { Text($0.rawValue).tag($0) }
                    }
                    if item.configuration.mode != .videoOnly {
                        Picker("Audio format", selection: $item.configuration.audioCodec) {
                            ForEach(OutputCapabilityMatrix.enabledAudioCodecs(for:item.configuration.mode)) { Text($0.rawValue).tag($0) }
                        }
                    }
                } else {
                    Text("Original image format and animation are preserved.")
                    Toggle("Remove location & camera metadata", isOn: Binding(get: { item.configuration.enginePreferences?.removeImageMetadata == true }, set: { var p = item.configuration.enginePreferences ?? .init(); p.removeImageMetadata = $0; item.configuration.enginePreferences = p }))
                }
            }
        }
        .navigationTitle("Item options")
        .onChange(of: item.configuration.mode) { _, _ in refreshSelection() }
        .onChange(of: item.configuration.maximumResolution) { _, _ in refreshSelection() }
        .onChange(of: item.configuration.container) { _, _ in refreshSelection() }
        .onChange(of:item.configuration.audioCodec) { _, _ in refreshSelection() }
    }
    private func refreshSelection() {
        item.configuration.preserveSourceResolution = item.configuration.maximumResolution == nil
        item.configuration = OutputCapabilityMatrix.normalized(item.configuration)
        FormatSelection.applyAutomaticSelection(to: &item.configuration, metadata: item.metadata)
    }
}

struct SiteSourceLabel: View {
    let site: MediaSite
    var body: some View {
        HStack(spacing: 9) {
            Image("SiteLogo-\(site.rawValue)").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.primary).accessibilityHidden(true)
            Text(site.name).font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
