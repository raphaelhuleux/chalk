// Records ONE window as a frame sequence: `winrec <pid> <seconds> <fps> <outdir>`.
// A ScreenCaptureKit stream filtered to that window, so nothing else on the
// screen enters the recording and the window need not be in front. Frames are
// PNG, `f0001.png`..., at the window's backing scale, with `times.txt` giving
// each frame's time from the start. Needs Screen Recording permission.
// Build: swiftc -O -parse-as-library scripts/screenshots/winrec.swift -o winrec
import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class Sink: NSObject, SCStreamOutput {
    private let outDir: URL
    private let context = CIContext()
    private(set) var index = 0
    private(set) var times: [String] = []

    init(outDir: URL) { self.outDir = outDir }

    private var firstPTS: Double?
    private(set) var firstWallTime: Double?

    /// Each frame's time is the stream's own presentation timestamp, not the
    /// moment this handler got to it: encoding runs behind the stream, and a
    /// wall clock here drifted a second late by the end of a run.
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if firstPTS == nil {
            firstPTS = pts
            // The first frame's wall time, taken on arrival (the queue is empty then), so a
            // run can be lined up with the app's own trace.
            firstWallTime = Date().timeIntervalSince1970
        }
        // Half size: four times fewer pixels to encode, so the queue keeps up
        // and the stream drops nothing; a one-frame fault is still 550 px wide.
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        index += 1
        let url = outDir.appendingPathComponent(String(format: "f%04d.png", index))
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        times.append(String(format: "%d %.3f", index, pts - (firstPTS ?? pts)))
    }
}

@main
struct WinRec {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 || args.count == 6, let pid = Int32(args[1]), let seconds = Double(args[2]),
              let fps = Double(args[3]) else {
            FileHandle.standardError.write(Data("usage: winrec <pid> <seconds> <fps> <outdir> [<window width in pt>]\n".utf8))
            exit(2)
        }
        // The app's largest window by default (the editor); a width picks another (Settings is 900).
        let wantedWidth = args.count == 6 ? Double(args[5]) : nil
        let outDir = URL(fileURLWithPath: args[4], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // A window-server connection, which a bare command-line process lacks.
        _ = NSApplication.shared

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.windowLayer == 0
                && (wantedWidth.map { abs(Double(window.frame.width) - $0) < 1 } ?? true)
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            FileHandle.standardError.write(Data("no on-screen window for pid \(pid)\n".utf8))
            exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        let sink = Sink(outDir: outDir)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "winrec"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        let header = String(format: "epoch %.3f\n", sink.firstWallTime ?? 0)
        try? (header + sink.times.joined(separator: "\n") + "\n")
            .write(to: outDir.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        print("\(sink.index) frames, \(Int(window.frame.width))x\(Int(window.frame.height)) pt")
    }
}
