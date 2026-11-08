import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable {
        case preparing, downloading, processing, waiting, paused, needsAttention, failed, completed, cancelled
    }

    struct ContentState: Codable, Hashable, Sendable {
        var stage: String
        var fraction: Double?
        var speed: String?
        var remaining: String?
        var terminal: Bool
        var updatedAt: Date? = nil
        // Optional so activities created by an older app version still decode.
        var phase: Phase? = nil

        func symbolName(isStale: Bool) -> String {
            if isStale && !terminal { return "exclamationmark.circle" }
            switch phase {
            case .preparing: return "hourglass"
            case .processing: return "gearshape"
            case .waiting: return "clock"
            case .paused: return "pause.circle"
            case .needsAttention: return "exclamationmark.circle"
            case .failed: return "exclamationmark.triangle.fill"
            case .completed: return "checkmark.circle.fill"
            case .cancelled: return "xmark.circle"
            case .downloading, nil: return "arrow.down.circle"
            }
        }

        func compactLabel(isStale: Bool) -> String {
            if isStale && !terminal { return "Open" }
            switch phase {
            case .needsAttention: return "Open"
            case .failed: return "Failed"
            case .paused: return "Paused"
            case .waiting: return "Wait"
            case .completed: return "Done"
            case .cancelled: return "Stopped"
            default:
                guard let fraction, fraction.isFinite, fraction > 0 else { return "…" }
                return "\(Int(min(1, fraction) * 100))%"
            }
        }

        func statusText(isStale: Bool) -> String {
            isStale && !terminal ? "Open Illucet to check progress" : stage
        }

        var showsTimeRemaining: Bool {
            phase == nil || phase == .downloading || phase == .processing
        }
    }
    var jobID: UUID
    var title: String
}
