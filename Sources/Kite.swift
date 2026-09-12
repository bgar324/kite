import AppKit
import Darwin

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@MainActor
final class KiteApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var ghostty: ghostty_app_t?
    private var config: ghostty_config_t?
    private var ghosttyArguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    private var window: NSWindow!
    private let table = NSTableView()
    private let terminalHost = NSView()
    private let status = NSTextField(wrappingLabelWithString: "Connecting to session daemon…")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Waiting for workspace…")
    private var workspace: Workspace?
    private var connected = false
    private var bootstrapped = false
    private var creatingFirstSession = false
    private var applyingWorkspace = false
    private var renderedLayout: PaneLayout?
    private var renderedSession: UInt32?
    private var cards: [UInt32: PaneCard] = [:]
    private var monitors: [Any] = []
    private var preferencePanel: PreferencesPanel?
    private var appliedSettings: Settings?
    private var appliedDarkAppearance: Bool?
    private var menuShortcuts: [String: NSMenuItem] = [:]
    private let dragType = NSPasteboard.PasteboardType("app.kite.session-id")
    private let socketPath = ProcessInfo.processInfo.environment["KITE_SOCKET"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Kite/session-v2.sock").path
    private let relayPath = ProcessInfo.processInfo.environment["KITE_RELAY"]
        ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("kite-relay").path
    private let daemonPath = ProcessInfo.processInfo.environment["KITE_DAEMON"]
        ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("kite-session").path
    private lazy var client = SessionClient(socketPath: socketPath, daemonPath: daemonPath)

    private var selectedSession: Session? {
        guard let workspace else { return nil }
        return workspace.sessions.first { $0.id == workspace.selectedSession }
    }
    private var selectedCard: PaneCard? { selectedSession.flatMap { cards[$0.selectedPane] } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()
        guard initializeGhostty() else { return }
        client.onConnectionChange = { [weak self] online, error in
            guard let self else { return }
            self.connected = online
            self.status.stringValue = error ?? (online ? "Workspace connected" : "Reconnecting to session daemon…")
            if !online {
                for card in self.cards.values { card.detach(message: "Waiting for daemon connection…") }
            }
        }
        client.onWorkspace = { [weak self] in self?.receive($0) }
        monitors = [NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  self.window.firstResponder is TerminalView || self.window.firstResponder === self.table else { return event }
            return self.handleShortcut(event) ? nil : event
        }, NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.modifierFlags.contains(.command), let view = self?.window.firstResponder as? TerminalView {
                view.keyUp(with: event)
                return nil
            }
            return event
        }].compactMap { $0 }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        client.connect()
    }

    private func initializeGhostty() -> Bool {
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        argv.initialize(to: strdup("Kite"))
        argv.advanced(by: 1).initialize(to: nil)
        ghosttyArguments = argv
        guard ghostty_init(1, argv) == GHOSTTY_SUCCESS else {
            showError("Ghostty could not initialize. Check the bundled terminal resources.")
            return false
        }
        do { config = try makeConfig(Settings()) }
        catch { showError(error.localizedDescription); return false }
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { pointer in
            guard let pointer else { return }
            let owner = Unmanaged<KiteApp>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in
                if let app = owner?.ghostty { ghostty_app_tick(app) }
            }
        }
        runtime.action_cb = { app, target, action in
            guard let app, let pointer = ghostty_app_userdata(app) else { return false }
            return Unmanaged<KiteApp>.fromOpaque(pointer).takeUnretainedValue().handleAction(target, action)
        }
        runtime.read_clipboard_cb = { pointer, location, state in
            guard let view = TerminalView.from(pointer), let surface = view.surface else { return false }
            let value = location == GHOSTTY_CLIPBOARD_STANDARD ? NSPasteboard.general.string(forType: .string) ?? "" : ""
            value.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
        runtime.confirm_read_clipboard_cb = { pointer, string, state, request in
            guard let view = TerminalView.from(pointer), let surface = view.surface else { return }
            let value = string.map { String(cString: $0) } ?? ""
            let alert = NSAlert()
            alert.messageText = request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
                ? "Allow this terminal program to read your clipboard?"
                : "Paste text containing terminal control characters?"
            alert.informativeText = "Only allow this if you trust the program running in this pane."
            alert.addButton(withTitle: "Deny")
            alert.addButton(withTitle: "Allow")
            let approved = alert.runModal() == .alertSecondButtonReturn
            guard view.surface == surface else { return }
            (approved ? value : "").withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        }
        runtime.write_clipboard_cb = { _, location, contents, count, confirm in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents else { return }
            var value: String?
            for item in UnsafeBufferPointer(start: contents, count: Int(count)) {
                if let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data {
                    value = String(cString: data)
                    break
                }
            }
            guard let value else { return }
            if confirm {
                let alert = NSAlert()
                alert.messageText = "Allow this terminal program to replace your clipboard?"
                alert.addButton(withTitle: "Deny")
                alert.addButton(withTitle: "Allow")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        runtime.close_surface_cb = { pointer, _ in
            guard let view = TerminalView.from(pointer), let surface = view.surface else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view, view.surface == surface else { return }
                view.owner?.relayClosed(view)
            }
        }
        guard let app = ghostty_app_new(&runtime, config) else {
            showError("Ghostty could not start its Metal renderer.")
            return false
        }
        ghostty = app
        ghostty_app_set_focus(app, NSApp.isActive)
        return true
    }

    private func makeConfig(_ settings: Settings) throws -> ghostty_config_t {
        guard let result = ghostty_config_new() else { throw uiError("Ghostty could not create its configuration.") }
        let dark = settings.theme == "dark" || (settings.theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let text = """
        font-family = \(settings.fontFamily)
        font-size = \(settings.fontSize)
        shell-integration = none
        clipboard-read = ask
        clipboard-write = ask
        keybind = clear
        background = \(dark ? "17191c" : "ffffff")
        foreground = \(dark ? "e5e7eb" : "202124")
        window-padding-x = 8
        window-padding-y = 6
        """
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kite-config-\(UUID().uuidString)")
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: path) }
            path.path.withCString { ghostty_config_load_file(result, $0) }
            ghostty_config_finalize(result)
            guard ghostty_config_diagnostics_count(result) == 0 else {
                throw uiError("Ghostty rejected the terminal settings. Check the font and size.")
            }
            return result
        } catch { ghostty_config_free(result); throw error }
    }

    private func applySettings(_ settings: Settings) {
        let dark = settings.theme == "dark" || (settings.theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        guard settings != appliedSettings || appliedDarkAppearance != dark else { return }
        do {
            let replacement = try makeConfig(settings)
            if let ghostty { ghostty_app_update_config(ghostty, replacement) }
            for card in cards.values {
                if let surface = card.terminal.surface { ghostty_surface_update_config(surface, replacement) }
            }
            if let config { ghostty_config_free(config) }
            config = replacement
            appliedSettings = settings
            appliedDarkAppearance = dark
            window.appearance = settings.theme == "system" ? nil : NSAppearance(named: settings.theme == "dark" ? .darkAqua : .aqua)
            for (action, item) in menuShortcuts {
                if let shortcut = settings.shortcuts[action].flatMap(Shortcut.init) {
                    item.keyEquivalent = shortcut.key
                    item.keyEquivalentModifierMask = shortcut.modifiers
                } else { item.keyEquivalent = "" }
            }
        } catch { showError(error.localizedDescription) }
    }

    func appearanceChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let settings = self.workspace?.settings, settings.theme == "system" else { return }
            self.applySettings(settings)
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Kite"
        window.minSize = NSSize(width: 700, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("KiteWorkspace")
        let content = NSView()
        window.contentView = content
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        let heading = NSTextField(labelWithString: "Sessions")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let add = NSButton(title: "+", target: self, action: #selector(newSession(_:)))
        add.setAccessibilityLabel("New session")
        let close = NSButton(title: "−", target: self, action: #selector(closeSession(_:)))
        close.setAccessibilityLabel("Close session and terminate shells")
        let headingRow = NSStackView(views: [heading, NSView(), add, close])
        headingRow.orientation = .horizontal
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil
        table.rowHeight = 62
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.target = self
        table.doubleAction = #selector(renameSession(_:))
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Sessions")
        let context = NSMenu()
        context.delegate = self
        for (title, action) in [("Rename…", #selector(renameSession(_:))), ("New session here", #selector(duplicateSession(_:))),
                                ("Restart selected pane…", #selector(restartPane(_:))), ("Close session…", #selector(closeSession(_:)))] {
            let item = context.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        table.menu = context
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let reconnect = NSButton(title: "Reconnect", target: self, action: #selector(reconnect(_:)))
        let preferences = NSButton(title: "Settings…", target: self, action: #selector(showPreferences(_:)))
        let footer = NSStackView(views: [status, reconnect, preferences])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        for view in [sidebar, terminalHost] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        for view in [headingRow, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 238),
            terminalHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: content.topAnchor), terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            headingRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), headingRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            headingRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headingRow.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -14)
        ])
        emptyLabel.frame = NSRect(x: 30, y: 30, width: 500, height: 80)
        terminalHost.addSubview(emptyLabel)
        window.center()
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            menu.addItem(item)
            return child
        }
        func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ setting: String? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            if let setting { menuShortcuts[setting] = item }
        }
        let app = submenu("Kite")
        command(app, "Settings…", #selector(showPreferences(_:)), ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Kite and Detach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let session = submenu("Session")
        command(session, "New Session", #selector(newSession(_:)), "t", "newSession")
        command(session, "Close Session…", #selector(closeSession(_:)), "w", "closeSession")
        command(session, "Rename Session…", #selector(renameSession(_:)))
        command(session, "New Session Here", #selector(duplicateSession(_:)))
        session.addItem(.separator())
        command(session, "Previous Session", #selector(previousSession(_:)), "", "previousSession")
        command(session, "Next Session", #selector(nextSession(_:)), "", "nextSession")
        for index in 1...9 {
            let item = session.addItem(withTitle: "Select Session \(index)", action: #selector(selectNumberedSession(_:)), keyEquivalent: String(index))
            item.target = self
            item.tag = index - 1
        }
        session.addItem(.separator())
        command(session, "Reconnect Attachments", #selector(reconnect(_:)))
        let pane = submenu("Pane")
        command(pane, "Split Left and Right", #selector(splitVertical(_:)), "d", "splitVertical")
        command(pane, "Split Top and Bottom", #selector(splitHorizontal(_:)), "", "splitHorizontal")
        command(pane, "Next Pane", #selector(nextPane(_:)), "", "nextPane")
        command(pane, "Move Pane to New Session", #selector(movePane(_:)))
        command(pane, "Restart Pane…", #selector(restartPane(_:)))
        command(pane, "Close Pane…", #selector(closePane(_:)), "", "closePane")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }

    private func receive(_ value: Workspace) {
        if let epoch = workspace?.epoch, epoch != value.epoch {
            for card in cards.values { card.detach(message: "Daemon restarted. Reattaching…") }
        }
        workspace = value
        connected = true
        applySettings(value.settings)
        applyingWorkspace = true
        table.reloadData()
        if let index = value.sessions.firstIndex(where: { $0.id == value.selectedSession }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        applyingWorkspace = false
        let liveIDs = Set(value.sessions.flatMap { $0.panes.map(\.id) })
        for id in Array(cards.keys) where !liveIDs.contains(id) {
            cards.removeValue(forKey: id)?.dispose()
        }
        for session in value.sessions {
            for pane in session.panes {
                let card: PaneCard
                if let existing = cards[pane.id] { card = existing }
                else {
                    card = PaneCard(paneID: pane.id, owner: self)
                    cards[pane.id] = card
                }
                card.update(pane)
            }
        }
        renderSelectedSession()
        status.stringValue = "Workspace connected · \(value.sessions.count) session\(value.sessions.count == 1 ? "" : "s")"
        if !bootstrapped {
            bootstrapped = true
            if value.sessions.isEmpty && !creatingFirstSession {
                creatingFirstSession = true
                send(ControlRequest(id: 0, op: .createSession)) { [weak self] _ in self?.creatingFirstSession = false }
            }
        }
    }

    private func renderSelectedSession() {
        guard let session = selectedSession else {
            cards.values.forEach { $0.terminal.attachmentVisible = false }
            terminalHost.subviews.forEach { $0.removeFromSuperview() }
            emptyLabel.stringValue = "No sessions. Choose New Session to start a shell."
            terminalHost.addSubview(emptyLabel)
            renderedLayout = nil
            renderedSession = nil
            window.title = "Kite"
            return
        }
        let changed = session.layout != renderedLayout || renderedSession != session.id
        if changed {
            cards.values.forEach { $0.terminal.attachmentVisible = false; $0.removeFromSuperview() }
            terminalHost.subviews.forEach { $0.removeFromSuperview() }
            let root = layoutView(session.layout, sessionID: session.id)
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = terminalHost.bounds
            root.autoresizingMask = [.width, .height]
            terminalHost.addSubview(root)
            renderedLayout = session.layout
            renderedSession = session.id
            terminalHost.layoutSubtreeIfNeeded()
        }
        window.title = "Kite · \(session.title)"
        for id in session.layout.paneIDs {
            guard let card = cards[id] else { continue }
            card.terminal.attachmentVisible = true
            card.setSelected(id == session.selectedPane)
        }
        // Metal needs a mounted, sized NSView. The next main-loop turn follows AppKit layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.selectedSession, current.id == session.id else { return }
            self.window.contentView?.layoutSubtreeIfNeeded()
            for id in current.layout.paneIDs { self.attachPane(id) }
            if self.window.isKeyWindow && (changed || self.window.firstResponder is TerminalView || self.window.firstResponder === self.table) {
                self.applyingWorkspace = true
                self.window.makeFirstResponder(self.cards[current.selectedPane]?.terminal)
                self.applyingWorkspace = false
            }
            self.syncWindowState()
        }
    }

    private func layoutView(_ layout: PaneLayout, sessionID: UInt32) -> NSView {
        switch layout {
        case .pane(let id): return cards[id]!
        case .split(let id, let axis, let ratio, let first, let second):
            let split = PaneSplitView(ratio: ratio, vertical: axis == .vertical)
            for child in [layoutView(first, sessionID: sessionID), layoutView(second, sessionID: sessionID)] {
                child.translatesAutoresizingMaskIntoConstraints = true
                child.autoresizingMask = []
                split.addSubview(child)
            }
            split.onDividerChange = { [weak self] ratio in
                self?.send(ControlRequest(id: 0, op: .resizeSplit, session: sessionID, split: id, ratio: ratio))
            }
            return split
        }
    }

    func attachPane(_ id: UInt32) {
        guard connected, let ghostty, let card = cards[id], card.terminal.attachmentVisible,
              card.terminal.surface == nil, !card.attachmentStarting, card.canAttach,
              card.terminal.window != nil, card.terminal.bounds.width > 1, card.terminal.bounds.height > 1 else { return }
        guard FileManager.default.isExecutableFile(atPath: relayPath) else {
            card.showFailure("Relay executable missing: \(relayPath)", retry: false)
            return
        }
        card.beginAttachment()
        let command = "\(shellQuote(relayPath)) attach \(shellQuote(socketPath)) \(id)"
        guard card.terminal.connect(app: ghostty, command: command) else {
            card.showFailure("Ghostty could not create this terminal. Retry after checking the renderer.", retry: false)
            return
        }
        card.terminal.syncGeometry()
    }

    func relayClosed(_ view: TerminalView) {
        guard let card = cards[view.paneID], card.terminal === view, view.surface != nil else { return }
        if card.pane?.state == .exited { card.showExited(); return }
        card.showFailure("Terminal attachment closed. The daemon still owns the shell.", retry: true)
    }

    func paneFocused(_ id: UInt32) {
        guard !applyingWorkspace, let session = workspace?.sessions.first(where: { $0.panes.contains(where: { $0.id == id }) }),
              session.selectedPane != id || workspace?.selectedSession != session.id else { return }
        send(ControlRequest(id: 0, op: .selectPane, session: session.id, pane: id))
    }

    func paneAction(_ operation: ControlOp, pane id: UInt32) {
        guard let session = workspace?.sessions.first(where: { $0.panes.contains(where: { $0.id == id }) }) else { return }
        if operation == .closePane || operation == .restartPane {
            let title = operation == .closePane ? "Close this pane?" : "Restart this pane?"
            guard confirm(title, "The shell and programs in this pane will be terminated.", operation == .closePane ? "Close Pane" : "Restart") else { return }
        }
        if operation == .restartPane { cards[id]?.detach(message: "Restarting shell…") }
        send(ControlRequest(id: 0, op: operation, session: session.id, pane: id))
    }

    private func send(_ request: ControlRequest, completion: ((ControlResponse) -> Void)? = nil) {
        client.send(request) { [weak self] response in
            if !response.ok { self?.showError(response.error ?? "The daemon rejected this operation.") }
            completion?(response)
        }
    }

    private func actionSession(_ sender: Any?) -> Session? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UInt32 { return workspace?.session(id: id) }
        return selectedSession
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        let id = workspace?.sessions.indices.contains(table.clickedRow) == true ? workspace?.sessions[table.clickedRow].id : workspace?.selectedSession
        for item in menu.items { item.representedObject = id }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reconnect(_:)) { return ghostty != nil }
        if menuItem.action == #selector(showPreferences(_:)) { return workspace != nil }
        if menuItem.action == #selector(newSession(_:)) { return connected }
        return connected && actionSession(menuItem) != nil
    }
    @objc private func newSession(_ sender: Any?) { send(ControlRequest(id: 0, op: .createSession)) }
    @objc private func closeSession(_ sender: Any?) {
        guard let session = actionSession(sender) else { return }
        guard confirm("Close \(session.title)?", "All shells and programs in its \(session.panes.count) pane(s) will be terminated. Closing the window or quitting Kite instead leaves them running.", "Close Session") else { return }
        send(ControlRequest(id: 0, op: .closeSession, session: session.id))
    }
    @objc private func renameSession(_ sender: Any?) {
        guard let session = actionSession(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename session"
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256 else { showError("Use a session name between 1 and 256 bytes."); return }
        send(ControlRequest(id: 0, op: .renameSession, session: session.id, title: title))
    }
    @objc private func duplicateSession(_ sender: Any?) {
        guard let session = actionSession(sender) else { return }
        let cwd = session.panes.first(where: { $0.id == session.selectedPane })?.cwd
        send(ControlRequest(id: 0, op: .createSession, cwd: cwd))
    }
    @objc private func splitVertical(_ sender: Any?) { split(.vertical) }
    @objc private func splitHorizontal(_ sender: Any?) { split(.horizontal) }
    private func split(_ axis: SplitAxis) {
        guard let session = selectedSession else { return }
        send(ControlRequest(id: 0, op: .createPane, session: session.id, pane: session.selectedPane, axis: axis))
    }
    @objc private func closePane(_ sender: Any?) { if let id = selectedSession?.selectedPane { paneAction(.closePane, pane: id) } }
    @objc private func restartPane(_ sender: Any?) { if let id = actionSession(sender)?.selectedPane { paneAction(.restartPane, pane: id) } }
    @objc private func movePane(_ sender: Any?) { if let id = selectedSession?.selectedPane { paneAction(.movePane, pane: id) } }
    @objc private func nextPane(_ sender: Any?) {
        guard let session = selectedSession, let index = session.layout.paneIDs.firstIndex(of: session.selectedPane) else { return }
        let ids = session.layout.paneIDs
        send(ControlRequest(id: 0, op: .selectPane, session: session.id, pane: ids[(index + 1) % ids.count]))
    }
    @objc private func previousSession(_ sender: Any?) { cycleSession(-1) }
    @objc private func nextSession(_ sender: Any?) { cycleSession(1) }
    private func cycleSession(_ delta: Int) {
        guard let workspace, !workspace.sessions.isEmpty,
              let index = workspace.sessions.firstIndex(where: { $0.id == workspace.selectedSession }) else { return }
        let next = (index + delta + workspace.sessions.count) % workspace.sessions.count
        send(ControlRequest(id: 0, op: .selectSession, session: workspace.sessions[next].id))
    }
    @objc private func selectNumberedSession(_ sender: NSMenuItem) { selectSessionAt(sender.tag) }
    private func selectSessionAt(_ index: Int) {
        guard let sessions = workspace?.sessions, sessions.indices.contains(index) else { return }
        send(ControlRequest(id: 0, op: .selectSession, session: sessions[index].id))
    }
    @objc private func reconnect(_ sender: Any?) {
        for card in cards.values { card.detach(message: "Reconnecting attachment…"); card.resetRetry() }
        if connected { renderSelectedSession() } else { client.connect() }
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, let key = event.charactersIgnoringModifiers, let index = Int(key), (1...9).contains(index) {
            selectSessionAt(index - 1)
            return true
        }
        guard let settings = workspace?.settings else { return false }
        for (action, value) in settings.shortcuts {
            guard let shortcut = Shortcut(value), shortcut.matches(event) else { continue }
            switch action {
            case "newSession": newSession(nil)
            case "closeSession": closeSession(nil)
            case "splitVertical": splitVertical(nil)
            case "splitHorizontal": splitHorizontal(nil)
            case "previousSession": previousSession(nil)
            case "nextSession": nextSession(nil)
            case "nextPane": nextPane(nil)
            case "closePane": closePane(nil)
            default: return false
            }
            return true
        }
        return false
    }

    @objc private func showPreferences(_ sender: Any?) {
        guard let settings = workspace?.settings else { showError("Connect to the daemon before changing settings."); return }
        if let preferencePanel { preferencePanel.makeKeyAndOrderFront(nil); return }
        let panel = PreferencesPanel(settings: settings)
        panel.onSave = { [weak self, weak panel] settings in
            guard let self else { return }
            do {
                let checked = try self.makeConfig(settings)
                ghostty_config_free(checked)
            } catch { panel?.showError(error.localizedDescription); return }
            self.client.send(ControlRequest(id: 0, op: .setSettings, settings: settings)) { response in
                if response.ok { panel?.close(); self.preferencePanel = nil }
                else { panel?.showError(response.error ?? "Could not save settings.") }
            }
        }
        panel.onClose = { [weak self] in self?.preferencePanel = nil }
        preferencePanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { workspace?.sessions.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session = workspace?.sessions[row] else { return nil }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: session.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let pane = session.panes.first { $0.id == session.selectedPane }
        let detail = NSTextField(labelWithString: pane?.cwd ?? "")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        let running = session.panes.filter { $0.state == .running }.count
        let process = NSTextField(labelWithString: running > 0
            ? "\(running) running · \(pane?.title ?? "shell")\(pane?.pid.map { " · PID \($0)" } ?? "")"
            : "Exited\(pane?.exitCode.map { " · status \($0)" } ?? "")")
        process.font = .systemFont(ofSize: 10)
        process.textColor = running > 0 ? .secondaryLabelColor : .systemOrange
        process.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail, process])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor), title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor), process.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingWorkspace else { return }
        selectSessionAt(table.selectedRow)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let session = workspace?.sessions[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(session.id), forType: dragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: dragType), let id = UInt32(raw),
              let oldIndex = workspace?.sessions.firstIndex(where: { $0.id == id }) else { return false }
        let destination = max(0, row > oldIndex ? row - 1 : row)
        send(ControlRequest(id: 0, op: .reorderSession, session: id, index: destination))
        return true
    }

    private func confirm(_ title: String, _ detail: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func showError(_ message: String) {
        status.stringValue = message
        let alert = NSAlert()
        alert.messageText = "Kite could not complete the operation"
        alert.informativeText = message
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
    }
    @objc private func keyboardChanged() { if let ghostty { ghostty_app_keyboard_changed(ghostty) } }
    private func syncWindowState() { cards.values.forEach { $0.terminal.syncWindowState() } }
    func applicationDidBecomeActive(_ notification: Notification) { if let ghostty { ghostty_app_set_focus(ghostty, true) }; syncWindowState() }
    func applicationDidResignActive(_ notification: Notification) { if let ghostty { ghostty_app_set_focus(ghostty, false) }; syncWindowState() }
    func windowDidBecomeKey(_ notification: Notification) { syncWindowState() }
    func windowDidResignKey(_ notification: Notification) { syncWindowState() }
    func windowDidChangeOcclusionState(_ notification: Notification) { syncWindowState() }
    func windowDidChangeScreen(_ notification: Notification) { cards.values.forEach { $0.terminal.syncGeometry() } }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        client.disconnect()
        monitors.forEach { NSEvent.removeMonitor($0) }
        NotificationCenter.default.removeObserver(self)
        cards.values.forEach { $0.dispose() }
        cards.removeAll()
        if let ghostty { ghostty_app_free(ghostty) }
        ghostty = nil
        if let config { ghostty_config_free(config) }
        config = nil
        if let argv = ghosttyArguments { free(argv[0]); argv.deinitialize(count: 2); argv.deallocate() }
        ghosttyArguments = nil
    }

    private func handleAction(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view: TerminalView?
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface { view = TerminalView.from(ghostty_surface_userdata(surface)) }
        else { view = selectedCard?.terminal }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD: return true // Daemon metadata is authoritative.
        case GHOSTTY_ACTION_RENDER:
            if let surface = view?.surface { ghostty_surface_draw(surface) }
            return true
        case GHOSTTY_ACTION_RING_BELL: NSSound.beep(); return true
        case GHOSTTY_ACTION_MOUSE_SHAPE: view?.setCursor(action.action.mouse_shape); return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            if let view, let surface = view.surface {
                DispatchQueue.main.async { [weak self, weak view] in
                    if let view, view.surface == surface { self?.relayClosed(view) }
                }
            }
            return true
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY, let view {
                DispatchQueue.main.async { [weak self] in self?.cards[view.paneID]?.showFailure("Metal renderer failed. Retry this attachment.", retry: false) }
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let value = action.action.open_url
            guard let bytes = value.url, value.len <= 16384,
                  let url = URL(string: String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(value.len)), as: UTF8.self)),
                  let scheme = url.scheme?.lowercased() else { return false }
            DispatchQueue.main.async { [weak self] in
                if ["https", "http", "mailto"].contains(scheme) || self?.confirm("Open this link?", url.absoluteString, "Open") == true {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW:
            DispatchQueue.main.async { NSApp.terminate(nil) }; return true
        default: return false
        }
    }
}

private func uiError(_ message: String) -> NSError { NSError(domain: "Kite", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

private final class PaneSplitView: NSSplitView {
    var onDividerChange: ((Double) -> Void)?
    private var ratio: Double
    init(ratio: Double, vertical: Bool) {
        self.ratio = min(0.9, max(0.1, ratio))
        super.init(frame: .zero)
        isVertical = vertical
        dividerStyle = .thin
    }
    required init?(coder: NSCoder) { return nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        let length = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        let first = length * ratio
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
            subviews[1].frame = NSRect(x: first + dividerThickness, y: 0, width: length - first, height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
            subviews[1].frame = NSRect(x: 0, y: first + dividerThickness, width: bounds.width, height: length - first)
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard subviews.count == 2 else { return }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard total > 0 else { return }
        let value = (isVertical ? subviews[0].frame.width : subviews[0].frame.height) / total
        ratio = min(0.9, max(0.1, value))
        resizeSubviews(withOldSize: bounds.size)
        onDividerChange?(ratio)
    }
}

private final class PaneCard: NSView {
    let terminal = TerminalView(frame: .zero)
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "Not attached")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private weak var owner: KiteApp?
    private(set) var pane: Pane?
    private(set) var attachmentStarting = false
    private(set) var canAttach = true
    private var timeout: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var generation = UUID()
    private var ready = false

    init(paneID: UInt32, owner: KiteApp) {
        self.owner = owner
        super.init(frame: .zero)
        terminal.paneID = paneID
        terminal.owner = owner
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        state.font = .systemFont(ofSize: 10)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        retry.target = self
        retry.action = #selector(retryAttachment(_:))
        retry.isHidden = true
        retry.controlSize = .small
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        actions.addItem(withTitle: "Pane")
        for (label, action) in [("Move to New Session", #selector(move(_:))), ("Restart Shell…", #selector(restart(_:))), ("Close Pane…", #selector(close(_:)))] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            actions.menu?.addItem(item)
        }
        actions.controlSize = .small
        let header = NSStackView(views: [title, state, retry, actions])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(terminal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 3), header.heightAnchor.constraint(equalToConstant: 25),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3), terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { return nil }
    func update(_ value: Pane) {
        if let old = pane, old.pid != value.pid, value.state == .running {
            detach(message: "Attaching to restarted shell…")
            retryCount = 0
        }
        pane = value
        title.stringValue = value.title.isEmpty ? value.cwd : value.title
        title.toolTip = "\(value.cwd)\(value.pid.map { " · PID \($0)" } ?? "")"
        terminal.setAccessibilityLabel("Terminal pane \(value.id): \(value.title)")
        if value.attached, terminal.surface != nil {
            let becameReady = !ready
            attachmentStarting = false
            ready = true
            retryCount = 0
            timeout?.cancel()
            timeout = nil
            state.stringValue = "Attached"
            state.textColor = .secondaryLabelColor
            retry.isHidden = true
            if becameReady, let surface = terminal.surface { ghostty_surface_refresh(surface) }
        } else if ready, value.state == .running {
            showFailure("Daemon detached this terminal. Reconnecting…", retry: true)
        }
        if value.state == .exited, ready { showExited() }
    }
    func setSelected(_ selected: Bool) { title.textColor = selected ? .controlAccentColor : .labelColor }
    func resetRetry() { retryCount = 0 }
    func beginAttachment() {
        generation = UUID()
        let current = generation
        attachmentStarting = true
        ready = false
        state.stringValue = "Restoring terminal…"
        state.textColor = .secondaryLabelColor
        retry.isHidden = true
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current, !self.ready else { return }
            self.showFailure("Attachment timed out before the daemon reported ready.", retry: true)
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
    }
    func showExited() {
        attachmentStarting = false
        timeout?.cancel()
        state.stringValue = pane?.exitMessage ?? "Exited\(pane?.exitCode.map { " · status \($0)" } ?? "")"
        state.toolTip = pane?.exitMessage
        state.textColor = .secondaryLabelColor
    }
    func showFailure(_ message: String, retry shouldRetry: Bool) {
        detach(message: message)
        state.textColor = .systemRed
        state.toolTip = message
        retry.isHidden = false
        canAttach = false
        guard shouldRetry, retryCount < 3 else { return }
        retryCount += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.canAttach = true
            self.owner?.attachPane(self.terminal.paneID)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(1 << retryCount), execute: work)
    }
    func detach(message: String) {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        retryWork?.cancel()
        retryWork = nil
        canAttach = true
        terminal.disconnect()
        attachmentStarting = false
        ready = false
        state.stringValue = message
        state.toolTip = message
    }
    func dispose() { detach(message: "Detached"); removeFromSuperview() }
    @objc private func retryAttachment(_ sender: Any?) { detach(message: "Reconnecting…"); retryCount = 0; owner?.attachPane(terminal.paneID) }
    @objc private func move(_ sender: Any?) { owner?.paneAction(.movePane, pane: terminal.paneID) }
    @objc private func restart(_ sender: Any?) { owner?.paneAction(.restartPane, pane: terminal.paneID) }
    @objc private func close(_ sender: Any?) { owner?.paneAction(.closePane, pane: terminal.paneID) }
}


private struct Shortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    init?(_ value: String) {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = parts.last, !last.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            let modifier: NSEvent.ModifierFlags
            switch part {
            case "cmd", "super": modifier = .command
            case "ctrl", "control": modifier = .control
            case "alt", "option": modifier = .option
            case "shift": modifier = .shift
            default: return nil
            }
            guard !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let special: [String: String] = ["tab": "\t", "enter": "\r", "space": " ", "left_bracket": "[", "right_bracket": "]",
            "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
            "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!)]
        guard let key = special[last] ?? (last.count == 1 ? last : nil) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }
    func matches(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == modifiers
            && event.characters(byApplyingModifiers: [])?.lowercased() == key
    }
}

private final class PreferencesPanel: NSPanel, NSWindowDelegate {
    var onSave: ((Settings) -> Void)?
    var onClose: (() -> Void)?
    private var settings: Settings
    private let font = NSTextField()
    private let size = NSTextField()
    private let shell = NSTextField()
    private let theme = NSPopUpButton()
    private var shortcuts: [String: NSTextField] = [:]
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    init(settings: Settings) {
        self.settings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Kite Settings"
        isReleasedWhenClosed = false
        delegate = self
        font.stringValue = settings.fontFamily
        size.stringValue = String(settings.fontSize)
        shell.stringValue = settings.shell
        theme.addItems(withTitles: ["system", "dark", "light"])
        theme.selectItem(withTitle: settings.theme)
        var rows: [[NSView]] = [[NSTextField(labelWithString: "Font family"), font], [NSTextField(labelWithString: "Font size"), size],
            [NSTextField(labelWithString: "Shell"), shell], [NSTextField(labelWithString: "Theme"), theme]]
        for (key, title) in [("newSession", "New session"), ("closeSession", "Close session"), ("splitVertical", "Split left / right"),
                             ("splitHorizontal", "Split top / bottom"), ("previousSession", "Previous session"), ("nextSession", "Next session"),
                             ("nextPane", "Next pane"), ("closePane", "Close pane")] {
            let field = NSTextField(string: settings.shortcuts[key] ?? "")
            field.placeholderString = "cmd+shift+d"
            shortcuts[key] = field
            rows.append([NSTextField(labelWithString: title), field])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        let note = NSTextField(wrappingLabelWithString: "Shell changes apply to new or restarted panes. Font and theme changes apply immediately. Shortcuts use cmd, ctrl, alt and shift joined with +. Command-1 through Command-9 select sessions.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings(_:)))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [grid, note, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor), errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    func showError(_ message: String) { errorLabel.stringValue = message }
    @objc private func saveSettings(_ sender: Any?) {
        let family = font.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, family.rangeOfCharacter(from: .controlCharacters) == nil,
              family == "JetBrains Mono" || NSFont(name: family, size: 13) != nil || NSFontManager.shared.availableFontFamilies.contains(family) else {
            showError("Choose an installed font family."); return
        }
        guard let fontSize = Double(size.stringValue), fontSize.isFinite, (7...72).contains(fontSize) else { showError("Font size must be between 7 and 72."); return }
        let executable = shell.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard executable.hasPrefix("/"), !executable.contains("\n"), FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable) else {
            showError("Shell must be an absolute path to an executable file."); return
        }
        var seen = Set<String>()
        var values: [String: String] = [:]
        for (name, field) in shortcuts {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.rangeOfCharacter(from: .controlCharacters) == nil, let parsed = Shortcut(value) else { showError("Invalid shortcut for \(name). Example: cmd+shift+d."); return }
            let signature = "\(parsed.modifiers.rawValue):\(parsed.key)"
            guard seen.insert(signature).inserted else { showError("Each action needs a different shortcut."); return }
            if parsed.modifiers == .command && (Int(parsed.key).map { (1...9).contains($0) } == true || ["q", ",", "c", "v", "a"].contains(parsed.key)) {
                showError("\(value) is reserved for a standard application command."); return
            }
            values[name] = value
        }
        settings.fontFamily = family
        settings.fontSize = fontSize
        settings.shell = executable
        settings.theme = theme.titleOfSelectedItem ?? "system"
        settings.shortcuts = values
        onSave?(settings)
    }
    @objc private func cancelSettings(_ sender: Any?) { close() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@main
private enum KiteMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = KiteApp()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
