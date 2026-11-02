import ActivityKit
import Foundation

public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bytesReceived: Int64
        public var bytesExpected: Int64
        public var bytesPerSecond: Double
        public var phase: String

        public init(bytesReceived: Int64, bytesExpected: Int64, bytesPerSecond: Double, phase: String) {
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            self.bytesPerSecond = bytesPerSecond
            self.phase = phase
        }

        public var hasTotal: Bool { bytesExpected > 0 }
        public var fraction: Double {
            hasTotal ? min(1, max(0, Double(bytesReceived) / Double(bytesExpected))) : 0
        }
        public var percent: Int { Int((fraction * 100).rounded()) }
    }
    public var downloadID: String
    public var fileName: String

    public init(downloadID: String, fileName: String) {
        self.downloadID = downloadID
        self.fileName = fileName
    }
}
