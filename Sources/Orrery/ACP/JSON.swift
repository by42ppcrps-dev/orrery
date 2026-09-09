import Foundation

/// Lightweight dynamic JSON accessor.
///
/// The ACP surface Grok exposes is large and still moving (`x.ai/*` methods come and go between
/// releases), so the client reads fields defensively instead of pinning a Codable schema to a
/// protocol version. Everything is optional; nothing throws.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init?(line: String) {
        guard let data = line.data(using: .utf8) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        self.raw = obj
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return JSON(nil) }
        return JSON(array[index])
    }

    var string: String? { raw as? String }
    var int: Int? { (raw as? NSNumber)?.intValue }
    var double: Double? { (raw as? NSNumber)?.doubleValue }
    var bool: Bool? { (raw as? NSNumber)?.boolValue }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var object: [String: JSON] {
        (raw as? [String: Any])?.mapValues(JSON.init) ?? [:]
    }
    var exists: Bool { raw != nil && !(raw is NSNull) }

    /// Compact single-line rendering, for tool arguments and unexpected payloads.
    var compact: String {
        guard let raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: raw)
    }

    var pretty: String {
        guard let raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: raw,
                                                 options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: raw)
    }
}
