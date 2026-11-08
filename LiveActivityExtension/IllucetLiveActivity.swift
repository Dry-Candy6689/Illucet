import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IllucetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Label(context.state.statusText(isStale: context.isStale), systemImage: context.state.symbolName(isStale: context.isStale))
                    .font(.subheadline).lineLimit(1)
                if let fraction = context.isStale ? nil : context.state.fraction { ProgressView(value: fraction) }
                HStack {
                    if let speed = context.isStale ? nil : context.state.speed { Text(speed) }
                    Spacer()
                    Text(Self.remaining(context.state, isStale: context.isStale))
                }.font(.caption)
                if context.isStale, let updatedAt = context.state.updatedAt {
                    (Text("Last updated ") + Text(updatedAt, style: .time))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !context.state.terminal {
                    Link("Open controls", destination: Self.url(context.attributes.jobID))
                        .font(.caption.bold())
                }
            }.padding().activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.white)
                .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: context.state.symbolName(isStale: context.isStale)) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.compactLabel(isStale: context.isStale)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.title).lineLimit(1)
                        Text(context.state.statusText(isStale: context.isStale)).font(.caption).lineLimit(1)
                        if let fraction = context.isStale ? nil : context.state.fraction { ProgressView(value: fraction) }
                        Text(Self.remaining(context.state, isStale: context.isStale)).font(.caption2)
                        if context.isStale, let updatedAt = context.state.updatedAt {
                            (Text("Last updated ") + Text(updatedAt, style: .time))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName(isStale: context.isStale))
                    .accessibilityLabel(context.state.statusText(isStale: context.isStale))
            } compactTrailing: {
                Text(context.state.compactLabel(isStale: context.isStale))
                    .font(.caption2.monospacedDigit()).frame(width: 46, alignment: .trailing)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } minimal: {
                Image(systemName: context.state.symbolName(isStale: context.isStale))
                    .accessibilityLabel(context.state.statusText(isStale: context.isStale))
            }
            .widgetURL(Self.url(context.attributes.jobID))
        }
    }
    private static func remaining(_ state: DownloadActivityAttributes.ContentState, isStale: Bool) -> String {
        if isStale && !state.terminal { return "Open Illucet for current status" }
        return state.remaining ?? (state.showsTimeRemaining && !state.terminal ? "Time remaining unknown" : "")
    }
    private static func url(_ id: UUID) -> URL { URL(string: "illucet://job/\(id.uuidString)")! }
}
