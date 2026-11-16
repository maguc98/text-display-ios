import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import Vision

/// A user-selected video copied out of the Photos picker so AVFoundation can
/// inspect it after the picker transfer has completed.
struct ImportedStatusBarRecording: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiniWatts-StatusBar-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedStatusBarRecording(url: destination)
        }
    }
}

enum StatusBarRecordingImportError: LocalizedError {
    case unreadable
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取所选视频，请重新从照片中选择系统录屏。"
        case .invalidDuration:
            return "视频时长无效或视频中没有可读取的画面。"
        }
    }
}

/// One battery percentage recognized in the top-right status-bar region.
/// seconds is relative to the beginning of the recording.
nonisolated struct RecordedBatteryLevel: Sendable, Hashable {
    let seconds: TimeInterval
    let percent: Int
}

/// Reads only the status-bar battery percentage from a user-selected system
/// recording. It does not start, control, or stream Apple's screen recorder.
nonisolated enum StatusBarRecordingAnalyzer {
    private static let maximumFrames = 600

    static func analyze(url: URL) throws -> [RecordedBatteryLevel] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else {
            throw StatusBarRecordingImportError.invalidDuration
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        // Two-second samples retain normal battery-level transitions while keeping
        // video analysis bounded. Very long recordings are sampled less frequently.
        let interval = max(2.0, duration / Double(maximumFrames))
        var readings: [RecordedBatteryLevel] = []
        var second = 0.0
        var frameCount = 0

        while second < duration, frameCount < maximumFrames {
            defer {
                second += interval
                frameCount += 1
            }

            let time = CMTime(seconds: second, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.004
            // Vision uses a lower-left origin; y=0.88 isolates the top status bar.
            request.regionOfInterest = CGRect(x: 0.68, y: 0.88, width: 0.32, height: 0.12)

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])

            let candidates = (request.results ?? []).compactMap { observation -> (percent: Int, rightEdge: CGFloat)? in
                guard let text = observation.topCandidates(3).first?.string,
                      let percent = parseBatteryPercent(text) else { return nil }
                return (percent, observation.boundingBox.maxX)
            }

            // The battery percentage is the rightmost numeric item in this cropped
            // status-bar area. This avoids mistaking carrier labels such as 5G for it.
            if let match = candidates.max(by: { $0.rightEdge < $1.rightEdge }) {
                readings.append(RecordedBatteryLevel(seconds: second, percent: match.percent))
            }
        }

        return readings
    }

    private static func parseBatteryPercent(_ text: String) -> Int? {
        let percentPattern = #"(100|[0-9]{1,2})\s*%"#
        if let range = text.range(of: percentPattern, options: .regularExpression) {
            let digits = text[range].filter { $0.isNumber }
            if let value = Int(digits), (0...100).contains(value) { return value }
        }

        // Some iOS versions draw the number inside the battery glyph without a
        // literal percent sign. Accept only a standalone one-to-three digit token.
        let standalonePattern = #"^\s*(100|[0-9]{1,2})\s*$"#
        guard let range = text.range(of: standalonePattern, options: .regularExpression) else { return nil }
        let digits = text[range].filter { $0.isNumber }
        guard let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }
}
