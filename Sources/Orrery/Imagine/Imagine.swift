import AppKit
import Foundation

/// Grok's Imagine tools (`image_gen`, `image_edit`, `image_to_video`) run inside the same agent
/// session Solo already uses; this composes an unambiguous instruction for them and the chat
/// shows what came back. Video needs a SuperGrok plan, which the agent reports itself.
struct ImagineRequest: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case image, video, edit
        var id: String { rawValue }
        var title: String {
            switch self { case .image: return "Image from text"; case .video: return "Video from an image"; case .edit: return "Edit an image" }
        }
    }
    static let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4"]
    static let durations = [6, 10]
    static let resolutions = ["480p", "720p"]

    var kind: Kind = .image
    var prompt = ""
    var aspectRatio = "1:1"
    var duration = 6
    var resolution = "480p"
    var referencePath: String?

    var isReady: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (kind == .image || referencePath != nil)
    }

    var instruction: String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .image:
            return "Use your image_gen tool with aspect_ratio \"\(aspectRatio)\" and this prompt: \(text)\n"
                + "Do not write any other files. When it is saved, reply with the image's absolute path on its own line and one sentence about it."
        case .video:
            return "Use your image_to_video tool with image=\"\(referencePath ?? "")\", duration=\(duration), resolution_name=\"\(resolution)\" and this prompt: \(text)\n"
                + "Do not write any other files. When it is saved, reply with the video's absolute path on its own line and one sentence about it. If video generation is not available on this plan, say so plainly."
        case .edit:
            return "Use your image_edit tool with image=\"\(referencePath ?? "")\" and this prompt: \(text)\n"
                + "Do not write any other files. When it is saved, reply with the edited image's absolute path on its own line and one sentence about what changed."
        }
    }
}

/// Files a tool reported, found by their path in its output; images and videos the chat can show.
enum MediaPaths {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let limit = 8

    static func isVideo(_ path: String) -> Bool { videoExtensions.contains((path as NSString).pathExtension.lowercased()) }

    static func paths(in text: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard !text.isEmpty else { return [] }
        // JSON escapes slashes; unescape before matching.
        let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
        let pattern = try! NSRegularExpression(pattern: #"(/[^\s"'<>|]+?\.(?:jpg|jpeg|png|gif|webp|heic|bmp|tiff|mp4|mov|m4v|webm))(?=[\s"'<>|,;)\]}]|$)"#, options: [.caseInsensitive])
        var found: [String] = []
        for match in pattern.matches(in: unescaped, range: NSRange(unescaped.startIndex..., in: unescaped)) {
            guard let range = Range(match.range(at: 1), in: unescaped) else { continue }
            // Grok's session folders are literally percent-encoded on disk (`%2FUsers%2F…`), so
            // the raw path is tried first; decoding is only a fallback for URL-escaped output.
            let raw = String(unescaped[range])
            let path: String
            if fileExists(raw) { path = raw }
            else if let decoded = raw.removingPercentEncoding, decoded != raw, fileExists(decoded) { path = decoded }
            else { continue }
            guard !found.contains(path) else { continue }
            found.append(path)
            if found.count >= limit { break }
        }
        return found
    }

    /// Copies a generated file into `<project>/images` (or `videos`) under a name that does not
    /// collide, and returns the destination.
    static func copyIntoProject(_ path: String, project: URL) throws -> URL {
        let source = URL(fileURLWithPath: path)
        let folder = project.appendingPathComponent(isVideo(path) ? "videos" : "images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(counter).\(ext)"); counter += 1
        }
        try FileManager.default.copyItem(at: source, to: candidate)
        return candidate
    }
}

extension ToolDetail {
    var mediaPaths: [String] { MediaPaths.paths(in: output + "\n" + rawInput) }
}
