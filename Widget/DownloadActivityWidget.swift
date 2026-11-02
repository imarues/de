import ActivityKit
import SwiftUI
import WidgetKit
import IslandShared

/// Keep the long filename in a full-width region. Leading/trailing regions have
/// very little horizontal space and must never contain long labels.
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text(context.attributes.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(percent(context.state))
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                }
                if context.state.hasTotal {
                    ProgressView(value: context.state.fraction)
                        .tint(.blue)
                } else {
                    ProgressView().tint(.blue)
                }
                HStack {
                    Text(transfer(context.state))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(speed(context.state))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .activityBackgroundTint(Color.black.opacity(0.9))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Download")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(context.attributes.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if context.state.hasTotal {
                            ProgressView(value: context.state.fraction)
                                .tint(.blue)
                                .frame(maxWidth: .infinity)
                        } else {
                            ProgressView()
                                .tint(.blue)
                                .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 8) {
                            Text(transfer(context.state))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(speed(context.state))
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text(percent(context.state))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }
            .keylineTint(.blue)
        }
    }

    private func percent(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.hasTotal ? "\(state.percent)%" : "…"
    }

    private func transfer(_ state: DownloadActivityAttributes.ContentState) -> String {
        let received = ByteCountFormatter.string(
            fromByteCount: max(0, state.bytesReceived), countStyle: .file)
        guard state.hasTotal else { return received }
        let total = ByteCountFormatter.string(
            fromByteCount: state.bytesExpected, countStyle: .file)
        return "\(received) / \(total)"
    }

    private func speed(_ state: DownloadActivityAttributes.ContentState) -> String {
        switch state.phase {
        case "completed": return "Complete"
        case "failed": return "Failed"
        case "paused": return "Paused"
        default:
            guard state.bytesPerSecond > 0 else { return "Downloading" }
            let perSecond = ByteCountFormatter.string(
                fromByteCount: Int64(state.bytesPerSecond), countStyle: .file)
            return "\(perSecond)/s"
        }
    }
}

@main
struct DownloadWidgetBundle: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}
