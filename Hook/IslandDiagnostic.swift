import ActivityKit
import UIKit
import Foundation
import IslandShared

/// Diagnostic only: explicitly asks iOS to create a Live Activity after the host app becomes active.
@MainActor
private final class IslandInstallDiagnostic {
    static let shared = IslandInstallDiagnostic()
    private var started = false
    private var token: NSObjectProtocol?
    private var activeTest: Activity<DownloadActivityAttributes>?

    func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runIfNeeded() }
        }
        if UIApplication.shared.applicationState == .active {
            runIfNeeded()
        }
        NSLog("[KiraIsland-DIAGNOSTIC] observer installed")
    }

    private func runIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
            guard enabled else {
                NSLog("[KiraIsland-DIAGNOSTIC] Live Activities disabled by iOS")
                showStatus("Live Activities are disabled in iOS settings. Enable them for DataManager and try again.")
                return
            }
            let attrs = DownloadActivityAttributes(
                downloadID: "diagnostic-island",
                fileName: "ISLAND TEST - not a download"
            )
            let state = DownloadActivityAttributes.ContentState(
                bytesReceived: 1, bytesExpected: 2,
                bytesPerSecond: 0, phase: "diagnostic"
            )
            do {
                let act = try Activity<DownloadActivityAttributes>.request(
                    attributes: attrs,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                activeTest = act
                NSLog("[KiraIsland-DIAGNOSTIC] Activity.request SUCCESS: %@", act.id)
                showStatus("iOS accepted the test Live Activity. Look for 'ISLAND TEST' on Dynamic Island or Lock Screen. If it does NOT appear, check Widget extension registration and signing.")
                Task {
                    try? await Task.sleep(nanoseconds: 35_000_000_000)
                    await act.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                    activeTest = nil
                }
            } catch {
                let message = "Activity.request failed: " + String(describing: error)
                NSLog("[KiraIsland-DIAGNOSTIC] %@", message)
                showStatus(message)
            }
        }
    }

    private func showStatus(_ message: String) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let controller = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            NSLog("[KiraIsland-DIAGNOSTIC] Alert unavailable: %@", message)
            return
        }
        var top = controller
        while let next = top.presentedViewController {
            top = next
        }
        let alert = UIAlertController(title: "DataManager Island Diagnostic", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }
}

@_cdecl("KiraIslandRunDiagnostics")
public func KiraIslandRunDiagnostics() {
    DispatchQueue.main.async {
        IslandInstallDiagnostic.shared.install()
    }
}
