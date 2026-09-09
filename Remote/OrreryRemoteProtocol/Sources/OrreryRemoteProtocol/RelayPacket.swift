import Foundation

/// Relay routing is outside the encrypted payload. A channel never shares a sealer or replay
/// counter with another viewer. The relay carries only the inner JSON envelope as UTF-8.
public struct RelayPacket: Codable, Equatable, Sendable {
    public var type: String
    public var id: String?
    public var data: String?
    public init(type: String, id: String? = nil, data: String? = nil) {
        self.type = type; self.id = id; self.data = data
    }
    public static let maxBytes = RemoteProtocol.maxFrameBytes * 2 + 4096
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= maxBytes, let packet = try? JSONDecoder().decode(Self.self, from: data),
              ["relay.ready", "relay.open", "relay.data", "relay.close"].contains(packet.type) else { return nil }
        if packet.type == "relay.ready" { return packet.id == nil && packet.data == nil ? packet : nil }
        guard let id = packet.id, id.utf8.count == 36, UUID(uuidString: id) != nil else { return nil }
        if packet.type == "relay.data" {
            guard let text = packet.data, !text.isEmpty, text.utf8.count <= RemoteProtocol.maxFrameBytes * 2 else { return nil }
        } else if packet.data != nil { return nil }
        return packet
    }
}
