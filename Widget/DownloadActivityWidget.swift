import ActivityKit
import SwiftUI
import WidgetKit
import IslandShared

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(context.attributes.fileName).lineLimit(1).font(.headline)
                    Spacer(minLength: 4)
                    Text(label(context.state)).monospacedDigit()
                }
                if context.state.hasTotal {
                    ProgressView(value: context.state.fraction).tint(.blue)
                } else {
                    ProgressView().tint(.blue)
                }
                HStack {
                    Text(context.state.phase)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: context.state.bytesReceived, countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Download", systemImage: "arrow.down.circle").font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(label(context.state)).monospacedDigit().font(.headline)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.fileName).lineLimit(1).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        if context.state.hasTotal {
                            ProgressView(value: context.state.fraction).tint(.blue)
                        } else {
                            ProgressView().tint(.blue)
                        }
                        Text(context.state.phase).font(.caption2)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text(label(context.state)).monospacedDigit().font(.caption2)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
            }.keylineTint(.blue)
        }
    }
    private func label(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.hasTotal ? "\(state.percent)%" : "…"
    }
}
@main
struct DownloadWidgetBundle: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}
