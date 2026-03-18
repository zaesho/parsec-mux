/// ParsecInputView — NSView subclass that captures keyboard and mouse events
/// and forwards them to the Parsec SDK via ParsecClient.
/// Implements Cmd+Shift combo system modeled after the C viewer.

import AppKit
import CParsecBridge

/// macOS virtual keycodes -> USB HID scancodes (ParsecKeycode)
let macOSToHID: [UInt32] = [
    4,22,7,9,11,10,29,27,6,25,100,5,20,26,8,21,    // 0x00-0x0F
    28,23,30,31,32,33,35,34,46,38,36,45,37,39,48,18, // 0x10-0x1F
    24,47,12,19,40,15,13,52,14,51,49,54,56,17,16,55, // 0x20-0x2F
    43,44,53,42,0,41,231,227,225,57,226,224,229,230,228,0, // 0x30-0x3F
    108,99,0,85,0,87,0,83,128,129,127,84,88,0,86,109, // 0x40-0x4F
    110,103,98,89,90,91,92,93,0,96,97,0,0,0,0,0,     // 0x50-0x5F
    62,63,64,60,65,66,0,68,0,104,107,105,0,67,101,69, // 0x60-0x6F
    0,106,73,74,75,76,61,77,59,78,58,80,79,81,82,0,  // 0x70-0x7F
]

/// macOS F-key virtual keycodes
let fKeyMap: [UInt16: Int] = [
    0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4,
    0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8,
]

/// Combo actions triggered by Cmd+Shift+Key
enum ComboAction {
    case toggleGrid          // G
    case toggleDebug         // D
    case toggleSidebar       // S
    case openQualityPicker   // Q
    case prevSession         // 8
    case nextSession         // 9
    case disconnect          // `
    case reconnect           // R
    case forceSingleMode     // F
    case gridArrow(ArrowDirection) // arrows in grid mode
}

enum ArrowDirection {
    case left, right, up, down
}

/// Callback for session switching and combo actions
protocol InputViewDelegate: AnyObject {
    func inputView(_ view: ParsecInputView, didRequestSwitchToSlot slot: Int)
    func inputView(_ view: ParsecInputView, didFireCombo action: ComboAction)
    func inputViewShouldConsumeKeyForOverlay(_ view: ParsecInputView, keyCode: UInt16, isDown: Bool, characters: String?) -> Bool
}

class ParsecInputView: NSView {
    weak var parsecClient: ParsecClient?
    weak var inputDelegate: InputViewDelegate?
    var isRelativeMode = false

    /// After a combo fires, suppress modifier keyup events for 200ms
    private var comboEndTime: CFAbsoluteTime = 0
    private let comboSuppressDuration: CFAbsoluteTime = 0.2

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()

        // Ensure our window accepts mouse moved events
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Add fresh tracking area covering visible bounds
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    // MARK: - Keyboard

    private func hidCode(for keyCode: UInt16) -> UInt32 {
        let idx = Int(keyCode)
        guard idx < macOSToHID.count else { return 0 }
        return macOSToHID[idx]
    }

    private func isCmdShiftHeld(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && flags.contains(.shift)
    }

    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E:
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if let delegate = inputDelegate,
           delegate.inputViewShouldConsumeKeyForOverlay(self, keyCode: event.keyCode, isDown: true, characters: event.characters) {
            return
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad]).isEmpty,
           let slot = fKeyMap[event.keyCode] {
            inputDelegate?.inputView(self, didRequestSwitchToSlot: slot)
            return
        }

        if isCmdShiftHeld(event) {
            handleComboKeyDown(event)
            return
        }

        guard let client = parsecClient else { return }
        let code = hidCode(for: event.keyCode)
        if code == 0 { return }
        client.sendKeyboard(code: code, mod: 0, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        if let delegate = inputDelegate,
           delegate.inputViewShouldConsumeKeyForOverlay(self, keyCode: event.keyCode, isDown: false, characters: nil) {
            return
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad]).isEmpty,
           fKeyMap[event.keyCode] != nil {
            return
        }

        if CFAbsoluteTimeGetCurrent() - comboEndTime < comboSuppressDuration {
            if isModifierKey(event.keyCode) {
                return
            }
        }

        if isCmdShiftHeld(event) {
            return
        }

        guard let client = parsecClient else { return }
        let code = hidCode(for: event.keyCode)
        if code == 0 { return }
        client.sendKeyboard(code: code, mod: 0, pressed: false)
    }

    private func handleComboKeyDown(_ event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: ComboAction?

        switch chars {
        case "g": action = .toggleGrid
        case "d": action = .toggleDebug
        case "s": action = .toggleSidebar
        case "q": action = .openQualityPicker
        case "8": action = .prevSession
        case "9": action = .nextSession
        case "`": action = .disconnect
        case "r": action = .reconnect
        case "f": action = .forceSingleMode
        default:
            switch event.keyCode {
            case 123: action = .gridArrow(.left)
            case 124: action = .gridArrow(.right)
            case 126: action = .gridArrow(.up)
            case 125: action = .gridArrow(.down)
            default: break
            }
        }

        if let action = action {
            comboEndTime = CFAbsoluteTimeGetCurrent()
            releaseAllModifiers()
            inputDelegate?.inputView(self, didFireCombo: action)
        }
    }

    private func releaseAllModifiers() {
        guard let client = parsecClient else { return }
        for code: UInt32 in [224, 225, 226, 227, 228, 229, 230, 231] {
            client.sendKeyboard(code: code, mod: 0, pressed: false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if CFAbsoluteTimeGetCurrent() - comboEndTime < comboSuppressDuration {
            if isModifierKey(event.keyCode) {
                return
            }
        }

        guard let client = parsecClient else { return }
        let code = hidCode(for: event.keyCode)
        if code == 0 { return }

        let flags = event.modifierFlags
        let pressed: Bool
        switch Int(event.keyCode) {
        case 0x37, 0x36: pressed = flags.contains(.command)
        case 0x38, 0x3C: pressed = flags.contains(.shift)
        case 0x3A, 0x3D: pressed = flags.contains(.option)
        case 0x3B, 0x3E: pressed = flags.contains(.control)
        case 0x39:       pressed = flags.contains(.capsLock)
        default:         pressed = false
        }

        if pressed && flags.contains(.command) && flags.contains(.shift) {
            return
        }

        client.sendKeyboard(code: code, mod: 0, pressed: pressed)
    }

    // MARK: - Mouse Motion

    override func mouseMoved(with event: NSEvent) { sendMotion(event) }
    override func mouseDragged(with event: NSEvent) { sendMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMotion(event) }

    private func sendMotion(_ event: NSEvent) {
        guard let client = parsecClient else { return }
        if isRelativeMode {
            client.sendMouseMotion(x: Int32(event.deltaX), y: Int32(event.deltaY), relative: true)
            return
        }

        // Per-pane MTKView: raw view coords, setDimensions matches this view's size
        let loc = convert(event.locationInWindow, from: nil)
        let x = Int32(loc.x)
        let y = Int32(self.bounds.height - loc.y)
        client.sendMouseMotion(x: x, y: y, relative: false)
    }

    // MARK: - Mouse Buttons

    override func mouseDown(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 1, pressed: true)
    }
    override func mouseUp(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 1, pressed: false)
    }
    override func rightMouseDown(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 3, pressed: true)
    }
    override func rightMouseUp(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 3, pressed: false)
    }
    override func otherMouseDown(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 2, pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        parsecClient?.sendMouseButton(button: 2, pressed: false)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let client = parsecClient else { return }
        let isTrackpad = event.phase != [] || event.momentumPhase != []
        if event.momentumPhase != [] { return }

        if isTrackpad {
            client.sendMouseWheel(x: Int32(event.scrollingDeltaX * 2),
                                  y: Int32(event.scrollingDeltaY * -2))
        } else {
            client.sendMouseWheel(x: Int32(event.scrollingDeltaX * 120),
                                  y: Int32(event.scrollingDeltaY * 120))
        }
    }
}
