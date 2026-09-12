import Foundation

@main
struct ModelWireCheck {
    static func main() throws {
        let payload = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        let first = Frame(kind: .output, stream: 41, payload: payload)
        let second = Frame(kind: .ready, stream: 41, payload: Data())
        let stream = first.encoded() + second.encoded()
        for split in 0...stream.count {
            var decoder = FrameDecoder()
            let a = try decoder.append(Data(stream.prefix(split)))
            let b = try decoder.append(Data(stream.dropFirst(split)))
            let decoded = a + b
            precondition(decoded.count == 2 && decoded[0].payload == payload)
            precondition(decoded[0].stream == 41 && decoded[1].kind == .ready)
            precondition(decoder.bufferedByteCount == 0)
        }
        var oversized = first.encoded()
        oversized.replaceSubrange(8..<12, with: [0, 1, 0, 1])
        do {
            var decoder = FrameDecoder()
            _ = try decoder.append(oversized)
            preconditionFailure("Oversized network frame accepted")
        } catch is WireError {}
        let largeState = Data(repeating: 120, count: 100_000)
        let controlFrame = Frame(kind: .workspace, stream: 0, payload: largeState).encoded()
        var controlDecoder = FrameDecoder()
        var controlFrames: [Frame] = []
        for offset in stride(from: 0, to: controlFrame.count, by: 4096) {
            controlFrames += try controlDecoder.append(controlFrame[offset..<min(offset + 4096, controlFrame.count)])
        }
        precondition(controlFrames.count == 1 && controlFrames[0].payload == largeState)
        let nested = PaneLayout.split(id: 10, axis: .vertical, ratio: 0.4, first: .pane(1),
            second: .split(id: 11, axis: .horizontal, ratio: 0.6, first: .pane(2), second: .pane(3)))
        let moved = nested.removing(pane: 2)!
        precondition(moved == .split(id: 10, axis: .vertical, ratio: 0.4, first: .pane(1), second: .pane(3)))
        precondition(moved.paneIDs == [1, 3])
        let roundTrip = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(nested))
        precondition(roundTrip == nested)
        print("Frame fragmentation, size rejection, and split-collapse invariants passed")
    }
}
