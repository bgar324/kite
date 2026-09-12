import Foundation
import Darwin

@MainActor
final class SessionClient {
    var onWorkspace: ((Workspace) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?

    private struct Pending {
        let completion: ((ControlResponse) -> Void)?
        let timeout: DispatchWorkItem
    }
    private let socketPath: String
    private let daemonPath: String
    private var transport: ControlTransport?
    private var pending: [UInt32: Pending] = [:]
    private var nextID: UInt64 = 1
    private var generation: UInt64 = 0
    private var active = false
    private var connected = false
    private var durabilityError: String?

    init(socketPath: String, daemonPath: String) {
        self.socketPath = socketPath
        self.daemonPath = daemonPath
    }

    deinit { transport?.stop() }

    func connect() {
        guard !active else { return }
        active = true
        generation &+= 1
        let token = generation
        let connection = ControlTransport(socketPath: socketPath, daemonPath: daemonPath) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == token else { return }
                self.receive(event)
            }
        }
        transport = connection
        connection.start()
    }

    func disconnect() {
        active = false
        connected = false
        generation &+= 1
        transport?.stop()
        transport = nil
        failPending("Connection cancelled")
        onConnectionChange?(false, nil)
    }

    func send(_ request: ControlRequest, completion: ((ControlResponse) -> Void)? = nil) {
        var request = request
        if request.id == 0 {
            guard nextID <= UInt64(UInt32.max) else {
                completion?(ControlResponse(id: 0, ok: false, error: "Request identifiers exhausted; reopen Kite", workspace: nil))
                return
            }
            request.id = UInt32(nextID)
            nextID += 1
        } else {
            guard UInt64(request.id) >= nextID else {
                completion?(ControlResponse(id: request.id, ok: false, error: "Request identifier was already used", workspace: nil))
                return
            }
            nextID = UInt64(request.id) + 1
        }
        guard active, connected, let transport else {
            completion?(ControlResponse(id: request.id, ok: false, error: "Not connected to the session daemon", workspace: nil))
            return
        }
        guard pending.count < 256 else {
            completion?(ControlResponse(id: request.id, ok: false, error: "Too many outstanding daemon requests", workspace: nil))
            return
        }
        do {
            let payload = try JSONEncoder().encode(request)
            guard payload.count <= 65_536 else {
                completion?(ControlResponse(id: request.id, ok: false, error: "Request exceeds the 64 KiB frame limit", workspace: nil))
                return
            }
            let id = request.id
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let item = self.pending.removeValue(forKey: id) else { return }
                item.completion?(ControlResponse(id: id, ok: false, error: "Daemon response timed out; operation outcome is unknown", workspace: nil))
            }
            pending[id] = Pending(completion: completion, timeout: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            transport.send(Frame(kind: .request, stream: 0, payload: payload).encoded())
        } catch {
            completion?(ControlResponse(id: request.id, ok: false, error: error.localizedDescription, workspace: nil))
        }
    }

    private func receive(_ event: ControlTransport.Event) {
        switch event {
        case .connected:
            connected = true
            send(ControlRequest(id: 0, op: .watch)) { [weak self] response in
                guard let self, self.active, self.connected else { return }
                if response.ok {
                    self.onConnectionChange?(true, self.durabilityError)
                } else {
                    self.receive(.stopped(response.error ?? "Workspace subscription failed"))
                }
            }
        case .disconnected(let message):
            connected = false
            failPending("\(message); operation outcome may be unknown")
            onConnectionChange?(false, message)
        case .stopped(let message):
            connected = false
            active = false
            transport?.stop()
            transport = nil
            failPending(message)
            onConnectionChange?(false, message)
        case .workspace(let workspace):
            onWorkspace?(workspace)
            if let durabilityError { onConnectionChange?(connected, durabilityError) }
        case .response(let response):
            if let workspace = response.workspace { onWorkspace?(workspace) }
            if response.workspace != nil, let durabilityError { onConnectionChange?(connected, durabilityError) }
            if response.id == 0 {
                durabilityError = response.error
                onConnectionChange?(connected, response.error)
                return
            }
            if let item = pending.removeValue(forKey: response.id) {
                item.timeout.cancel()
                item.completion?(response)
            }
        }
    }

    private func failPending(_ message: String) {
        let cancelled = pending
        pending.removeAll()
        for (id, item) in cancelled {
            item.timeout.cancel()
            item.completion?(ControlResponse(id: id, ok: false, error: message, workspace: nil))
        }
    }
}

// Socket state is confined to this queue. UI state and callbacks stay on MainActor.
private final class ControlTransport {
    enum Event {
        case connected
        case disconnected(String)
        case stopped(String)
        case workspace(Workspace)
        case response(ControlResponse)
    }
    private let queue = DispatchQueue(label: "kite.control.socket")
    private let socketPath: String
    private let daemonPath: String
    private let event: (Event) -> Void
    private var running = false
    private var connecting = false
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var writerResumed = false
    private var deadline: DispatchWorkItem?
    private var reconnect: DispatchWorkItem?
    private var attempts = 0
    private var launched = false
    private var decoder = FrameDecoder()
    private var outgoing = Data()
    private var offset = 0

    init(socketPath: String, daemonPath: String, event: @escaping (Event) -> Void) {
        self.socketPath = socketPath
        self.daemonPath = daemonPath
        self.event = event
    }

    func start() { queue.async { self.running = true; self.openSocket() } }
    func stop() {
        queue.async {
            self.running = false
            self.reconnect?.cancel()
            self.reconnect = nil
            self.closeSocket()
        }
    }
    func send(_ bytes: Data) {
        queue.async {
            guard self.running, self.fd >= 0, !self.connecting else { return }
            guard bytes.count <= 262_144 - (self.outgoing.count - self.offset) else {
                self.failed("Control connection write queue is full")
                return
            }
            if self.offset != 0 {
                self.outgoing.removeSubrange(0..<self.offset)
                self.offset = 0
            }
            self.outgoing.append(bytes)
            self.enableWriter()
        }
    }

    private func openSocket() {
        guard running else { return }
        reconnect = nil
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8CString)
        guard !socketPath.utf8.contains(0), path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            running = false
            event(.stopped("Daemon socket path is invalid or too long"))
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { failed("Creating daemon socket: \(String(cString: strerror(errno)))"); return }
        fd = socketFD
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            failed("Configuring daemon socket: \(String(cString: strerror(errno)))")
            return
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let connectionError = errno
        if result < 0 && connectionError != EINPROGRESS && connectionError != EAGAIN {
            unavailable(connectionError)
            return
        }
        connecting = true
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        var cancellations = 2
        let close: () -> Void = {
            cancellations -= 1
            if cancellations == 0 { Darwin.close(socketFD) }
        }
        readSource.setCancelHandler(handler: close)
        writeSource.setCancelHandler(handler: close)
        readSource.setEventHandler { [weak self] in
            guard let self, self.fd == socketFD else { return }
            if self.connecting { self.finishConnect() }
            if !self.connecting, self.fd == socketFD { self.readAvailable() }
        }
        writeSource.setEventHandler { [weak self] in
            guard let self, self.fd == socketFD else { return }
            if self.connecting { self.finishConnect() }
            if !self.connecting, self.fd == socketFD { self.writeAvailable() }
        }
        reader = readSource
        writer = writeSource
        readSource.resume()
        enableWriter()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.fd == socketFD, self.connecting else { return }
            self.failed("Connecting to daemon timed out")
        }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
        if result == 0 { finishConnect() }
    }

    private func finishConnect() {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
            failed("Reading daemon connection status failed")
            return
        }
        guard error == 0 else { unavailable(error); return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            running = false
            closeSocket()
            event(.stopped("Daemon socket belongs to another user"))
            return
        }
        connecting = false
        deadline?.cancel()
        deadline = nil
        attempts = 0
        launched = false
        event(.connected)
    }

    private func unavailable(_ error: Int32) {
        var message = "Connecting to daemon: \(String(cString: strerror(error)))"
        if !launched && (error == ENOENT || error == ECONNREFUSED) {
            launched = true
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: daemonPath)
                process.arguments = ["serve", socketPath]
                let null = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
                defer { try? null.close() }
                process.standardInput = null
                process.standardOutput = null
                process.standardError = null
                try process.run()
            } catch {
                message = "Starting session daemon: \(error.localizedDescription)"
            }
        }
        failed(message)
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Yield to queued sends/disconnect after a bounded read batch.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                do {
                    for frame in try decoder.append(Data(bytes.prefix(count))) {
                        guard frame.stream == 0, frame.kind == .response || frame.kind == .workspace else {
                            failed("Unexpected daemon control frame")
                            return
                        }
                        if frame.kind == .workspace {
                            event(.workspace(try JSONDecoder().decode(Workspace.self, from: frame.payload)))
                        } else {
                            let response = try JSONDecoder().decode(ControlResponse.self, from: frame.payload)
                            // ID zero carries checkpoint failure or recovery, never a request reply.
                            let notification = response.workspace == nil && (response.ok ? response.error == nil : response.error?.isEmpty == false)
                            guard response.id != 0 || notification else {
                                failed("Invalid daemon response identifier or notification")
                                return
                            }
                            event(.response(response))
                        }
                    }
                } catch {
                    failed("Invalid daemon response: \(error.localizedDescription)")
                    return
                }
            } else if count == 0 {
                failed("Session daemon disconnected")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR {
                failed("Reading daemon socket: \(String(cString: strerror(errno)))")
                return
            }
        }
    }

    private func writeAvailable() {
        while offset < outgoing.count {
            let count = outgoing.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else if count < 0 && errno == EINTR { continue }
            else { failed("Writing daemon socket failed"); return }
        }
        outgoing.removeAll(keepingCapacity: true)
        offset = 0
        if writerResumed { writer?.suspend(); writerResumed = false }
    }

    private func enableWriter() {
        if !writerResumed, let writer { writerResumed = true; writer.resume() }
    }

    private func closeSocket() {
        deadline?.cancel()
        deadline = nil
        let oldFD = fd
        fd = -1
        connecting = false
        if let reader, let writer {
            reader.cancel()
            writer.cancel()
            if !writerResumed { writer.resume() }
        } else if oldFD >= 0 { Darwin.close(oldFD) }
        reader = nil
        writer = nil
        writerResumed = false
        decoder = FrameDecoder()
        outgoing.removeAll(keepingCapacity: false)
        offset = 0
    }

    private func failed(_ message: String) {
        closeSocket()
        event(.disconnected(message))
        guard running else { return }
        guard attempts < 8 else {
            running = false
            event(.stopped("\(message). Reconnect to try again."))
            return
        }
        let delay = min(5.0, 0.1 * pow(2.0, Double(attempts)))
        attempts += 1
        let work = DispatchWorkItem { [weak self] in self?.openSocket() }
        reconnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
