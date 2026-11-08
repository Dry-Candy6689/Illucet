import Foundation

@main
struct IllucetZIPInteropVerifier {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-ZIP-Interop-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let first = root.appending(path: "01 Alpha.txt")
        let second = root.appending(path: "02 Unicode.txt")
        try Data("alpha\n".utf8).write(to: first)
        try Data("café\n".utf8).write(to: second)
        let archive = root.appending(path: "Illucet-interop.zip")
        let result = try await ZIPArchiveWriter().write(
            sources: [
                ZIPArchiveSource(
                    archivePath: first.lastPathComponent,
                    fileURL: first
                ),
                ZIPArchiveSource(
                    archivePath: "02 Café.txt",
                    fileURL: second
                ),
            ],
            to: archive
        )
        print(archive.path)
        print(
            "entries=\(result.entryCount) source_bytes=\(result.sourceBytes) archive_bytes=\(result.archiveBytes)"
        )
    }
}
