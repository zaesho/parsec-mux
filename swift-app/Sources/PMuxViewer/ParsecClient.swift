/// Swift wrapper around the CParsecBridge C functions.
/// Each instance owns one ParsecDSO handle (one Parsec connection).

import Foundation
import CParsecBridge

final class ParsecClient: @unchecked Sendable {
    private let dso: OpaquePointer
    let port: UInt16

    /// Expose handle for direct C bridge calls from the GL view
    var dsoHandle: OpaquePointer { dso }

    init(sdkPath: String, clientPort: UInt16) throws {
        var dsoPtr: OpaquePointer?
        let status = pmux_init(sdkPath, clientPort, &dsoPtr)
        guard status == 0, let dso = dsoPtr else {
            throw ParsecError.initFailed(code: status)
        }
        self.dso = dso
        self.port = clientPort
    }

    deinit { pmux_destroy(dso) }

    var version: String {
        let v = pmux_version(dso)
        return "\(v >> 16).\(v & 0xFFFF)"
    }

    // MARK: - Connection

    struct Quality {
        var h265: Bool = false
        var color444: Bool = false
        var decoderIndex: Int32 = 1
        var resX: Int32 = 0
        var resY: Int32 = 0
    }

    func connect(sessionID: String, peerID: String, quality: Quality = Quality()) throws {
        let status = pmux_connect(dso, sessionID, peerID,
                                   quality.h265, quality.color444, quality.decoderIndex,
                                   quality.resX, quality.resY)
        guard status == 0 else { throw ParsecError.connectFailed(code: status) }
    }

    func disconnect() { pmux_disconnect(dso) }

    func getStatus() -> (code: Int32, status: ParsecClientStatus) {
        var st = ParsecClientStatus()
        let code = pmux_get_status(dso, &st)
        return (code, st)
    }

    func setDimensions(stream: UInt8 = 0, width: UInt32, height: UInt32, scale: Float) {
        pmux_set_dimensions(dso, stream, width, height, scale)
    }

    func enableStream(_ stream: UInt8, enable: Bool) {
        pmux_enable_stream(dso, stream, enable)
    }

    // MARK: - Input

    func sendKeyboard(code: UInt32, mod: UInt16, pressed: Bool) {
        pmux_send_keyboard(dso, code, mod, pressed)
    }

    func sendMouseMotion(x: Int32, y: Int32, relative: Bool, stream: UInt8 = 0) {
        pmux_send_mouse_motion(dso, x, y, relative, stream)
    }

    func sendMouseButton(button: UInt32, pressed: Bool) {
        pmux_send_mouse_button(dso, button, pressed)
    }

    func sendMouseWheel(x: Int32, y: Int32) {
        pmux_send_mouse_wheel(dso, x, y)
    }

    func sendClipboard(_ text: String) {
        text.withCString { pmux_send_clipboard(dso, $0) }
    }

    // MARK: - Rendering

    func metalRenderFrame(stream: UInt8 = 0, commandQueue: AnyObject,
                          texture: inout AnyObject?, timeout: UInt32) -> Int32 {
        let cq = Unmanaged.passUnretained(commandQueue).toOpaque()
        var texPtr: UnsafeMutableRawPointer? = texture.map {
            Unmanaged.passUnretained($0).toOpaque()
        }
        let status = pmux_metal_render(dso, stream, cq, &texPtr, timeout)
        if let ptr = texPtr {
            texture = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
        }
        return status
    }

    func pollFrame(stream: UInt8 = 0, callback: pmux_frame_cb,
                   timeout: UInt32, opaque: UnsafeMutableRawPointer?) -> Int32 {
        return pmux_poll_frame(dso, stream, callback, timeout, opaque)
    }

    // MARK: - GL Offscreen Rendering

    func glInit(width: UInt32, height: UInt32) -> Int32 {
        return pmux_gl_init(dso, width, height)
    }

    func glRender(stream: UInt8 = 0, timeout: UInt32,
                  pixels: UnsafeMutableRawPointer, bufSize: UInt32,
                  outW: inout UInt32, outH: inout UInt32) -> Int32 {
        return pmux_gl_render(dso, stream, timeout, pixels, bufSize, &outW, &outH)
    }

    func glDestroy() {
        pmux_gl_destroy(dso)
    }

    func glStreamDestroy(stream: UInt8 = 0) {
        pmux_gl_stream_destroy(dso, stream)
    }

    // MARK: - Audio

    func pollAudio(callback: pmux_audio_cb, timeout: UInt32,
                   opaque: UnsafeMutableRawPointer?) -> Int32 {
        return pmux_poll_audio(dso, callback, timeout, opaque)
    }

    // MARK: - Events

    func pollEvents(timeout: UInt32 = 0) -> ParsecClientEvent? {
        var event = ParsecClientEvent()
        if pmux_poll_events(dso, timeout, &event) {
            return event
        }
        return nil
    }

    func getBuffer(key: UInt32) -> UnsafeMutableRawPointer? {
        return pmux_get_buffer(dso, key)
    }

    func freeBuffer(_ buf: UnsafeMutableRawPointer) {
        pmux_free_buffer(dso, buf)
    }

    // MARK: - Log

    func setLogCallback(_ callback: pmux_log_cb, opaque: UnsafeMutableRawPointer? = nil) {
        pmux_set_log_callback(dso, callback, opaque)
    }
}

enum ParsecError: Error, LocalizedError {
    case initFailed(code: Int32)
    case connectFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .initFailed(let c): return "ParsecInit failed: \(c)"
        case .connectFailed(let c): return "ParsecClientConnect failed: \(c)"
        }
    }
}
