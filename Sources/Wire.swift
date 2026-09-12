import Foundation

enum FrameKind: UInt8 {
    case request = 1, response, workspace, attach, input, resize, output, exit, ready, error, replayStart, replayEnd
}

struct Frame {
    static let headerSize = 16
    static let maxPayload = 65_536
    static let maxControlPayload = 1_048_576
    static func maximumPayload(for kind: FrameKind) -> Int {
        kind == .response || kind == .workspace ? maxControlPayload : maxPayload
    }
    let kind: FrameKind
    let stream: UInt32
    let payload: Data

    func encoded() -> Data {
        precondition(payload.count <= Self.maximumPayload(for: kind))
        var result = Data(capacity: Self.headerSize + payload.count)
        result.append(contentsOf: [0x4b, 0x49, 0x54, 0x45, 2, kind.rawValue, 0, 0])
        result.appendUInt32BE(UInt32(payload.count))
        result.appendUInt32BE(stream)
        result.append(payload)
        return result
    }
}

struct FrameDecoder {
    private var pending = Data()
    private var target = Frame.headerSize

    var bufferedByteCount: Int { pending.count }

    mutating func append(_ data: Data) throws -> [Frame] {
        var frames: [Frame] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let count = min(target - pending.count, data.endIndex - offset)
            pending.append(data[offset..<(offset + count)])
            offset += count
            guard pending.count == target else { continue }
            if target == Frame.headerSize {
                guard pending.prefix(4).elementsEqual([0x4b, 0x49, 0x54, 0x45]),
                      pending[4] == 2, pending[6] == 0, pending[7] == 0,
                      let kind = FrameKind(rawValue: pending[5]) else {
                    throw WireError.invalid("Invalid Kite frame or protocol version")
                }
                let length = Int(pending.uint32BE(at: 8))
                guard length <= Frame.maximumPayload(for: kind) else { throw WireError.invalid("Kite frame exceeds its payload limit") }
                target += length
                if length != 0 { continue }
            }
            // The header was validated before any payload allocation.
            frames.append(Frame(kind: FrameKind(rawValue: pending[5])!, stream: pending.uint32BE(at: 12),
                                payload: Data(pending.dropFirst(Frame.headerSize))))
            pending.removeAll(keepingCapacity: true)
            target = Frame.headerSize
        }
        return frames
    }
}

enum WireError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    func uint32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
