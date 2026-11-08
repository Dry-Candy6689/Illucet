import Foundation

/// Estimates saturate instead of wrapping; a storage admission check rejects
/// unrepresentable requirements instead of treating them as an unknown size.
enum StorageByteArithmetic {
    static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        let result = max(0, left).addingReportingOverflow(max(0, right))
        return result.overflow ? .max : result.partialValue
    }

    static func audioEstimate(durationSeconds: Double, bitrateKbps: Int) -> Int64? {
        guard durationSeconds.isFinite, durationSeconds >= 0,
              bitrateKbps >= 0 else { return nil }
        let bytes = durationSeconds * Double(bitrateKbps) * 1_000 / 8
        // Double(Int64.max) rounds up to 2^63, which cannot be converted to Int64.
        guard bytes < Double(Int64.max) else { return .max }
        return Int64(bytes)
    }

    static func validateBudget(
        requiredBytes: Int64,
        reserveBytes: Int64,
        availableBytes: Int64
    ) throws {
        let available = max(0, availableBytes)
        let total = requiredBytes.addingReportingOverflow(reserveBytes)
        guard requiredBytes >= 0, reserveBytes >= 0,
              !total.overflow, total.partialValue <= available
        else {
            let requirement = requiredBytes >= 0 && reserveBytes >= 0 && !total.overflow
                ? total.partialValue : Int64.max
            throw IllucetError.insufficientStorage(required: requirement, available: available)
        }
    }
}
