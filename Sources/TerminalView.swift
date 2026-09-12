import AppKit
import Carbon
import QuartzCore

private func inputMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var bits: UInt32 = 0
    if flags.contains(.shift) { bits |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { bits |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { bits |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { bits |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { bits |= GHOSTTY_MODS_CAPS.rawValue }
    if flags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { bits |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if flags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 { bits |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { bits |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 { bits |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(bits)
}

final class TerminalView: NSView, NSTextInputClient {
    weak var owner: KiteApp?
    var paneID: UInt32 = 0
    var attachmentVisible = false { didSet { syncWindowState() } }
    private(set) var surface: ghostty_surface_t?
    private var marked = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var keyText: [String]?
    private var cursor = NSCursor.iBeam
    private var keyboardGeneration = 0

    static func from(_ pointer: UnsafeMutableRawPointer?) -> TerminalView? {
        pointer.map { Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("Terminal pane")
        NotificationCenter.default.addObserver(self, selector: #selector(inputSourceChanged),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var acceptsFirstResponder: Bool { true }

    func connect(app: ghostty_app_t, command: String) -> Bool {
        var options = ghostty_surface_config_new()
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        options.userdata = Unmanaged.passUnretained(self).toOpaque()
        options.scale_factor = Double(window?.backingScaleFactor ?? 1)
        options.wait_after_command = true
        surface = command.withCString {
            options.command = $0
            return ghostty_surface_new(app, &options)
        }
        guard surface != nil else { return false }
        // libghostty installs its own Metal-backed IOSurfaceLayer on this NSView.
        syncGeometry()
        syncWindowState()
        viewDidChangeEffectiveAppearance()
        updateTrackingAreas()
        return true
    }

    func disconnect() {
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
        }
    }

    func syncGeometry() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let pixels = convertToBacking(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, pixels.width / bounds.width, pixels.height / bounds.height)
        ghostty_surface_set_size(surface, UInt32(pixels.width.rounded()), UInt32(pixels.height.rounded()))
        if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
        inputContext?.invalidateCharacterCoordinates()
    }

    func syncWindowState() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, attachmentVisible && window?.firstResponder === self && window?.isKeyWindow == true && NSApp.isActive)
        ghostty_surface_set_occlusion(surface, attachmentVisible && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncGeometry(); syncWindowState() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncGeometry() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); syncGeometry() }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let surface { ghostty_surface_set_focus(surface, attachmentVisible && window?.isKeyWindow == true && NSApp.isActive) }
        owner?.paneFocused(paneID)
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.appearanceChanged()
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
    }
    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, inputMods(event.modifierFlags))
    }
    override func mouseEntered(with event: NSEvent) { cursor.set(); mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, inputMods(event.modifierFlags)) }
    }
    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        if state == GHOSTTY_MOUSE_PRESS { window?.makeFirstResponder(self) }
        mouseMoved(with: event)
        _ = ghostty_surface_mouse_button(surface, state, button, inputMods(event.modifierFlags))
    }
    override func mouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_PRESS, event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN)
    }
    override func otherMouseUp(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_RELEASE, event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN)
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        let precision: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        let multiplier = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * multiplier,
            event.scrollingDeltaY * multiplier, precision | (momentum << 1))
    }
    override func pressureChange(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure)) }
    }

    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { binding("select_all") }
    private func binding(_ name: String) {
        guard let surface else { return }
        name.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count)) }
    }
    @objc private func inputSourceChanged() { keyboardGeneration += 1 }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        if owner?.handleShortcut(event) == true { return true }
        if event.modifierFlags.contains(.control) {
            if event.charactersIgnoringModifiers == "\r" {
                keyDown(with: event)
                return true
            }
            if event.charactersIgnoringModifiers == "/",
               event.modifierFlags.isDisjoint(with: [.shift, .command, .option]),
               let translated = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                   modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                   windowNumber: event.windowNumber, context: nil, characters: "_",
                   charactersIgnoringModifiers: "_", isARepeat: event.isARepeat, keyCode: event.keyCode) {
                keyDown(with: translated)
                return true
            }
        }
        guard event.modifierFlags.contains(.command) else { return false }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        let translated = ghostty_surface_key_translation_mods(surface, inputMods(event.modifierFlags)).rawValue
        var flags = event.modifierFlags
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
                            (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if translated & bit.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        // Keep the original NSEvent identity when possible; Korean input depends on it.
        let translatedEvent = flags == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        let wasMarked = hasMarkedText()
        let generation = keyboardGeneration
        keyText = []
        defer { keyText = nil }
        interpretKeyEvents([translatedEvent])
        if !wasMarked && keyboardGeneration != generation { return }
        syncPreedit()
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if let text = keyText, !text.isEmpty {
            for value in text { sendKey(event, action, text: value, translationFlags: flags) }
        } else {
            var text = translatedEvent.characters
            if let scalar = text?.unicodeScalars.first, text?.count == 1 {
                if scalar.value < 0x20 {
                    text = translatedEvent.characters(byApplyingModifiers: flags.subtracting(.control))
                } else if (0xF700...0xF8FF).contains(scalar.value) {
                    text = nil
                }
            }
            sendKey(event, action, text: text, composing: wasMarked || hasMarkedText(), translationFlags: flags)
        }
    }
    override func keyUp(with event: NSEvent) { sendKey(event, GHOSTTY_ACTION_RELEASE) }
    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText() else { return }
        let mask: UInt
        switch event.keyCode {
        case 0x38: mask = UInt(NX_DEVICELSHIFTKEYMASK)
        case 0x3C: mask = UInt(NX_DEVICERSHIFTKEYMASK)
        case 0x3B: mask = UInt(NX_DEVICELCTLKEYMASK)
        case 0x3E: mask = UInt(NX_DEVICERCTLKEYMASK)
        case 0x3A: mask = UInt(NX_DEVICELALTKEYMASK)
        case 0x3D: mask = UInt(NX_DEVICERALTKEYMASK)
        case 0x37: mask = UInt(NX_DEVICELCMDKEYMASK)
        case 0x36: mask = UInt(NX_DEVICERCMDKEYMASK)
        case 0x39:
            sendKey(event, event.modifierFlags.contains(.capsLock) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
            return
        default: return
        }
        sendKey(event, event.modifierFlags.rawValue & UInt(mask) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
    }
    private func sendKey(_ event: NSEvent, _ action: ghostty_input_action_e, text: String? = nil,
                         composing: Bool = false, translationFlags: NSEvent.ModifierFlags? = nil) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = inputMods(event.modifierFlags)
        key.consumed_mods = inputMods((translationFlags ?? event.modifierFlags).subtracting([.control, .command]))
        key.composing = composing
        if event.type == .keyDown || event.type == .keyUp {
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }
    override func doCommand(by selector: Selector) {
        // During interpretKeyEvents, Ghostty encodes command keys in sendKey instead.
        if keyText == nil { super.doCommand(by: selector) }
    }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange {
        NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length)
    }
    func selectedRange() -> NSRange {
        if hasMarkedText() { return markedSelection }
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: NSNotFound, length: 0) }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }
    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let value = value as? NSAttributedString { marked = value }
        else if let value = value as? String { marked = NSAttributedString(string: value) }
        else { return }
        markedSelection = selectedRange
        if keyText == nil { syncPreedit() }
    }
    func unmarkText() {
        marked = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        syncPreedit()
    }
    private func syncPreedit() {
        guard let surface else { return }
        if hasMarkedText() {
            marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) }
        } else { ghostty_surface_preedit(surface, nil, 0) }
        inputContext?.invalidateCharacterCoordinates()
    }
    func insertText(_ value: Any, replacementRange: NSRange) {
        let text: String
        if let value = value as? NSAttributedString { text = value.string }
        else if let value = value as? String { text = value }
        else { return }
        unmarkText()
        if keyText != nil { keyText?.append(text) }
        else if let surface { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if hasMarkedText() {
            let intersection = NSIntersectionRange(range, NSRange(location: 0, length: marked.length))
            guard intersection.length > 0 else { return nil }
            actualRange?.pointee = intersection
            return marked.attributedSubstring(from: intersection)
        }
        guard range.length > 0, let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), let value = text.text else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        actualRange?.pointee = NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
        return NSAttributedString(string: String(cString: value))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
