import Foundation
import SwiftUI

@_silgen_name("KiraIslandStart")
private func islandStart(_ id: Int32, _ fileName: UnsafePointer<CChar>?)
@_silgen_name("KiraIslandProgress")
private func islandProgress(_ id: Int32, _ received: Int64, _ expected: Int64, _ speed: Double)
@_silgen_name("KiraIslandFinish")
private func islandFinish(_ id: Int32, _ successful: Bool, _ received: Int64, _ expected: Int64)

@MainActor
final class DemoDownloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var urlText = "https://dl.ikiraplus.workers.dev/dl/regram-452.0.1-v6.5-cracked"
    @Published var info = "Ready"
    @Published var progress = 0.0
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private var last: [Int: (bytes: Int64, time: Date)] = [:]
    private var finalSizes: [Int: Int64] = [:]
    private var handled: Set<Int> = []

    func download() {
        guard let url = URL(string: urlText), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            info = "Invalid URL"
            return
        }
        let task = session.downloadTask(with: url)
        let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        info = "Downloading \(name)"
        progress = 0
        name.withCString { islandStart(Int32(task.taskIdentifier), $0) }
        task.resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let id = downloadTask.taskIdentifier
            let now = Date()
            let speed: Double
            if let sample = last[id], now.timeIntervalSince(sample.time) > 0 {
                speed = Double(totalBytesWritten - sample.bytes) / now.timeIntervalSince(sample.time)
            } else {
                speed = 0
            }
            last[id] = (totalBytesWritten, now)
            finalSizes[id] = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
            islandProgress(Int32(id), totalBytesWritten, totalBytesExpectedToWrite, speed)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let name = downloadTask.response?.suggestedFilename ?? UUID().uuidString
        let destination = docs.appendingPathComponent(UUID().uuidString + "-" + name)
        let success = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            handled.insert(taskID)
            info = success ? "Saved \(name)" : "Could not save file"
            islandFinish(Int32(taskID), success, bytes, finalSizes[taskID] ?? bytes)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor in
            let id = task.taskIdentifier
            if !handled.contains(id) {
                info = "Download failed"
                islandFinish(Int32(id), false, 0, finalSizes[id] ?? -1)
            }
        }
    }
}

@main
struct IslandDemoApp: App {
    @StateObject private var dm = DemoDownloads()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 18) {
                Text("DataManager Island Test").font(.title2)
                TextField("File URL", text: $dm.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Start real download") { dm.download() }.buttonStyle(.borderedProminent)
                ProgressView(value: dm.progress)
                Text(dm.info).font(.caption).multilineTextAlignment(.center)
            }.padding()
        }
    }
}
