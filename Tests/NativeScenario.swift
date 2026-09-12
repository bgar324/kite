// Appended to Kite.swift only by verify-native.py; exercises the real native app.
import CoreImage
import IOSurface

@MainActor
private final class NativeFixture {
    static let shared = NativeFixture()
    var alpha: UInt32 = 0
    var alphaPane: UInt32 = 0
    var beta: UInt32 = 0
    var alphaPID: Int32 = 0
    var result: [String: Any] = [:]
    var finished = false
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KITE_TEST_ARTIFACTS"]!)
    let phase = ProcessInfo.processInfo.environment["KITE_TEST_PHASE"] ?? "exercise"
}

extension KiteApp {
    private var fixture: NativeFixture { .shared }

    func installNativeScenario() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.fixture.finished else { return }
            self.nativeFail("Native workflow exceeded 90 seconds")
        }
        nativeWait("initial workspace and terminal", until: {
            self.workspace?.sessions.count ?? 0 > 0 && self.selectedCard?.terminal.surface != nil && self.selectedCard?.pane?.attached == true
        }) {
            self.window.level = .floating
            self.window.makeKeyAndOrderFront(nil)
            self.window.setContentSize(NSSize(width: 1180, height: 780))
            if self.fixture.phase == "restore" { self.nativeRestore() }
            else { self.nativeAdvance(0) }
        }
    }

    private func nativeFail(_ message: String) -> Never {
        fixture.result["ok"] = false
        fixture.result["error"] = message
        fixture.result["panes"] = Dictionary(uniqueKeysWithValues: cards.map { (String($0.key), $0.value.nativeDiagnostic) })
        fixture.result["terminalText"] = Dictionary(uniqueKeysWithValues: cards.map { id, card in
            (String(id), nativeText(card.terminal).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(10).joined(separator: "\n"))
        })
        fixture.result["hostFrame"] = NSStringFromRect(terminalHost.frame)
        fixture.result["rootFrame"] = terminalHost.subviews.first.map { NSStringFromRect($0.frame) } ?? "none"
        nativeWriteResult()
        Darwin.exit(1)
    }
    private func nativeRequire(_ predicate: Bool, _ message: String) {
        if !predicate { nativeFail(message) }
    }
    private func nativeWriteResult() {
        let data = try! JSONSerialization.data(withJSONObject: fixture.result, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: fixture.directory.appendingPathComponent("native-\(fixture.phase).json"), options: .atomic)
    }
    private func nativeWait(_ label: String, until predicate: @escaping () -> Bool, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(15)
        func check() {
            if predicate() { action(); return }
            if Date() >= deadline {
                nativeFail("Timed out: \(label); status=\(status.stringValue)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { check() }
        }
        DispatchQueue.main.async { check() }
    }
    private func nativeText(_ terminal: TerminalView) -> String {
        guard let surface = terminal.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_SCREEN
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_SCREEN
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var output = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &output), let pointer = output.text else { return "" }
        defer { ghostty_surface_free_text(surface, &output) }
        return String(cString: pointer)
    }
    private func nativeCommand(_ command: String, in terminal: TerminalView) {
        window.makeFirstResponder(terminal)
        terminal.insertText(command, replacementRange: NSRange(location: NSNotFound, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            terminal.keyDown(with: enter)
        }
    }
    private func nativeHiddenTabCheck(then action: @escaping () -> Void) {
        guard let terminal = cards[fixture.alphaPane]?.terminal, let layer = terminal.layer else { nativeFail("Missing retained background terminal") }
        nativeRequire(!terminal.attachmentVisible, "Background tab remains marked visible")
        let retainedSurface = terminal.surface
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var presentations = 0
            let observer = layer.observe(\.contents, options: [.new]) { _, _ in
                MainActor.assumeIsolated { presentations += 1 }
            }
            let before = cpuSeconds()
            terminal.insertText("i=0; while [ $i -lt 20 ]; do printf 'HIDDEN_TICK_%s\\n' $i; i=$((i+1)); sleep 0.03; done", replacementRange: NSRange(location: NSNotFound, length: 0))
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            terminal.keyDown(with: enter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                observer.invalidate()
                let cpu = cpuSeconds() - before
                self.nativeRequire(terminal.surface == retainedSurface, "Tab switch replaced the retained terminal")
                self.nativeRequire(self.nativeText(terminal).contains("HIDDEN_TICK_19"), "Hidden shell output stopped progressing")
                self.nativeRequire(presentations == 0, "Hidden terminal presented frames")
                self.nativeRequire(cpu < 0.1, "Hidden-output sample consumed over 100ms of GUI CPU")
                self.fixture.result["hidden_tab_presentations"] = presentations
                self.fixture.result["hidden_tab_cpu_seconds_over_1_5s"] = cpu
                self.fixture.result["hidden_tab_output_progress"] = true
                action()
            }
        }
    }
    private func nativeInputMethodCheck(_ terminal: TerminalView, then action: @escaping () -> Void) {
        terminal.insertText("printf '\\125NICODE_%s\\n' ", replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        nativeRequire(terminal.hasMarkedText(), "IME preedit was not retained")
        terminal.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        nativeRequire(!terminal.hasMarkedText(), "IME commit did not clear preedit")
        nativeCommand("", in: terminal)
        nativeWait("Unicode input method commit", until: { self.nativeText(terminal).contains("UNICODE_日本語") }) {
            self.fixture.result["native_ime_commit"] = true
            action()
        }
    }
    private func nativeFullScreenCheck(then action: @escaping () -> Void) {
        let file = fixture.directory.appendingPathComponent("vim-buffer.txt")
        try! "TUI_PERSIST_MARKER\nThe editor process must survive reconnect.\n".write(to: file, atomically: true, encoding: .utf8)
        nativeCommand("/usr/bin/vim -Nu NONE -i NONE -n --noplugin \(shellQuote(file.path))", in: selectedCard!.terminal)
        nativeWait("real full-screen Vim startup", until: {
            self.selectedCard?.terminal.surface != nil && self.nativeText(self.selectedCard!.terminal).contains("TUI_PERSIST_MARKER")
        }) {
            self.reconnect(nil)
            self.nativeWait("Vim alternate screen reconstructed", until: {
                self.selectedCard?.pane?.attached == true && self.selectedCard?.terminal.surface != nil &&
                    self.nativeText(self.selectedCard!.terminal).contains("TUI_PERSIST_MARKER")
            }) {
                self.fixture.result["vim_reconnect"] = true
                let terminal = self.selectedCard!.terminal
                let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [("\u{1b}", 53, []), (":", 41, .shift), ("q", 12, []), ("!", 18, .shift), ("\r", 36, [])]
                for (index, key) in keys.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.2,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                            context: nil, characters: key.0, charactersIgnoringModifiers: key.0, isARepeat: false, keyCode: key.1)!
                        terminal.keyDown(with: event)
                    }
                }
                self.nativeWait("primary screen restored when Vim exits", until: { self.nativeText(terminal).contains("KITE_PERSIST_MARKER") }) {
                    self.fixture.result["vim_exit_restores_primary"] = true
                    action()
                }
            }
        }
    }
    private func nativeKeyboardCheck(_ terminal: TerminalView, then action: @escaping () -> Void) {
        let keys: [(String, UInt16)] = [("e", 14), ("c", 8), ("h", 4), ("o", 31), (" ", 49), ("x", 7), ("\r", 36)]
        window.makeFirstResponder(terminal)
        for (index, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(index) * 0.08) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                    context: nil, characters: key.0, charactersIgnoringModifiers: key.0, isARepeat: false, keyCode: key.1)!
                terminal.keyDown(with: event)
            }
        }
        nativeWait("native character key events", until: {
            self.nativeText(terminal).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "x" }
        }) { self.fixture.result["native_keyboard"] = true; action() }
    }
    private func nativeClipboardCheck(_ terminal: TerminalView, then action: @escaping () -> Void) {
        func save() -> [[(NSPasteboard.PasteboardType, Data)]] {
            (NSPasteboard.general.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        func restore(_ data: [[(NSPasteboard.PasteboardType, Data)]]) {
            let items = data.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, bytes) in values { item.setData(bytes, forType: type) }
                return item
            }
            NSPasteboard.general.clearContents()
            if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        }
        let saved = save()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("printf '\\120ASTE_NATIVE_OK\\n'", forType: .string)
        let change = NSPasteboard.general.changeCount
        terminal.paste(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSPasteboard.general.changeCount == change { restore(saved) }
            self.nativeCommand("", in: terminal)
        }
        nativeWait("native clipboard paste", until: { self.nativeText(terminal).contains("PASTE_NATIVE_OK") }) {
            let beforeCopy = save()
            terminal.selectAll(nil)
            terminal.copy(nil)
            let copied = NSPasteboard.general.string(forType: .string)?.contains("KITE_PERSIST_MARKER") == true
            restore(beforeCopy)
            self.nativeRequire(copied, "Native copy did not write terminal selection")
            self.fixture.result["native_clipboard"] = true
            action()
        }
    }
    private func nativeDividerAndMove() {
        guard let split = terminalHost.subviews.first as? PaneSplitView else { nativeFail("Missing native split view") }
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition(extent * 0.43, ofDividerAt: 0)
        split.onDividerChange?(0.43)
        nativeWait("divider ratio persisted from native callback", until: {
            guard let layout = self.selectedSession?.layout, case .split(_, _, let ratio, _, _) = layout else { return false }
            return abs(ratio - 0.43) < 0.0001
        }) {
            self.fixture.result["native_divider_persistence"] = true
            let moving = self.selectedSession!.selectedPane
            let pid = self.workspace!.pane(id: moving)!.pid
            self.movePane(nil)
            self.nativeWait("move pane into new native session", until: {
                self.workspace?.sessions.count == 3 && self.selectedSession?.id != self.fixture.beta &&
                    self.selectedSession?.id != self.fixture.alpha && self.selectedSession?.selectedPane == moving &&
                    self.selectedCard?.pane?.attached == true
            }) {
                self.nativeRequire((self.selectedCard?.terminal.bounds.height ?? 0) > 100, "Moved pane collapsed during reparenting")
                self.nativeCapture(fileName: "native-moved.png")
                self.nativeRequire(self.selectedCard?.pane?.pid == pid, "Moving pane replaced its shell")
                self.fixture.result["native_move_pane"] = true
                self.nativeModal(button: "Close Session")
                self.closeSession(nil)
                self.nativeWait("close moved session", until: { self.workspace?.sessions.count == 2 }) { self.nativeAdvance(4) }
            }
        }
    }
    private func nativeModal(button title: String, text: String? = nil) {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func dialogViews() -> [NSView] {
            let windows = NSApp.modalWindow.map { [$0] } ?? NSApp.windows.filter { $0 !== self.window && $0.isVisible }
            return windows.compactMap(\.contentView).flatMap(descendants)
        }
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
            let views = dialogViews()
            guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                if Date() >= deadline { timer.invalidate(); self.nativeFail("Native dialog action not found: \(title)") }
                return
            }
            if let text, let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) { field.stringValue = text }
            timer.invalidate()
            button.performClick(nil)
            }
        }
        // Modal AppKit loops service run-loop timers, not nested main-queue work.
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
    }
    private func nativeCapture(fileName: String = "native-workspace.png") {
        guard let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { nativeFail("Cannot capture native view") }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(bitmap)
        image.lockFocus()
        for (id, card) in cards where card.terminal.attachmentVisible {
            guard let contents = card.terminal.layer?.contents else { nativeFail("Pane \(id) has no rendered Metal surface") }
            let io = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            let native = CIImage(ioSurface: io)
            guard let cg = CIContext().createCGImage(native, from: native.extent) else { nativeFail("Cannot read rendered pane \(id)") }
            let rectangle = card.terminal.convert(card.terminal.bounds, to: root)
            nativeRequire(rectangle.width > 50 && rectangle.height > 50, "Pane has unusable geometry")
            NSImage(cgImage: cg, size: rectangle.size).draw(in: rectangle)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { nativeFail("Cannot encode native capture") }
        try! png.write(to: fixture.directory.appendingPathComponent(fileName))
        fixture.result["rendered_panes"] = max(fixture.result["rendered_panes"] as? Int ?? 0, cards.values.filter { $0.terminal.attachmentVisible }.count)
        fixture.result["window_id"] = window.windowNumber
        let windowRecord = try! JSONSerialization.data(withJSONObject: ["id": window.windowNumber])
        try! windowRecord.write(to: fixture.directory.appendingPathComponent("window.json"), options: .atomic)
    }

    private func nativeAdvance(_ step: Int) {
        switch step {
        case 0:
            fixture.alpha = selectedSession!.id
            fixture.alphaPane = selectedSession!.selectedPane
            fixture.alphaPID = selectedCard!.pane!.pid!
            let terminal = selectedCard!.terminal
            nativeCommand("export KITE_NATIVE_PERSIST=kept; printf '\\113ITE_PERSIST_MARKER\\n'", in: terminal)
            nativeWait("shell command through native input", until: { self.nativeText(terminal).contains("KITE_PERSIST_MARKER") }) {
                self.nativeKeyboardCheck(terminal) { self.nativeAdvance(1) }
            }
        case 1:
            newSession(nil)
            nativeWait("second sidebar session", until: { self.workspace?.sessions.count == 2 && self.selectedSession?.id != self.fixture.alpha && self.selectedCard?.pane?.attached == true }) {
                self.nativeRequire(self.table.numberOfRows == 2, "Sidebar does not reflect two sessions")
                self.fixture.beta = self.selectedSession!.id
                self.nativeHiddenTabCheck {
                    self.nativeModal(button: "Rename", text: "Native beta")
                    self.renameSession(nil)
                    self.nativeWait("renamed sidebar session", until: { self.selectedSession?.title == "Native beta" }) { self.nativeAdvance(2) }
                }
            }
        case 2:
            splitVertical(nil)
            nativeWait("vertical split", until: { self.selectedSession?.panes.count == 2 && self.selectedSession!.panes.allSatisfy(\.attached) }) {
                self.splitHorizontal(nil)
                self.nativeWait("nested horizontal split", until: { self.selectedSession?.panes.count == 3 && self.selectedSession!.panes.allSatisfy(\.attached) }) { self.nativeAdvance(3) }
            }
        case 3:
            for pane in selectedSession!.panes {
                let terminal = cards[pane.id]!.terminal
                nativeCommand("printf '\\120ANE_\(pane.id)\\n'; stty size", in: terminal)
            }
            nativeWait("all three panes render shell output", until: {
                self.selectedSession!.panes.allSatisfy { self.nativeText(self.cards[$0.id]!.terminal).contains("PANE_\($0.id)") }
            }) {
                let old = self.selectedSession!.selectedPane
                self.nextPane(nil)
                self.nativeWait("pane focus navigation", until: { self.selectedSession?.selectedPane != old && self.window.firstResponder === self.selectedCard?.terminal }) {
                    self.nativeCapture()
                    self.fixture.result["split_and_focus"] = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.nativeDividerAndMove() }
                }
            }
        case 4:
            send(ControlRequest(op: .reorderSession, session: fixture.beta, index: 0)) { response in
                self.nativeRequire(response.ok, "Session reorder failed")
                self.nativeWait("sidebar reorder", until: { self.workspace?.sessions.first?.id == self.fixture.beta }) {
                    self.selectSessionAt(1)
                    self.nativeWait("keyboard-index session selection", until: { self.selectedSession?.id == self.fixture.alpha && self.selectedCard?.pane?.attached == true }) { self.nativeAdvance(5) }
                }
            }
        case 5:
            nativeRequire(nativeText(selectedCard!.terminal).contains("KITE_PERSIST_MARKER"), "Tab switch lost terminal contents")
            reconnect(nil)
            nativeWait("reconstructed native terminal after reconnect", until: {
                self.selectedCard?.pane?.attached == true && self.selectedCard?.terminal.surface != nil && self.nativeText(self.selectedCard!.terminal).contains("KITE_PERSIST_MARKER")
            }) {
                self.nativeRequire(self.selectedCard?.pane?.pid == self.fixture.alphaPID, "Reconnection replaced shell")
                self.fixture.result["native_snapshot_reconnect"] = true
                self.nativeClipboardCheck(self.selectedCard!.terminal) {
                    self.nativeInputMethodCheck(self.selectedCard!.terminal) {
                        self.nativeFullScreenCheck {
                            self.showPreferences(nil)
                            self.preferencePanel!.nativeConfigureAndSave()
                            self.nativeWait("persisted native preferences", until: { self.workspace?.settings.fontSize == 16 && self.workspace?.settings.theme == "dark" && self.preferencePanel == nil }) { self.nativeAdvance(6) }
                        }
                    }
                }
            }
        case 6:
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)!
            nativeRequire(handleShortcut(event), "Configured shortcut was not recognized")
            nativeWait("configured shortcut creates a session", until: { self.workspace?.sessions.count == 3 && self.selectedCard?.pane?.attached == true }) {
                self.nativeModal(button: "Close Session")
                self.closeSession(nil)
                self.nativeWait("close session confirmation", until: { self.workspace?.sessions.count == 2 }) { self.nativeAdvance(7) }
            }
        case 7:
            let index = workspace!.sessions.firstIndex { $0.id == fixture.beta }!
            selectSessionAt(index)
            nativeWait("select split session for close", until: { self.selectedSession?.id == self.fixture.beta && self.selectedCard?.pane?.attached == true }) {
                let remaining = self.selectedSession!.panes.count - 1
                self.nativeModal(button: "Close Pane")
                self.closePane(nil)
                self.nativeWait("closed pane collapses layout", until: { self.selectedSession?.panes.count == remaining }) { self.nativeAdvance(8) }
            }
        case 8:
            nativeModal(button: "Close Session")
            closeSession(nil)
            nativeWait("close split session", until: { self.workspace?.sessions.count == 1 && self.selectedSession?.id == self.fixture.alpha && self.selectedCard?.pane?.attached == true }) {
                self.fixture.result["session_actions_and_preferences"] = true
                self.fixture.result["alpha"] = self.fixture.alpha
                self.fixture.result["alpha_pane"] = self.fixture.alphaPane
                self.fixture.result["alpha_pid"] = self.fixture.alphaPID
                self.nativeFinish()
            }
        default: nativeFail("Unknown native scenario step")
        }
    }
    private func nativeRestore() {
        let data = try! Data(contentsOf: fixture.directory.appendingPathComponent("native-exercise.json"))
        let previous = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = (previous["alpha_pane"] as! NSNumber).uint32Value
        let pid = (previous["alpha_pid"] as! NSNumber).int32Value
        nativeWait("workspace and screen after GUI relaunch", until: {
            self.workspace?.pane(id: id)?.attached == true && self.cards[id]?.terminal.surface != nil && self.nativeText(self.cards[id]!.terminal).contains("KITE_PERSIST_MARKER")
        }) {
            self.nativeRequire(self.workspace?.pane(id: id)?.pid == pid, "GUI relaunch replaced persistent shell")
            self.nativeRequire(self.workspace?.settings.fontSize == 16, "GUI relaunch lost settings")
            self.fixture.result["gui_relaunch_preserves_screen_and_pid"] = true
            self.nativeFinish()
        }
    }
    private func nativeFinish() {
        fixture.result["ok"] = true
        fixture.finished = true
        nativeWriteResult()
        window.level = .normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

extension PreferencesPanel {
    func nativeConfigureAndSave() {
        font.stringValue = "Menlo"
        size.stringValue = "16"
        shell.stringValue = "/bin/sh"
        theme.selectItem(withTitle: "dark")
        shortcuts["newSession"]!.stringValue = "cmd+alt+t"
        saveSettings(nil)
    }
}

extension PaneCard {
    var nativeDiagnostic: [String: Any] {
        ["frame": NSStringFromRect(frame), "terminalFrame": NSStringFromRect(terminal.frame),
         "terminalBounds": NSStringFromRect(terminal.bounds), "label": state.stringValue,
         "attached": pane?.attached ?? false, "starting": attachmentStarting,
         "visible": terminal.attachmentVisible, "canAttach": canAttach,
         "hasSurface": terminal.surface != nil]
    }
}
