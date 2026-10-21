import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// The answer to a `render-tikz` request. MIRRORED by `TikzResult` in
/// packages/editor-core/src/editor/tikz-renderer.ts: change both.
public enum TikzRenderResult: Equatable, Sendable, Codable {
    /// A PNG data URL and its size in CSS pixels.
    case image(url: String, width: Double, height: Double)
    /// The TeX error, for the caption under the figure.
    case error(String)

    private enum CodingKeys: String, CodingKey { case url, width, height, error }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url, width, height):
            try c.encode(url, forKey: .url)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
        case let .error(message):
            try c.encode(message, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try c.decodeIfPresent(String.self, forKey: .error) {
            self = .error(message)
        } else {
            self = .image(url: try c.decode(String.self, forKey: .url),
                          width: try c.decode(Double.self, forKey: .width),
                          height: try c.decode(Double.self, forKey: .height))
        }
    }
}

/// Typesets the standalone documents the editor's TikZ widgets send
/// (editor-core's tikz-source.ts builds them) with pdflatex, and rasterizes
/// the cropped page to a PNG. Runs are deduplicated per document, capped at
/// `maxConcurrent`, and cached in memory and, for successes, on disk.
public actor TikzRenderService {
    /// pdflatex runs in the document's folder, so `\input{macros}` and
    /// relative `\includegraphics` resolve; its output goes to a temp folder.
    public struct Request: Sendable {
        public var document: String
        public var workingDirectory: URL?

        public init(document: String, workingDirectory: URL?) {
            self.document = document
            self.workingDirectory = workingDirectory
        }

        /// The working directory is part of the key: the same picture can
        /// `\input` different macros in two folders.
        var key: String {
            let digest = SHA256.hash(data: Data((workingDirectory?.path ?? "").utf8) + Data([0]) + Data(document.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// CSS pixels per TeX big point (1/72 in against 1/96 in).
    static let cssPerPoint = 4.0 / 3.0
    /// Device pixels per CSS pixel: Retina, with headroom for zoom.
    static let pixelsPerCSS = 3.0
    /// A poster-sized figure is drawn smaller rather than as a huge PNG.
    static let maxPixelSide = 4096.0

    private let locator: @Sendable () -> ToolLocator?
    private let cacheDirectory: URL?
    private let maxConcurrent: Int
    private let timeout: TimeInterval

    private var memory: [String: TikzRenderResult] = [:]
    private var memoryOrder: [String] = []
    private static let memoryLimit = 128
    /// Every paused edit that compiles is a new entry: past the limit the
    /// least recently used go, down to `diskKeep`.
    static let diskLimit = 400
    static let diskKeep = 300
    private var diskWrites = 0
    private var inFlight: [String: Task<TikzRenderResult?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `locator` is called off the actor and may block (the login shell);
    /// nil means TeX can't run here (a sandboxed build), and every request
    /// answers nil.
    public init(
        locator: @escaping @Sendable () -> ToolLocator?,
        cacheDirectory: URL?,
        maxConcurrent: Int = 2,
        timeout: TimeInterval = 20
    ) {
        self.locator = locator
        self.cacheDirectory = cacheDirectory
        self.maxConcurrent = maxConcurrent
        self.timeout = timeout
    }

    /// The figure, the TeX error, or nil when pdflatex is not installed.
    public func render(_ request: Request) async -> TikzRenderResult? {
        let key = request.key
        if let hit = memory[key] { return hit }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.produce(request, key: key) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { remember(key, result) }
        return result
    }

    private func produce(_ request: Request, key: String) async -> TikzRenderResult? {
        if let cached = readDiskCache(key) { return cached }
        await acquire()
        defer { release() }
        let (locator, timeout) = (self.locator, self.timeout)
        let result = await withCheckedContinuation { (done: CheckedContinuation<TikzRenderResult?, Never>) in
            // Process.waitUntilExit blocks: keep it off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let tools = locator() else { return done.resume(returning: nil) }
                done.resume(returning: Self.typeset(request, tools: tools, timeout: timeout))
            }
        }
        if case .image = result { writeDiskCache(key, result!) }
        return result
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot straight to the next waiter, so `running` never dips.
    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func remember(_ key: String, _ result: TikzRenderResult) {
        if memory.updateValue(result, forKey: key) == nil { memoryOrder.append(key) }
        if memoryOrder.count > Self.memoryLimit { memory[memoryOrder.removeFirst()] = nil }
    }

    private func readDiskCache(_ key: String) -> TikzRenderResult? {
        guard let url = cacheDirectory?.appendingPathComponent(key + ".json"),
              let data = try? Data(contentsOf: url) else { return nil }
        // The modification date is the recency `pruneDiskCache` sorts by.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return try? JSONDecoder().decode(TikzRenderResult.self, from: data)
    }

    private func writeDiskCache(_ key: String, _ result: TikzRenderResult) {
        guard let dir = cacheDirectory, let data = try? JSONEncoder().encode(result) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(key + ".json"), options: .atomic)
        // The first write of a launch, then every 50th: a listing per write is waste.
        if diskWrites % 50 == 0 { Self.pruneDiskCache(dir) }
        diskWrites += 1
    }

    static func pruneDiskCache(_ dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), entries.count > diskLimit
        else { return }
        let dated = entries.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(diskKeep) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Typesetting (blocking)

    /// One pdflatex run in a fresh temp folder, then the PDF's first page as a PNG.
    static func typeset(_ request: Request, tools: ToolLocator, timeout: TimeInterval) -> TikzRenderResult? {
        guard tools.locate("pdflatex") != nil else { return nil }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("chalk-tikz-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("figure.tex")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try request.document.write(to: source, atomically: true, encoding: .utf8)
        } catch {
            return .error("Could not write the figure: \(error.localizedDescription)")
        }
        let pdf = scratch.appendingPathComponent("figure.pdf")
        let job = CompileJob(
            source: source,
            workingDirectory: request.workingDirectory ?? scratch,
            pdf: pdf,
            plan: .steps([CompileStep("pdflatex", [
                "-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape",
                "-output-directory=\(scratch.path)", source.path,
            ])]),
            notes: [],
            staged: nil
        )
        let outcome = CompileProcessRunner(locator: tools, timeout: timeout).run(job)
        guard outcome.succeeded, let made = outcome.pdf else {
            return .error(errorMessage(log: outcome.log, timeout: timeout))
        }
        return rasterize(pdf: made) ?? .error("pdflatex wrote no picture.")
    }

    /// TeX's first `! …` error with its `l.N …` context line, else a fallback.
    static func errorMessage(log: String, timeout: TimeInterval) -> String {
        let lines = log.components(separatedBy: "\n")
        if let bang = lines.firstIndex(where: { $0.hasPrefix("! ") }) {
            var message = lines[bang]
            if let context = lines[bang...].prefix(12).first(where: { $0.hasPrefix("l.") }) {
                message += "\n" + context
            }
            return message
        }
        if log.contains("[chalk] pdflatex stopped after") {
            return "pdflatex took longer than \(Int(timeout)) s."
        }
        if log.contains("[chalk] pdflatex not found") { return "pdflatex not found." }
        return "pdflatex failed."
    }

    /// The first page on a transparent ground, at `pixelsPerCSS` (fewer for
    /// a very large page), as a PNG data URL with its CSS size.
    static func rasterize(pdf: URL) -> TikzRenderResult? {
        guard let document = CGPDFDocument(pdf as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let cssWidth = box.width * cssPerPoint
        let cssHeight = box.height * cssPerPoint
        let density = min(pixelsPerCSS, maxPixelSide / max(cssWidth, cssHeight))
        let pixelsPerPoint = cssPerPoint * density
        let width = Int((box.width * pixelsPerPoint).rounded(.up))
        let height = Int((box.height * pixelsPerPoint).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let png = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return .image(url: "data:image/png;base64," + (png as Data).base64EncodedString(),
                      width: (Double(cssWidth) * 100).rounded() / 100,
                      height: (Double(cssHeight) * 100).rounded() / 100)
    }
}
