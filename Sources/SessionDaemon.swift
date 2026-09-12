import Foundation
import Dispatch
import Darwin

private let queueLimit = 256 * 1024
private let controlQueueLimit = 2 * 1024 * 1024
private let titleHintLimit = 256
private let lostProcessMessage = "Process lost when the session daemon stopped; exit status unknown"
private let snapshotLimit = 16 * 1024 * 1024

private struct ByteQueue {
    private var bytes = Data()
    private var offset = 0
    var count: Int { bytes.count - offset }
    mutating func append(_ data: Data, limit: Int = queueLimit) -> Bool {
        guard data.count <= limit - count else { return false }
        if offset > 0 { bytes.removeFirst(offset); offset = 0 }
        bytes.append(data)
        return true
    }
    mutating func flush(to fd: Int32) throws {
        while count > 0 {
            let sent = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), count)
            }
            if sent > 0 { offset += sent }
            else if sent < 0 && errno == EINTR { continue }
            else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { throw systemError("write") }
        }
        bytes.removeAll(keepingCapacity: true); offset = 0
    }
}

private func systemError(_ operation: String) -> WorkspaceError {
    .invalid("\(operation): \(String(cString: strerror(errno)))")
}

private final class Connection {
    let fd: Int32
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var decoder = FrameDecoder()
    var outgoing = ByteQueue()
    var live = ByteQueue()
    var snapshot: Data?
    var snapshotOffset = 0
    var pane: UInt32?
    var watching = false
    var closed = false
    var closeAfterFlush = false
    var awaitingReady = false
    var exitSent = false
    init(fd: Int32) { self.fd = fd }
}

private final class PaneProcess {
    let id: UInt32
    let terminal: OpaquePointer
    var fd: Int32
    var pid: Int32?
    var exitCode: Int32?
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var input = ByteQueue()
    weak var relay: Connection?
    var eof = false
    var canonicalFailed = false
    var retired = false
    var descendants: OpaquePointer?
    init(id: UInt32, terminal: OpaquePointer, fd: Int32 = -1, pid: Int32? = nil, exitCode: Int32? = nil) {
        self.id = id; self.terminal = terminal; self.fd = fd; self.pid = pid; self.exitCode = exitCode
        eof = fd < 0
    }
    deinit {
        kite_terminal_free(terminal)
        if let descendants { kite_process_tree_dispose(descendants) }
    }
}

private final class Daemon {
    let queue = DispatchQueue(label: "Kite.workspace")
    let endpoint: OpaquePointer
    let workspacePath: String
    var workspace: Workspace
    var listener: DispatchSourceRead?
    var signalSources: [DispatchSourceSignal] = []
    var clients: [Int32: Connection] = [:]
    var panes: [UInt32: PaneProcess] = [:]
    var retired: [PaneProcess] = []
    var metadataPending = false
    var metadataChanged = false
    var metadataDirty = Set<UInt32>()
    var persistenceError: String?
    var stopping = false
    var terminationCount = 0
    let encoder = JSONEncoder()

    init(socketPath: String) throws {
        guard let opened = kite_endpoint_open(socketPath) else { throw systemError("open private daemon socket") }
        endpoint = opened
        workspacePath = URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("workspace.json").path
        do {
            let fd = Darwin.open(workspacePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                var status = stat()
                guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_uid == getuid(), status.st_size <= Frame.maxControlPayload, status.st_size > 0 else {
                    throw WorkspaceError.invalid("Invalid workspace metadata file")
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let data = try handle.readToEnd() ?? Data()
                workspace = try JSONDecoder().decode(Workspace.self, from: data)
                for s in workspace.sessions.indices {
                    for p in workspace.sessions[s].panes.indices {
                        workspace.sessions[s].panes[p].title = Self.titleHint(workspace.sessions[s].panes[p].title)
                    }
                    if !workspace.sessions[s].customTitle {
                        workspace.sessions[s].title = Self.titleHint(workspace.sessions[s].title)
                    }
                }
                try Self.validateWorkspace(workspace)
            } else if errno == ENOENT { workspace = Workspace() }
            else { throw systemError("read workspace") }
            workspace.epoch = UUID().uuidString
            for s in workspace.sessions.indices {
                for p in workspace.sessions[s].panes.indices {
                    if workspace.sessions[s].panes[p].state != .exited || workspace.sessions[s].panes[p].exitCode == nil {
                        workspace.sessions[s].panes[p].exitCode = 255
                        workspace.sessions[s].panes[p].exitMessage = lostProcessMessage
                    }
                    workspace.sessions[s].panes[p].state = .exited
                    workspace.sessions[s].panes[p].pid = nil
                    workspace.sessions[s].panes[p].attached = false
                }
            }
        } catch { kite_endpoint_close(opened); throw error }
    }

    static func validateSettings(_ settings: Settings, checkExecutable: Bool = true) throws {
        guard settings.fontSize.isFinite, (7...72).contains(settings.fontSize),
              !settings.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.fontFamily.utf8.count <= 256,
              !settings.fontFamily.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["dark", "light", "system"].contains(settings.theme),
              settings.shell.hasPrefix("/"), !settings.shell.contains("\0"),
              settings.shell.utf8.count < Int(PATH_MAX) else {
            throw WorkspaceError.invalid("Invalid font, theme, or executable shell settings")
        }
        if checkExecutable {
            var status = stat()
            guard stat(settings.shell, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                  access(settings.shell, X_OK) == 0 else {
                throw WorkspaceError.invalid("Shell must be an executable file")
            }
        }
        let keys = Set(Settings().shortcuts.keys)
        guard Set(settings.shortcuts.keys) == keys else { throw WorkspaceError.invalid("Shortcut action keys must match the supported actions") }
        var used = Set<String>()
        let aliases = ["cmd": "cmd", "super": "cmd", "ctrl": "ctrl", "control": "ctrl",
                       "alt": "alt", "option": "alt", "shift": "shift"]
        let namedKeys = ["tab": "\t", "enter": "\r", "space": " ", "left_bracket": "[", "right_bracket": "]",
                         "left": "left", "right": "right", "up": "up", "down": "down"]
        let reserved = Set(["1", "2", "3", "4", "5", "6", "7", "8", "9", "q", ",", "c", "v", "a"])
        for value in settings.shortcuts.values {
            let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            let modifiers = parts.dropLast().compactMap { aliases[$0] }
            guard !value.isEmpty, value.utf8.count <= 80, parts.count >= 2,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  modifiers.count == parts.count - 1, Set(modifiers).count == modifiers.count,
                  modifiers.contains(where: { $0 != "shift" }),
                  let token = parts.last, token.count == 1 || namedKeys[token] != nil,
                  !token.contains(where: { $0.isWhitespace }) else {
                throw WorkspaceError.invalid("Shortcuts require a supported key and unique cmd, ctrl, alt, or shift modifiers")
            }
            let key = namedKeys[token] ?? token
            guard !(modifiers == ["cmd"] && reserved.contains(key)),
                  used.insert(modifiers.sorted().joined(separator: "+") + "+" + key).inserted else {
                throw WorkspaceError.invalid("Shortcut duplicates another action or a standard application shortcut")
            }
        }
    }

    static func titleHint(_ value: String) -> String {
        let suffix = " [truncated]"
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let size = scalar.utf8.count
            guard byteCount + size <= titleHintLimit else {
                while result.utf8.count + suffix.utf8.count > titleHintLimit { result.removeLast() }
                return result + suffix
            }
            result.unicodeScalars.append(scalar)
            byteCount += size
        }
        return result
    }

    static func validateWorkspace(_ value: Workspace) throws {
        // A removed shell must not prevent restoring the workspace and changing settings.
        try validateSettings(value.settings, checkExecutable: false)
        guard value.schema == 2, value.sessions.count <= 64,
              value.sessions.reduce(0, { $0 + $1.panes.count }) <= 64 else { throw WorkspaceError.invalid("Unsupported or oversized workspace") }
        var ids = Set<UInt32>()
        func claim(_ id: UInt32) throws {
            guard id > 0, id < value.nextID, ids.insert(id).inserted else { throw WorkspaceError.invalid("Invalid workspace identifiers") }
        }
        func checkLayout(_ layout: PaneLayout, depth: Int) throws {
            guard depth <= 64 else { throw WorkspaceError.invalid("Pane layout is too deep") }
            if case .split(let id, _, let ratio, let first, let second) = layout {
                try claim(id)
                guard ratio.isFinite, (0.05...0.95).contains(ratio) else { throw WorkspaceError.invalid("Invalid split ratio") }
                try checkLayout(first, depth: depth + 1); try checkLayout(second, depth: depth + 1)
            }
        }
        for session in value.sessions {
            try claim(session.id)
            guard !session.panes.isEmpty, session.title.utf8.count <= 1024,
                  !session.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  Set(session.layout.paneIDs) == Set(session.panes.map(\.id)),
                  session.layout.paneIDs.count == session.panes.count,
                  session.panes.contains(where: { $0.id == session.selectedPane }) else { throw WorkspaceError.invalid("Invalid session layout") }
            try checkLayout(session.layout, depth: 0)
            for pane in session.panes {
                try claim(pane.id)
                guard (1...1000).contains(pane.rows), (1...1000).contains(pane.cols),
                      pane.cwd.hasPrefix("/"), pane.cwd.utf8.count < Int(PATH_MAX), !pane.cwd.contains("\0"),
                      pane.title.utf8.count <= titleHintLimit,
                      (pane.exitMessage?.utf8.count ?? 0) <= 256 else { throw WorkspaceError.invalid("Invalid persisted pane") }
            }
        }
        guard value.nextID > 0, value.selectedSession.map({ value.session(id: $0) != nil }) ?? value.sessions.isEmpty else {
            throw WorkspaceError.invalid("Invalid selected session")
        }
        // Reserve room for the response envelope and a bounded failure message.
        guard try JSONEncoder().encode(value).count <= Frame.maxControlPayload - 8192 else {
            throw WorkspaceError.invalid("Workspace metadata exceeds the 1 MiB control capacity")
        }
    }

    func persist(_ value: Workspace) throws {
        let data = try encoder.encode(value)
        guard data.count <= Frame.maxControlPayload - 8192 else { throw WorkspaceError.invalid("Workspace metadata exceeds the 1 MiB control capacity") }
        let temporary = workspacePath + "." + UUID().uuidString
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw systemError("create workspace checkpoint") }
        defer { Darwin.close(fd); unlink(temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError("write workspace checkpoint") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw systemError("sync workspace checkpoint") }
        guard rename(temporary, workspacePath) == 0 else { throw systemError("replace workspace checkpoint") }
        let directory = Darwin.open(URL(fileURLWithPath: workspacePath).deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
    }

    func start() throws {
        try persist(workspace)
        let source = DispatchSource.makeReadSource(fileDescriptor: kite_endpoint_fd(endpoint), queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        listener = source
        signal(SIGPIPE, SIG_IGN)
        signal(SIGCHLD, { _ in })
        for number in [SIGCHLD, SIGTERM, SIGINT, SIGHUP] {
            if number != SIGCHLD { signal(number, SIG_IGN) }
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if number == SIGCHLD { self.reapChildren() } else { self.shutdown() }
            }
            signalSources.append(source); source.resume()
        }
        listener?.resume()
    }

    func acceptClients() {
        guard !stopping else { return }
        for _ in 0..<64 {
            let fd = kite_accept(kite_endpoint_fd(endpoint))
            if fd < 0 { if errno == EINTR { continue }; return }
            guard clients.count < 128 else { Darwin.close(fd); continue }
            let client = Connection(fd: fd); clients[fd] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak client] in if let client { self?.readClient(client) } }
            source.setCancelHandler { Darwin.close(fd) }
            client.reader = source; source.resume()
            queue.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
                guard let client, !client.closed, client.pane == nil, !client.watching else { return }
                // A list-only socket is allowed five seconds to finish, never an idle resident.
                self?.drop(client)
            }
        }
    }

    func drop(_ client: Connection) {
        guard !client.closed else { return }
        client.closed = true; clients.removeValue(forKey: client.fd)
        client.writer?.cancel(); client.writer = nil
        client.reader?.cancel(); client.reader = nil
        client.snapshot = nil
        if let id = client.pane, let process = panes[id], process.relay === client {
            process.relay = nil
            updatePane(id) { $0.attached = false }
            publishMetadataSoon()
        }
    }

    func armWriter(_ client: Connection) {
        guard client.writer == nil, !client.closed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in if let client { self?.flush(client) } }
        client.writer = source; source.resume()
    }

    func send(_ kind: FrameKind, stream: UInt32 = 0, payload: Data = Data(), to client: Connection) {
        guard !client.closed else { return }
        let frame = Frame(kind: kind, stream: stream, payload: payload).encoded()
        if client.snapshot != nil || client.live.count > 0 {
            guard client.live.append(frame, limit: queueLimit - 64 * 1024) else { drop(client); return }
        } else {
            let limit = client.pane == nil ? controlQueueLimit : queueLimit
            guard client.outgoing.append(frame, limit: limit - client.live.count) else { drop(client); return }
        }
        flush(client)
    }

    func flush(_ client: Connection) {
        guard !client.closed else { return }
        do {
            // A bounded write quantum lets busy PTYs and control peers keep making progress.
            for _ in 0..<8 {
                try client.outgoing.flush(to: client.fd)
                if client.outgoing.count > 0 { armWriter(client); return }
                if let snapshot = client.snapshot {
                    if client.snapshotOffset < snapshot.count {
                        let end = min(snapshot.count, client.snapshotOffset + 32 * 1024)
                        let chunk = Data(snapshot[client.snapshotOffset..<end]); client.snapshotOffset = end
                        _ = client.outgoing.append(Frame(kind: .output, stream: client.pane!, payload: chunk).encoded())
                        continue
                    }
                    client.snapshot = nil
                    _ = client.outgoing.append(Frame(kind: .replayEnd, stream: client.pane!, payload: Data()).encoded())
                    _ = client.outgoing.append(Frame(kind: .ready, stream: client.pane!, payload: Data()).encoded())
                    client.awaitingReady = true
                    continue
                }
                try client.live.flush(to: client.fd)
                if client.live.count > 0 { armWriter(client); return }
                client.writer?.cancel(); client.writer = nil
                if client.closeAfterFlush { drop(client) }
                return
            }
            armWriter(client)
        } catch { drop(client) }
    }

    func fail(_ client: Connection, _ message: String, stream: UInt32? = nil) {
        send(.error, stream: stream ?? client.pane ?? 0, payload: Data(message.utf8.prefix(4096)), to: client)
        client.closeAfterFlush = true; flush(client)
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak client] in if let client { self?.drop(client) } }
    }

    func readClient(_ client: Connection) {
        guard !client.closed, !client.closeAfterFlush else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            let count = Darwin.read(client.fd, &buffer, buffer.count)
            if count == 0 { drop(client); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { drop(client) }
                return
            }
            do {
                for frame in try client.decoder.append(Data(buffer.prefix(count))) {
                    guard !client.closed, !client.closeAfterFlush else { return }
                    do { try receive(frame, from: client) }
                    catch { fail(client, error.localizedDescription, stream: frame.stream); return }
                }
            } catch { fail(client, error.localizedDescription); return }
        }
    }

    func receive(_ frame: Frame, from client: Connection) throws {
        switch frame.kind {
        case .request:
            guard frame.stream == 0, client.pane == nil else { throw WorkspaceError.invalid("Control request on terminal connection") }
            let request = try JSONDecoder().decode(ControlRequest.self, from: frame.payload)
            control(request, client: client)
        case .attach:
            guard client.pane == nil, !client.watching, frame.stream != 0 else { throw WorkspaceError.invalid("Connection is already in use") }
            try attach(frame, client: client)
        case .input:
            guard let process = panes[frame.stream], process.relay === client, !client.awaitingReady,
                  client.snapshot == nil, process.pid != nil, !process.eof else { throw WorkspaceError.invalid("Pane is not accepting input") }
            try enqueueInput(frame.payload, process: process)
        case .resize:
            guard let process = panes[frame.stream], process.relay === client else { throw WorkspaceError.invalid("Resize requires pane ownership") }
            try resize(process, payload: frame.payload)
        case .ready:
            guard frame.payload.isEmpty, client.pane == frame.stream, client.awaitingReady,
                  client.snapshot == nil, panes[frame.stream]?.relay === client else { throw WorkspaceError.invalid("Unexpected ready acknowledgement") }
            client.awaitingReady = false
            updatePane(frame.stream) { $0.attached = true }
            publishNow()
            if let process = panes[frame.stream], process.eof, let code = process.exitCode {
                sendExit(process, code: code)
            }
        default: throw WorkspaceError.invalid("Unexpected client frame")
        }
    }

    func dimensions(_ data: Data) throws -> (UInt16, UInt16, UInt16, UInt16) {
        guard data.count == 8 else { throw WorkspaceError.invalid("Resize requires eight bytes") }
        let bytes = Array(data)
        let values = stride(from: 0, to: 8, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        guard (1...1000).contains(values[0]), (1...1000).contains(values[1]) else { throw WorkspaceError.invalid("Terminal dimensions outside 1...1000") }
        return (values[0], values[1], values[2], values[3])
    }

    func resize(_ process: PaneProcess, payload: Data) throws {
        let (rows, cols, width, height) = try dimensions(payload)
        guard !process.canonicalFailed else { throw WorkspaceError.invalid("Terminal state failed; restart pane") }
        if process.fd >= 0, kite_pty_resize(process.fd, rows, cols, width, height) < 0 { throw systemError("resize PTY") }
        guard kite_terminal_resize(process.terminal, cols, rows) else {
            canonicalFailure(process); throw WorkspaceError.invalid("Canonical terminal resize failed")
        }
        updatePane(process.id) { $0.rows = rows; $0.cols = cols }
        publishMetadataSoon()
    }

    func attach(_ frame: Frame, client: Connection) throws {
        _ = try dimensions(frame.payload)
        guard let pane = workspace.pane(id: frame.stream) else { throw WorkspaceError.invalid("Unknown pane") }
        let process: PaneProcess
        if let existing = panes[pane.id] { process = existing }
        else {
            guard let terminal = kite_terminal_new(pane.cols, pane.rows, 2 * 1024 * 1024) else { throw WorkspaceError.invalid("Cannot allocate terminal state") }
            process = PaneProcess(id: pane.id, terminal: terminal, exitCode: pane.exitCode ?? 255)
            if pane.exitCode == nil {
                updatePane(pane.id) { $0.exitCode = 255; $0.exitMessage = lostProcessMessage }
            }
            panes[pane.id] = process
        }
        guard process.relay == nil else { throw WorkspaceError.invalid("Another renderer is already attached to this pane") }
        try resize(process, payload: frame.payload)
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard kite_terminal_snapshot(process.terminal, &bytes, &length), length <= snapshotLimit else {
            if let bytes { kite_terminal_bytes_free(bytes, length) }
            throw WorkspaceError.invalid("Cannot reconstruct terminal snapshot")
        }
        let snapshot = bytes.map { Data(bytes: $0, count: length) } ?? Data()
        if let bytes { kite_terminal_bytes_free(bytes, length) }
        client.pane = pane.id; process.relay = client
        client.awaitingReady = true
        _ = client.outgoing.append(Frame(kind: .replayStart, stream: pane.id, payload: Data()).encoded())
        client.snapshot = snapshot; client.snapshotOffset = 0
        flush(client)
        if process.eof, let code = process.exitCode { sendExit(process, code: code) }
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak client] in
            guard let client, client.awaitingReady else { return }
            self?.fail(client, "Terminal snapshot acknowledgement timed out")
        }
    }

    func enqueueInput(_ data: Data, process: PaneProcess) throws {
        guard process.fd >= 0, !process.eof, process.input.append(data) else { throw WorkspaceError.invalid("Pane input queue exceeded 256 KiB") }
        try process.input.flush(to: process.fd)
        if process.input.count > 0, process.writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: process.fd, queue: queue)
            source.setEventHandler { [weak self, weak process] in
                guard let self, let process, process.fd >= 0 else { return }
                do {
                    try process.input.flush(to: process.fd)
                    if process.input.count == 0 { process.writer?.cancel(); process.writer = nil }
                } catch { self.closePTY(process) }
            }
            process.writer = source; source.resume()
        }
    }

    func startReading(_ process: PaneProcess) {
        let fd = process.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak process] in if let process { self?.readPTY(process) } }
        source.setCancelHandler { Darwin.close(fd) }
        process.reader = source; source.resume()
    }

    func readPTY(_ process: PaneProcess) {
        guard process.fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            let count = Darwin.read(process.fd, &buffer, buffer.count)
            if count == 0 || (count < 0 && errno == EIO) { closePTY(process); reapChildren(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { closePTY(process) }
                return
            }
            guard !process.canonicalFailed else { continue }
            let fed = buffer.withUnsafeBufferPointer { kite_terminal_feed(process.terminal, $0.baseAddress, count) }
            guard fed else { canonicalFailure(process); return }
            var reply: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard kite_terminal_take_reply(process.terminal, &reply, &length) else { canonicalFailure(process); return }
            if let reply {
                let data = Data(bytes: reply, count: length); kite_terminal_bytes_free(reply, length)
                if process.relay == nil && !data.isEmpty && data.count <= queueLimit - process.input.count {
                    do { try enqueueInput(data, process: process) } catch { closePTY(process); reapChildren(); return }
                }
            }
            if let relay = process.relay { send(.output, stream: process.id, payload: Data(buffer.prefix(count)), to: relay) }
            metadataDirty.insert(process.id)
            publishMetadataSoon(changed: false)
        }
    }

    func closePTY(_ process: PaneProcess) {
        guard process.fd >= 0 else { return }
        process.writer?.cancel(); process.writer = nil
        if let reader = process.reader { reader.cancel(); process.reader = nil }
        else { Darwin.close(process.fd) }
        process.fd = -1; process.eof = true
        if let code = process.exitCode { sendExit(process, code: code) }
    }

    func sendExit(_ process: PaneProcess, code: Int32) {
        guard let relay = process.relay, !relay.awaitingReady, relay.snapshot == nil, !relay.exitSent else { return }
        relay.exitSent = true
        var payload = Data(); payload.appendUInt32BE(UInt32(bitPattern: code))
        send(.exit, stream: process.id, payload: payload, to: relay)
    }

    func canonicalFailure(_ process: PaneProcess) {
        process.canonicalFailed = true
        if let relay = process.relay { fail(relay, "Canonical terminal state failed; restart this pane") }
        terminate(process)
        updatePane(process.id) { $0.state = .exited; $0.pid = nil; $0.attached = false; $0.exitCode = 1 }
        publishNow()
    }

    func refreshMetadata(_ process: PaneProcess) {
        guard !process.retired else { return }
        var title = kite_terminal_title(process.terminal).map { String(cString: $0) } ?? ""
        title = Self.titleHint(title)
        var cwd = kite_terminal_cwd(process.terminal).map { String(cString: $0) } ?? ""
        if let pid = process.pid {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if kite_pty_cwd(pid, &buffer, buffer.count) == 0 { cwd = String(cString: buffer) }
        }
        guard let before = workspace.pane(id: process.id) else { return }
        let cleanCwd = cwd.hasPrefix("/") && cwd.utf8.count < Int(PATH_MAX) && !cwd.contains("\0") ? cwd : before.cwd
        let cleanTitle = title.isEmpty ? before.title : title
        guard before.cwd != cleanCwd || before.title != cleanTitle else { return }
        var draft = workspace
        for s in draft.sessions.indices {
            if let p = draft.sessions[s].panes.firstIndex(where: { $0.id == process.id }) {
                draft.sessions[s].panes[p].cwd = cleanCwd
                draft.sessions[s].panes[p].title = cleanTitle
                if draft.sessions[s].selectedPane == process.id && !draft.sessions[s].customTitle {
                    draft.sessions[s].title = cleanTitle
                }
                break
            }
        }
        do {
            try Self.validateWorkspace(draft)
            workspace = draft
            publishMetadataSoon()
        } catch {
            notify("Pane \(process.id) metadata update was rejected: \(error.localizedDescription)")
        }
    }

    func updatePane(_ id: UInt32, _ body: (inout Pane) -> Void) {
        for s in workspace.sessions.indices {
            if let p = workspace.sessions[s].panes.firstIndex(where: { $0.id == id }) { body(&workspace.sessions[s].panes[p]); return }
        }
    }

    func publishMetadataSoon(changed: Bool = true) {
        metadataChanged = metadataChanged || changed
        guard !metadataPending, !stopping else { return }
        metadataPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, self.metadataPending, !self.stopping else { return }
            let dirty = self.metadataDirty
            self.metadataDirty.removeAll(keepingCapacity: true)
            for id in dirty { if let process = self.panes[id] { self.refreshMetadata(process) } }
            self.metadataPending = false
            if self.metadataChanged { self.publishNow() }
        }
    }

    func publishNow(persistMetadata: Bool = true) {
        metadataChanged = false
        if persistMetadata {
            do { try persist(workspace); clearPersistenceError() }
            catch { persistenceError = "Workspace changes are not saved: \(error.localizedDescription)" }
        }
        do {
            let data = try encoder.encode(workspace)
            guard data.count <= Frame.maxControlPayload - 8192 else {
                throw WorkspaceError.invalid("Workspace metadata exceeds the 1 MiB control capacity")
            }
            for client in Array(clients.values) where client.watching { send(.workspace, payload: data, to: client) }
        } catch {
            notify("Cannot publish workspace: \(error.localizedDescription)")
        }
        if let persistenceError { notify(persistenceError) }
    }

    func notify(_ message: String) {
        for client in Array(clients.values) where client.watching {
            sendResponse(ControlResponse(id: 0, ok: false, error: message, workspace: nil), to: client)
        }
    }

    func clearPersistenceError() {
        guard persistenceError != nil else { return }
        persistenceError = nil
        for client in Array(clients.values) where client.watching {
            sendResponse(ControlResponse(id: 0, ok: true, error: nil, workspace: nil), to: client)
        }
    }

    func sendResponse(_ response: ControlResponse, to client: Connection) {
        do {
            var response = response
            if let error = response.error {
                response.error = String(String.UnicodeScalarView(error.unicodeScalars.prefix(1024)))
            }
            let data = try encoder.encode(response)
            guard data.count <= Frame.maxControlPayload else { throw WorkspaceError.invalid("Response exceeds control frame limit") }
            send(.response, payload: data, to: client)
        } catch { fail(client, error.localizedDescription) }
    }

    func validCwd(_ requested: String?, fallback: String) throws -> String {
        let path = requested ?? fallback
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX) else { throw WorkspaceError.invalid("Working directory must be an absolute path") }
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR, access(path, X_OK) == 0 else {
            throw WorkspaceError.invalid("Working directory does not exist or is not accessible")
        }
        return path
    }

    func spawn(id: UInt32, cwd: String, settings: Settings, rows: UInt16 = 24, cols: UInt16 = 80) throws -> PaneProcess {
        try Self.validateSettings(settings)
        guard let terminal = kite_terminal_new(cols, rows, 2 * 1024 * 1024) else { throw WorkspaceError.invalid("Cannot allocate canonical terminal") }
        var pid: Int32 = 0
        let fd = kite_pty_spawn(settings.shell, cwd, true, rows, cols, &pid)
        guard fd >= 0 else { kite_terminal_free(terminal); throw systemError("launch shell") }
        return PaneProcess(id: id, terminal: terminal, fd: fd, pid: pid)
    }

    func control(_ request: ControlRequest, client: Connection) {
        guard request.id != 0 else { fail(client, "Control request identifier zero is reserved for notifications"); return }
        guard !stopping else { sendResponse(ControlResponse(id: request.id, ok: false, error: "Daemon is shutting down", workspace: workspace), to: client); return }
        if request.op == .watch || request.op == .list {
            if request.op == .watch { client.watching = true }
            sendResponse(ControlResponse(id: request.id, ok: true, error: nil, workspace: workspace), to: client)
            if request.op == .watch {
                sendResponse(ControlResponse(id: 0, ok: persistenceError == nil, error: persistenceError, workspace: nil), to: client)
            }
            return
        }
        var draft = workspace
        var created: PaneProcess?
        var removed: [UInt32] = []
        do {
            func sessionIndex() throws -> Int {
                guard let id = request.session, let index = draft.sessions.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.invalid("Unknown session") }
                return index
            }
            func paneLocation() throws -> (Int, Int) {
                guard let id = request.pane else { throw WorkspaceError.invalid("Pane identifier required") }
                for s in draft.sessions.indices {
                    if let p = draft.sessions[s].panes.firstIndex(where: { $0.id == id }) {
                        guard request.session == nil || request.session == draft.sessions[s].id else { throw WorkspaceError.invalid("Pane does not belong to session") }
                        return (s, p)
                    }
                }
                throw WorkspaceError.invalid("Unknown pane")
            }
            func inheritedCwd() -> String {
                if let selected = draft.selectedSession, let session = draft.session(id: selected), let pane = draft.pane(id: session.selectedPane) { return pane.cwd }
                return FileManager.default.homeDirectoryForCurrentUser.path
            }
            func removePane(_ s: Int, _ p: Int) {
                let id = draft.sessions[s].panes[p].id
                if let layout = draft.sessions[s].layout.removing(pane: id) {
                    draft.sessions[s].layout = layout
                    draft.sessions[s].panes.remove(at: p)
                    if draft.sessions[s].selectedPane == id { draft.sessions[s].selectedPane = layout.paneIDs[0] }
                } else { draft.sessions.remove(at: s) }
                if draft.selectedSession.flatMap({ draft.session(id: $0) }) == nil {
                    draft.selectedSession = draft.sessions.isEmpty ? nil : draft.sessions[min(s, draft.sessions.count - 1)].id
                }
            }
            switch request.op {
            case .createSession:
                guard draft.sessions.count < 64, draft.sessions.reduce(0, { $0 + $1.panes.count }) < 64 else { throw WorkspaceError.invalid("Workspace limit of 64 panes reached") }
                let cwd = try validCwd(request.cwd, fallback: inheritedCwd())
                let sessionID = try draft.allocateID(), paneID = try draft.allocateID()
                let process = try spawn(id: paneID, cwd: cwd, settings: draft.settings); created = process
                let title = Self.titleHint(URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? "Terminal" : URL(fileURLWithPath: cwd).lastPathComponent)
                let pane = Pane(id: paneID, title: title, cwd: cwd, pid: process.pid)
                draft.sessions.append(Session(id: sessionID, title: title, layout: .pane(paneID), selectedPane: paneID, panes: [pane]))
                draft.selectedSession = sessionID
            case .closeSession:
                let s = try sessionIndex(); removed = draft.sessions[s].panes.map(\.id)
                draft.sessions.remove(at: s)
                if draft.selectedSession == request.session { draft.selectedSession = draft.sessions.isEmpty ? nil : draft.sessions[min(s, draft.sessions.count - 1)].id }
            case .renameSession:
                let s = try sessionIndex()
                guard let value = request.title else { throw WorkspaceError.invalid("Session title required") }
                let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.utf8.count <= 1024, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw WorkspaceError.invalid("Session title must contain 1...1024 bytes without control characters") }
                draft.sessions[s].title = title; draft.sessions[s].customTitle = true
            case .reorderSession:
                let s = try sessionIndex()
                guard let index = request.index, draft.sessions.indices.contains(index) else { throw WorkspaceError.invalid("Session order index is out of bounds") }
                let session = draft.sessions.remove(at: s); draft.sessions.insert(session, at: index)
            case .selectSession:
                let s = try sessionIndex(); draft.selectedSession = draft.sessions[s].id
            case .createPane:
                let (s, p) = try paneLocation()
                guard draft.sessions.reduce(0, { $0 + $1.panes.count }) < 64 else { throw WorkspaceError.invalid("Workspace limit of 64 panes reached") }
                guard let axis = request.axis else { throw WorkspaceError.invalid("Split axis required") }
                let target = draft.sessions[s].panes[p]
                let cwd = try validCwd(request.cwd, fallback: target.cwd)
                let paneID = try draft.allocateID(), splitID = try draft.allocateID()
                let process = try spawn(id: paneID, cwd: cwd, settings: draft.settings, rows: target.rows, cols: target.cols); created = process
                let pane = Pane(id: paneID, title: target.title, cwd: cwd, rows: target.rows, cols: target.cols, pid: process.pid)
                draft.sessions[s].layout = draft.sessions[s].layout.replacing(pane: target.id, with: .split(id: splitID, axis: axis, ratio: 0.5, first: .pane(target.id), second: .pane(paneID)))
                draft.sessions[s].panes.append(pane); draft.sessions[s].selectedPane = paneID; draft.selectedSession = draft.sessions[s].id
            case .closePane:
                let (s, p) = try paneLocation(); removed = [draft.sessions[s].panes[p].id]; removePane(s, p)
            case .selectPane:
                let (s, p) = try paneLocation(); draft.sessions[s].selectedPane = draft.sessions[s].panes[p].id; draft.selectedSession = draft.sessions[s].id
            case .movePane:
                let (s, p) = try paneLocation()
                guard draft.sessions[s].panes.count > 1 else { throw WorkspaceError.invalid("Pane already occupies its own session") }
                guard draft.sessions.count < 64 else { throw WorkspaceError.invalid("Session limit reached") }
                let pane = draft.sessions[s].panes[p], id = try draft.allocateID()
                removePane(s, p)
                draft.sessions.append(Session(id: id, title: pane.title, layout: .pane(pane.id), selectedPane: pane.id, panes: [pane])); draft.selectedSession = id
            case .resizeSplit:
                let s = try sessionIndex()
                guard let id = request.split, draft.sessions[s].layout.splitIDs.contains(id), let ratio = request.ratio,
                      ratio.isFinite, (0.05...0.95).contains(ratio) else { throw WorkspaceError.invalid("Unknown split or ratio outside 0.05...0.95") }
                draft.sessions[s].layout = draft.sessions[s].layout.updatingRatio(split: id, ratio: ratio)
            case .restartPane:
                let (s, p) = try paneLocation(); let pane = draft.sessions[s].panes[p]
                let cwd = try validCwd(request.cwd, fallback: pane.cwd)
                let process = try spawn(id: pane.id, cwd: cwd, settings: draft.settings, rows: pane.rows, cols: pane.cols); created = process
                removed = [pane.id]
                draft.sessions[s].panes[p].cwd = cwd; draft.sessions[s].panes[p].state = .running
                draft.sessions[s].panes[p].pid = process.pid; draft.sessions[s].panes[p].exitCode = nil; draft.sessions[s].panes[p].attached = false
                draft.sessions[s].panes[p].exitMessage = nil
            case .setSettings:
                guard let settings = request.settings else { throw WorkspaceError.invalid("Settings required") }
                try Self.validateSettings(settings); draft.settings = settings
            case .shutdown:
                for s in draft.sessions.indices { for p in draft.sessions[s].panes.indices {
                    draft.sessions[s].panes[p].state = .exited; draft.sessions[s].panes[p].pid = nil; draft.sessions[s].panes[p].attached = false
                } }
            case .watch, .list: break
            }
            for s in draft.sessions.indices where !draft.sessions[s].customTitle {
                if let selected = draft.sessions[s].panes.first(where: { $0.id == draft.sessions[s].selectedPane }) {
                    draft.sessions[s].title = selected.title
                }
            }
            try Self.validateWorkspace(draft)
            try persist(draft)
            clearPersistenceError()
            workspace = draft
            for id in removed {
                if let process = panes.removeValue(forKey: id) {
                    if let relay = process.relay { fail(relay, "Pane closed or restarted") }
                    terminate(process)
                }
            }
            if let process = created { panes[process.id] = process; startReading(process); reapChildren() }
            sendResponse(ControlResponse(id: request.id, ok: true, error: nil, workspace: workspace), to: client)
            publishNow(persistMetadata: false)
            if request.op == .shutdown { shutdown() }
        } catch {
            if let created { terminate(created) }
            sendResponse(ControlResponse(id: request.id, ok: false, error: error.localizedDescription, workspace: workspace), to: client)
        }
    }

    func terminate(_ process: PaneProcess) {
        guard !process.retired else { return }
        process.retired = true
        if let relay = process.relay { drop(relay) }
        let pid = process.pid
        let tree: OpaquePointer?
        if let pid {
            tree = kite_terminate_begin(pid)
        } else {
            tree = process.descendants
            process.descendants = nil
            if let tree { kite_process_tree_signal(tree) }
        }
        if tree == nil, let pid { _ = kill(pid, SIGHUP); _ = kill(pid, SIGTERM) }
        guard tree != nil || pid != nil else { closePTY(process); return }
        terminationCount += 1
        queue.asyncAfter(deadline: .now() + 1) { [weak self, process] in
            guard let self else { return }
            if let tree { kite_terminate_finish(tree) }
            else if let pid, process.pid == pid { _ = kill(pid, SIGKILL) }
            self.closePTY(process); self.terminationCount -= 1; self.reapChildren(); self.finishShutdownIfReady()
        }
        retired.append(process)
    }

    func reapChildren() {
        for process in Array(panes.values) + retired {
            guard let pid = process.pid else { continue }
            guard kite_child_exited(pid) == 1 else { continue }
            if !process.retired, process.descendants == nil {
                process.descendants = kite_process_tree_capture(pid)
            }
            var code: Int32 = 0
            let result = kite_reap(pid, &code)
            guard result == 1 else { continue }
            process.pid = nil; process.exitCode = code
            if !process.retired {
                updatePane(process.id) { $0.state = .exited; $0.pid = nil; $0.exitCode = code; $0.exitMessage = nil }
                publishNow()
                if process.fd >= 0 { readPTY(process) }
                if process.eof { sendExit(process, code: code) }
            }
        }
        retired.removeAll { $0.pid == nil && $0.fd < 0 }
        finishShutdownIfReady()
    }

    func shutdown() {
        guard !stopping else { return }
        stopping = true; listener?.cancel(); listener = nil
        for process in Array(panes.values) { terminate(process) }
        for s in workspace.sessions.indices { for p in workspace.sessions[s].panes.indices {
            workspace.sessions[s].panes[p].state = .exited; workspace.sessions[s].panes[p].pid = nil; workspace.sessions[s].panes[p].attached = false
        } }
        publishNow()
        // One finite shutdown grace period, not a periodic idle timer.
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishShutdown(force: true) }
        finishShutdownIfReady()
    }

    func finishShutdownIfReady() {
        if stopping, terminationCount == 0, retired.allSatisfy({ $0.pid == nil }) {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.finishShutdown(force: false) }
        }
    }

    func finishShutdown(force: Bool) {
        guard stopping, force || (terminationCount == 0 && retired.allSatisfy({ $0.pid == nil })) else { return }
        for client in Array(clients.values) { drop(client) }
        kite_endpoint_close(endpoint)
        Darwin.exit(0)
    }
}

@main
struct SessionDaemon {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "serve" else {
            fputs("usage: kite-session serve SOCKET\n", stderr); Darwin.exit(64)
        }
        // Process-spawned daemons must never share the GUI's process group.
        if setsid() < 0 && errno != EPERM { fputs("kite-session: setsid failed\n", stderr); Darwin.exit(1) }
        do {
            let daemon = try Daemon(socketPath: CommandLine.arguments[2])
            try daemon.start()
            withExtendedLifetime(daemon) { dispatchMain() }
        } catch {
            fputs("kite-session: \(error.localizedDescription)\n", stderr); Darwin.exit(1)
        }
    }
}
