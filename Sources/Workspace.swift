import Foundation

struct Workspace: Codable, Equatable {
    var schema: Int = 2
    var epoch: String = UUID().uuidString
    var nextID: UInt32 = 1
    var sessions: [Session] = []
    var selectedSession: UInt32?
    var settings = Settings()

    func pane(id: UInt32) -> Pane? {
        sessions.lazy.flatMap(\.panes).first { $0.id == id }
    }
    func session(id: UInt32) -> Session? { sessions.first { $0.id == id } }
    func sessionContaining(pane id: UInt32) -> Session? {
        sessions.first { $0.panes.contains { $0.id == id } }
    }
    mutating func allocateID() throws -> UInt32 {
        guard nextID != 0, nextID < UInt32.max else { throw WorkspaceError.invalid("Workspace identifier space exhausted") }
        defer { nextID += 1 }
        return nextID
    }
}

struct Session: Codable, Equatable {
    var id: UInt32
    var title: String
    var customTitle: Bool = false
    var layout: PaneLayout
    var selectedPane: UInt32
    var panes: [Pane]
}

struct Pane: Codable, Equatable {
    var id: UInt32
    var title: String
    var cwd: String
    var attached: Bool = false
    var rows: UInt16 = 24
    var cols: UInt16 = 80
    var state: PaneState = .running
    var pid: Int32?
    var exitCode: Int32?
    var exitMessage: String?
}

enum PaneState: String, Codable { case running, exited, closing }
enum SplitAxis: String, Codable { case vertical, horizontal }

indirect enum PaneLayout: Codable, Equatable {
    case pane(UInt32)
    case split(id: UInt32, axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    private enum CodingKeys: String, CodingKey { case pane, id, axis, ratio, first, second }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.pane) {
            guard values.allKeys.count == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .pane, in: values, debugDescription: "A leaf cannot also contain split fields")
            }
            self = .pane(try values.decode(UInt32.self, forKey: .pane))
        } else {
            self = .split(id: try values.decode(UInt32.self, forKey: .id),
                          axis: try values.decode(SplitAxis.self, forKey: .axis),
                          ratio: try values.decode(Double.self, forKey: .ratio),
                          first: try values.decode(PaneLayout.self, forKey: .first),
                          second: try values.decode(PaneLayout.self, forKey: .second))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id): try values.encode(id, forKey: .pane)
        case .split(let id, let axis, let ratio, let first, let second):
            try values.encode(id, forKey: .id)
            try values.encode(axis, forKey: .axis)
            try values.encode(ratio, forKey: .ratio)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }
    var paneIDs: [UInt32] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }
    var splitIDs: [UInt32] {
        switch self {
        case .pane: return []
        case .split(let id, _, _, let first, let second): return [id] + first.splitIDs + second.splitIDs
        }
    }
    func replacing(pane id: UInt32, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let current): return current == id ? replacement : self
        case .split(let splitID, let axis, let ratio, let first, let second):
            return .split(id: splitID, axis: axis, ratio: ratio,
                          first: first.replacing(pane: id, with: replacement),
                          second: second.replacing(pane: id, with: replacement))
        }
    }
    func removing(pane id: UInt32) -> PaneLayout? {
        switch self {
        case .pane(let current): return current == id ? nil : self
        case .split(let splitID, let axis, let ratio, let first, let second):
            let left = first.removing(pane: id)
            let right = second.removing(pane: id)
            guard let left else { return right }
            guard let right else { return left }
            return .split(id: splitID, axis: axis, ratio: ratio, first: left, second: right)
        }
    }
    func updatingRatio(split id: UInt32, ratio newRatio: Double) -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let splitID, let axis, let ratio, let first, let second):
            return .split(id: splitID, axis: axis, ratio: splitID == id ? newRatio : ratio,
                          first: first.updatingRatio(split: id, ratio: newRatio),
                          second: second.updatingRatio(split: id, ratio: newRatio))
        }
    }
}

struct Settings: Codable, Equatable {
    var fontFamily: String = "JetBrains Mono"
    var fontSize: Double = 14
    var shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    var theme: String = "system"
    var shortcuts: [String: String] = [
        "newSession": "cmd+t", "closeSession": "cmd+w",
        "splitVertical": "cmd+d", "splitHorizontal": "cmd+shift+d",
        "nextSession": "cmd+shift+]", "previousSession": "cmd+shift+[",
        "nextPane": "cmd+alt+right", "closePane": "cmd+shift+w"
    ]
}

enum ControlOp: String, Codable {
    case watch, list, createSession, closeSession, renameSession, reorderSession, selectSession
    case createPane, closePane, selectPane, movePane, resizeSplit, restartPane, setSettings, shutdown
}

struct ControlRequest: Codable {
    var id: UInt32 = 0
    var op: ControlOp
    var session: UInt32?
    var pane: UInt32?
    var title: String?
    var cwd: String?
    var axis: SplitAxis?
    var index: Int?
    var split: UInt32?
    var ratio: Double?
    var settings: Settings?
}

struct ControlResponse: Codable {
    var id: UInt32
    var ok: Bool
    var error: String?
    var workspace: Workspace?
}

enum WorkspaceError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
