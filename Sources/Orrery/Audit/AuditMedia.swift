import AppKit
import AVFoundation

/// Image and video tabs: the editor must route them to a preview, the preview must actually
/// put pixels on screen, and a video must report a real duration. Classification-only checks
/// would pass while the pane still showed the binary placeholder.
@MainActor
enum AuditMedia {

    static func run(_ audit: Auditor) async {
        routing(audit)
        await Auditor.withTemporaryDirectory { dir in
            await image(audit, dir)
            await video(audit, dir)
        }
    }

    // MARK: - Routing

    private static func routing(_ audit: Auditor) {
        audit.section("Media — routing by extension")
        func kind(_ name: String) -> MediaKind? {
            MediaKind.of(url: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        audit.equal("png is an image", kind("logo.png"), .image)
        audit.equal("jpeg is an image regardless of case", kind("Shot.JPEG"), .image)
        audit.equal("webp is an image", kind("pic.webp"), .image)
        audit.equal("mp4 is a video", kind("clip.mp4"), .video)
        audit.equal("MOV is a video regardless of case", kind("Clip.MOV"), .video)
        audit.equal("a Swift file is not media", kind("App.swift"), nil)
        audit.equal("a PNG-magic binary with no image extension is not an image tab",
                    kind("logo.bin"), nil)
    }

    // MARK: - Image

    private static func image(_ audit: Auditor, _ dir: URL) async {
        audit.section("Media — image preview")
        let png = dir.appendingPathComponent("swatch.png")
        let width = 80, height = 60
        audit.check("a PNG can be generated for the preview check",
                    writePNG(to: png, width: width, height: height, colour: .magenta))

        let model = AppModel(trust: .forAudit)
        model.openProject(dir)
        model.open(file: png)
        audit.check("opening an image through AppModel puts it in the active tab",
                    model.documents.active?.url == png)
        audit.equal("opening an image routes to the image path",
                    model.documents.active.flatMap { MediaKind.of(url: $0.url) }, .image)
        let reported = model.documents.active.flatMap { MediaInfo.pixelSize(of: $0.url) }
        audit.check("the status bar can read the pixel size",
                    reported?.width == width && reported?.height == height,
                    "got \(reported.map { "\($0.width)×\($0.height)" } ?? "nil"), expected \(width)×\(height)")

        guard let appearance = NSAppearance(named: .aqua) else { return }
        let view = ImagePreviewView(url: png)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.colorSpace = .sRGB
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let counts = AuditRendering.histogram(view, view.bounds)
        let samples = counts.values.reduce(0, +)
        var background = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            background = EditorTheme.background.usingColorSpace(.sRGB) ?? .white
        }
        var nonBackground = 0
        for (colour, n) in counts {
            guard let sample = colour.usingColorSpace(.sRGB) else { continue }
            let distance = abs(sample.redComponent - background.redComponent)
                + abs(sample.greenComponent - background.greenComponent)
                + abs(sample.blueComponent - background.blueComponent)
            if distance >= 0.25 { nonBackground += n }
        }
        audit.check("the image preview contains non-background pixels",
                    nonBackground >= 500,
                    "\(nonBackground) of \(samples) samples were not the editor background")

        // Agents rewrite files under open tabs. When the PNG changes on disk, the preview must
        // show the new pixels, not the bitmap it loaded first.
        let magentaCount = count(of: .magenta, in: view, appearance: appearance)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3)],
                                               ofItemAtPath: png.path)
        _ = writePNG(to: png, width: width, height: height, colour: .green)
        view.reloadIfChanged()
        view.layoutSubtreeIfNeeded()
        let magentaAfter = count(of: .magenta, in: view, appearance: appearance)
        let greenAfter = count(of: .green, in: view, appearance: appearance)
        audit.check("a replaced image reloads from disk",
                    magentaCount >= 500 && magentaAfter < magentaCount / 4
                    && greenAfter >= 500,
                    "magenta \(magentaCount) → \(magentaAfter), green after \(greenAfter)")
        window.contentView = nil
    }

    // MARK: - Video

    private static func video(_ audit: Auditor, _ dir: URL) async {
        audit.section("Media — video preview")
        let mp4 = dir.appendingPathComponent("clip.mp4")
        var error = await writeTinyMovie(to: mp4, fileType: .mp4, codec: .h264)
        var url = mp4
        if error != nil {
            let mov = dir.appendingPathComponent("clip.mov")
            error = await writeTinyMovie(to: mov, fileType: .mov, codec: .jpeg)
            url = mov
        }
        audit.check("a tiny movie can be generated with AVAssetWriter",
                    error == nil && FileManager.default.fileExists(atPath: url.path),
                    error ?? "file missing")

        let model = AppModel(trust: .forAudit)
        model.openProject(dir)
        model.open(file: url)
        audit.check("opening a video through AppModel puts it in the active tab",
                    model.documents.active?.url == url)
        audit.equal("opening a video routes to the video path",
                    model.documents.active.flatMap { MediaKind.of(url: $0.url) }, .video)

        let seconds = await MediaInfo.duration(of: url)
        audit.check("the reported duration is greater than zero",
                    (seconds ?? 0) > 0,
                    seconds.map { String(format: "%.3fs", $0) } ?? "nil")
    }

    /// Pixels within a small distance of `target`, for the reload check.
    private static func count(of target: NSColor, in view: NSView,
                              appearance: NSAppearance) -> Int {
        var wanted = target
        appearance.performAsCurrentDrawingAppearance {
            wanted = target.usingColorSpace(.sRGB) ?? target
        }
        var total = 0
        for (colour, n) in AuditRendering.histogram(view, view.bounds) {
            guard let sample = colour.usingColorSpace(.sRGB) else { continue }
            let distance = abs(sample.redComponent - wanted.redComponent)
                + abs(sample.greenComponent - wanted.greenComponent)
                + abs(sample.blueComponent - wanted.blueComponent)
            if distance < 0.35 { total += n }
        }
        return total
    }

    // MARK: - Fixtures

    private static func writePNG(to url: URL, width: Int, height: Int, colour: NSColor) -> Bool {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.usingColorSpace(.sRGB)?.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// A short solid-colour clip. H.264 in an mp4 is tried first; JPEG in a mov is the
    /// fallback so the check still runs on machines without a hardware encoder.
    private static func writeTinyMovie(to url: URL, fileType: AVFileType,
                                       codec: AVVideoCodecType) async -> String? {
        try? FileManager.default.removeItem(at: url)
        let width = 128, height = 96
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            return error.localizedDescription
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return "cannot add video input for \(codec.rawValue)" }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.startWriting() else {
            return writer.error?.localizedDescription ?? "startWriting failed"
        }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 10
        let frames = 15
        for index in 0..<frames {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                waits += 1
                if waits > 400 { return "writer input never became ready" }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let buffer = pixelBuffer(width: width, height: height) else {
                return "could not create a pixel buffer"
            }
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) {
                return writer.error?.localizedDescription ?? "append failed at frame \(index)"
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            return writer.error?.localizedDescription
                ?? "writer status \(writer.status.rawValue)"
        }
        return nil
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4 + 0] = 0
                row[x * 4 + 1] = 0
                row[x * 4 + 2] = 255
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}
