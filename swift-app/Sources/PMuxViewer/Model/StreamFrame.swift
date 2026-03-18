/// StreamFrame — Per-stream NV12/RGBA frame data with Metal textures.
/// No CPU conversion for NV12 — GPU does YUV→RGB in the fragment shader.

import Metal

final class StreamFrame {
    var yTex: MTLTexture?
    var uvTex: MTLTexture?
    var width: Int = 0
    var height: Int = 0
    var fullWidth: Int = 0
    var fullHeight: Int = 0
    var hasFrame: Bool = false
    var format: UInt32 = 0

    // For non-NV12 formats, CPU-converted RGBA texture
    var rgbaTex: MTLTexture?
    var rgbaPixels: UnsafeMutablePointer<UInt8>?
    deinit { rgbaPixels?.deallocate() }
}
