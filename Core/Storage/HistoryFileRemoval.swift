import Foundation

/// A failed record stays in History so its remaining outputs can be retried.
enum HistoryFileRemoval {
    struct Result: Equatable, Sendable {
        var removedRecordIDs: Set<UUID> = []
        var failedRecordIDs: Set<UUID> = []
        var failedFileCount = 0
    }

    static func remove(
        records: [HistoryRecord],
        documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        folderBookmark: Data? = nil,
        resolver suppliedResolver: SavedOutputResolver? = nil,
        removeFile: ((URL) throws -> Void)? = nil
    ) -> Result {
        let resolver = suppliedResolver ?? SavedOutputResolver(documentsURL: documentsURL)
        var result = Result()
        for record in records {
            let access = resolver.open(record, fallbackBookmark: folderBookmark, allowMissing: true)
            var failed = false
            for url in record.ownedFileURLs {
                do {
                    // The injected operation keeps deterministic failure fixtures independent of disk.
                    if let removeFile { try removeFile(url) }
                    else { try access.remove(url) }
                } catch { failed = true; result.failedFileCount += 1 }
            }
            if failed { result.failedRecordIDs.insert(record.id) }
            else { result.removedRecordIDs.insert(record.id) }
        }
        return result
    }
}
