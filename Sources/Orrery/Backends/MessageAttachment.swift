import Foundation
import AppKit
import ImageIO

struct MessageAttachment: Identifiable, Codable {
    var id = UUID()
    let name: String
    let data: Data
    let mimeType: String?
    var isImage: Bool { mimeType != nil }
    static let limit = 8 * 1024 * 1024

    init(name: String, text: String) throws {
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.limit, !text.contains("\0") else {
            throw ComputerError("The selected context is too large. Select a smaller section.")
        }
        self.name = String(name.prefix(300)); data = bytes; mimeType = nil
    }

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.limit else {
            throw ComputerError("Attach a regular file smaller than 8 MB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let contents = try file.read(upToCount: Self.limit + 1) ?? Data()
        guard contents.count <= Self.limit else { throw ComputerError("The attachment is larger than 8 MB.") }
        name = url.lastPathComponent
        if let source = CGImageSourceCreateWithData(contents as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            guard width > 0, height > 0, width <= 16_384, height <= 16_384,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  png.count <= Self.limit else { throw ComputerError("The image is too large to attach safely.") }
            data = png; mimeType = "image/png"
        } else {
            guard let text = String(data: contents, encoding: .utf8), !text.contains("\0") else {
                throw ComputerError("Use a supported image or a UTF-8 text file.")
            }
            data = contents; mimeType = nil
        }
    }
    var textContext: String { "Attached file: \(name)\n\(String(data: data, encoding: .utf8) ?? "")" }
    func content(for provider: Provider) -> [String: Any] {
        guard let mimeType else { return ["type": "text", "text": textContext] }
        let base64 = data.base64EncodedString()
        switch provider {
        case .grok: return ["type": "image", "mimeType": mimeType, "data": base64]
        case .claude: return ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": base64]]
        case .codex: return ["type": "image", "url": "data:\(mimeType);base64,\(base64)"]
        }
    }
}
