import SwiftUI

struct RetainedMediaReprocessView: View {
    @EnvironmentObject private var model: IllucetAppModel
    let record: HistoryRecord
    @State private var format: RetainedAudioFormat = .mp3
    @State private var running = false
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var completed: HistoryRecord?
    var body: some View {
        Form {
            Section {
                Picker("Audio format", selection: $format) {
                    ForEach(RetainedAudioFormat.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(running)
                brandedText("Convert the retained file locally. The original stays intact. A verified new audio file is saved to Illucet and added to History. Keep this screen open during processing.")
                if running {
                    ProgressView("Processing saved media…")
                    Button("Cancel processing", role: .destructive) { operation?.cancel() }
                } else {
                    Button("Create audio copy") { start() }
                }
                if let message { Text(message) }
                if let completed {
                    NavigationLink("Open new output") { OutputDetailView(record: completed, context: .queue).environmentObject(model) }
                }
            }
        }
        .navigationTitle("Reprocess saved file")
        .onDisappear { operation?.cancel() }
    }
    private func start() {
        guard !running else { return }
        message = nil
        completed = nil
        running = true
        operation = Task {
            do {
                let workflow = RetainedMediaReprocessor(processor: NativeFFmpegMediaProcessor(), exporter: model.exporter,
                    fastStart: model.settings.fastStartMP4, outputResolver: model.outputResolver, folderBookmark: model.outputFolderBookmark)
                let output = try await workflow.convert(record: record, format: format, progress: { _ in })
                model.history.insert(output, at: 0)
                model.scheduleSave()
                model.requestStorageRefresh()
                completed = output
                message = "Saved the verified audio copy."
            } catch is CancellationError { message = "Processing cancelled. The original was kept." }
            catch { message = "The saved file could not be converted. The original was kept." }
            running = false
        }
    }
}
