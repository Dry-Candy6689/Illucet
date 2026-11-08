import SwiftUI

/// Keeps the authorized folder alive through the actual UIKit share controller.
struct SavedOutputShareButton: View {
    @EnvironmentObject private var model: IllucetAppModel
    let record: HistoryRecord
    let urls: [URL]
    var title = "Share"
    var access: SavedOutputAccessSession? = nil
    @State private var presentation: Presentation?
    @State private var failure: String?
    @State private var preparing = false

    private struct Presentation: Identifiable {
        let id = UUID()
        let request: SharePresentationRequest
        let access: SavedOutputAccessSession
    }

    var body: some View {
        Button {
            preparing = true
            Task {
                let resolver = model.outputResolver
                let bookmark = model.outputFolderBookmark
                let session: SavedOutputAccessSession
                if let access { session = access }
                else { session = await Task.detached { resolver.open(record, fallbackBookmark: bookmark) }.value }
                defer { preparing = false }
                let resolved: [URL]
                do {
                    resolved = try await Task.detached { try urls.map { try session.read($0) { $0 } } }.value
                    guard !resolved.isEmpty else { throw SavedOutputAccessFailure.unavailable }
                } catch {
                    failure = (error as? SavedOutputAccessFailure)?.localizedDescription ?? SavedOutputAccessFailure.unavailable.localizedDescription
                    return
                }
                presentation = Presentation(request: .init(jobID: record.jobID, title: record.title, fileURLs: resolved), access: session)
            }
        } label: {
            Label(title, systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon).lineLimit(1).frame(maxWidth: .infinity)
        }
        .disabled(preparing)
        .sheet(item: $presentation) { item in
            SystemShareSheet(request: item.request, completion: { _, _ in presentation = nil }, fileAccess: item.access)
        }
        .alert("Can't share this file", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}
