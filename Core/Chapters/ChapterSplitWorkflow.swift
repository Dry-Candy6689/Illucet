import Foundation

struct ChapterSplitOutput: Equatable, Sendable {
    let chapter: MediaChapter
    let filename: String
    let fileURL: URL
    let probe: MediaProbeResult
}

final class ChapterSplitWorkflow: @unchecked Sendable {
    private let trimWorkflow: ManualTrimWorkflow
    private let fileManager: FileManager

    init(
        mediaProcessor: any MediaProcessor,
        fileManager: FileManager = .default
    ) {
        trimWorkflow = ManualTrimWorkflow(mediaProcessor: mediaProcessor)
        self.fileManager = fileManager
    }

    func split(
        mediaURL: URL,
        inputProbe: MediaProbeResult,
        plan: OutputPlan,
        chapters: [MediaChapter],
        metadata: MediaMetadata,
        settings: AppSettings,
        temporaryRoot: URL,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> [ChapterSplitOutput] {
        let segments = try Self.contiguousSegments(
            chapters,
            durationSeconds: inputProbe.durationSeconds
                ?? metadata.durationSeconds
        )
        let root = temporaryRoot.appending(
            path: "chapter-splits",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var outputs: [ChapterSplitOutput] = []
        do {
            for (index, chapter) in segments.enumerated() {
                try Task.checkCancellation()
                let base = Self.filename(chapter, index: index)
                let destination = root.appending(
                    path: "\(base).\(plan.fileExtension)"
                )
                let result = try await trimWorkflow.trim(
                    mediaURL: mediaURL,
                    inputProbe: inputProbe,
                    plan: plan,
                    range: MediaTrimRange(
                        startSeconds: chapter.startSeconds,
                        endSeconds: chapter.endSeconds
                    ),
                    mode: .accurate,
                    metadata: metadata,
                    settings: settings,
                    destinationURL: destination,
                    operationID: UUID(),
                    progress: progress
                )
                outputs.append(
                    ChapterSplitOutput(
                        chapter: chapter,
                        filename: base,
                        fileURL: result.fileURL,
                        probe: result.probe
                    )
                )
            }
            return outputs
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    static func contiguousSegments(
        _ chapters: [MediaChapter],
        durationSeconds: Double?
    ) throws -> [MediaChapter] {
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0,
              !chapters.isEmpty,
              chapters.count <= ChapterWorkflow.maximumChapterCount,
              abs(chapters[0].startSeconds) <= 0.002
        else {
            throw ChapterWorkflowError.invalidChapterData
        }
        var result: [MediaChapter] = []
        for index in chapters.indices {
            let start = chapters[index].startSeconds
            let end = chapters.indices.contains(index + 1)
                ? chapters[index + 1].startSeconds
                : durationSeconds
            guard start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start,
                  end <= durationSeconds + 0.002
            else {
                throw ChapterWorkflowError.invalidChapterData
            }
            result.append(
                MediaChapter(
                    title: chapters[index].title,
                    startSeconds: start,
                    endSeconds: end
                )
            )
        }
        return result
    }

    private static func filename(
        _ chapter: MediaChapter,
        index: Int
    ) -> String {
        let number = String(format: "%03d", index + 1)
        let title = FilenameSystem.sanitizeComponent(chapter.title)
        return "\(number) - \(title.isEmpty ? "Chapter" : title)"
    }
}
