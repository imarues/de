import ActivityKit
import Foundation
import IslandShared

@MainActor
private final class LiveDownloadTracker {
    static let shared = LiveDownloadTracker()
    private var activities: [Int: Activity<DownloadActivityAttributes>] = [:]
    private var recent: [Int: (time: Date, percent: Int)] = [:]

    func start(id: Int, name: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[id] == nil else { return }
        let attrs = DownloadActivityAttributes(downloadID: String(id), fileName: name)
        let state = DownloadActivityAttributes.ContentState(
            bytesReceived: 0, bytesExpected: -1, bytesPerSecond: 0, phase: "downloading")
        do {
            activities[id] = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
        } catch {
            NSLog("[KiraIsland] Failed to start: %@", String(describing: error))
        }
    }

    func progress(id: Int, received: Int64, expected: Int64, speed: Double) {
        guard let activity = activities[id] else { return }
        let now = Date()
        let pct = expected > 0 ? Int((100.0 * Double(received) / Double(expected)).rounded()) : -1
        if let last = recent[id], now.timeIntervalSince(last.time) < 1.0, last.percent == pct { return }
        recent[id] = (now, pct)
        let state = DownloadActivityAttributes.ContentState(
            bytesReceived: max(0, received), bytesExpected: expected,
            bytesPerSecond: max(0, speed), phase: "downloading")
        Task {
            await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(120)))
        }
    }

    func finish(id: Int, succeeded: Bool, received: Int64, expected: Int64) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        recent.removeValue(forKey: id)
        let state = DownloadActivityAttributes.ContentState(
            bytesReceived: max(0, received), bytesExpected: expected, bytesPerSecond: 0,
            phase: succeeded ? "completed" : "failed")
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
    }
}

@_cdecl("KiraIslandStart")
public func KiraIslandStart(_ taskID: Int32, _ cFileName: UnsafePointer<CChar>?) {
    let name = cFileName.map { String(cString: $0) } ?? "Download"
    DispatchQueue.main.async {
        LiveDownloadTracker.shared.start(id: Int(taskID), name: name)
    }
}

@_cdecl("KiraIslandProgress")
public func KiraIslandProgress(_ taskID: Int32, _ received: Int64, _ expected: Int64, _ speed: Double) {
    DispatchQueue.main.async {
        LiveDownloadTracker.shared.progress(id: Int(taskID), received: received, expected: expected, speed: speed)
    }
}

@_cdecl("KiraIslandFinish")
public func KiraIslandFinish(_ taskID: Int32, _ succeeded: Bool, _ received: Int64, _ expected: Int64) {
    DispatchQueue.main.async {
        LiveDownloadTracker.shared.finish(id: Int(taskID), succeeded: succeeded, received: received, expected: expected)
    }
}
