import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO

/// Image and video tabs cannot be edited as text, so the editor shows a preview instead of
/// the binary-file placeholder. Classification is by extension, case-insensitive, matching
/// what the status bar and `--audit` use so those three cannot disagree.
enum MediaKind: Equatable {
    case image
    case video

    static func of(url: URL) -> MediaKind? {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp":
            return .image
        case "mp4", "mov", "m4v":
            return .video
        default:
            return nil
        }
    }
}

enum MediaInfo {
    /// Pixel size of the image as stored, not the point size NSImage reports on a retina display.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let time = try await asset.load(.duration)
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// The image, scaled to fit the editor area. Built as a real NSImageView so `--audit` can
/// histogram the same view the window shows.
struct ImagePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ImagePreviewView {
        ImagePreviewView(url: url)
    }

    func updateNSView(_ view: ImagePreviewView, context: Context) {
        view.url = url
        // Agents rewrite files under open tabs; text tabs reload, and this must too.
        view.reloadIfChanged()
    }
}

final class ImagePreviewView: NSView {
    var url: URL {
        didSet { if url != oldValue { reload() } }
    }
    private let imageView = NSImageView()
    private var loadedModificationDate: Date?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        addSubview(imageView)
        reload()
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = EditorTheme.background.cgColor
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    /// Re-read only when the file on disk is newer than what is showing — cheap enough to
    /// call on every SwiftUI update pass.
    func reloadIfChanged() {
        if modificationDate() != loadedModificationDate { reload() }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func reload() {
        loadedModificationDate = modificationDate()
        imageView.image = NSImage(contentsOf: url)
        needsDisplay = true
    }
}

/// AVKit player with the standard playback controls. The player is paused and dropped when
/// the tab goes away so a hidden video does not keep decoding.
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Duration of the active video tab, loaded off the view body so a slow asset does not stall
/// the status bar. Image dimensions are sync and live next to this in the pane.
struct MediaDurationLabel: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        Text(text)
            .task(id: url) {
                if let seconds = await MediaInfo.duration(of: url) {
                    text = MediaInfo.formatDuration(seconds)
                }
            }
    }
}
