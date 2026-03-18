/// SingleStreamMTKView — MTKView that renders ONE Parsec stream via PollFrame + Metal.
/// Each session pane gets its own instance. No grid logic, no overlays.

import AppKit
import Metal
import MetalKit
import CParsecBridge

final class SingleStreamMTKView: MTKView, MTKViewDelegate {
    weak var client: ParsecClient?
    var metalContext: MetalContext?
    let streamFrame = StreamFrame()
    var isActivePane: Bool = true {
        didSet { preferredFramesPerSecond = isActivePane ? 60 : 15 }
    }
    var lastRenderStatus: Int32 = -1

    // Aspect-fit rect in clip space (for mouse mapping)
    private(set) var fittedRect: (x0: Float, y0: Float, x1: Float, y1: Float) = (-1, -1, 1, 1)

    // Callbacks
    var onFrameRendered: (() -> Void)?

    private var frameCount: UInt64 = 0
    private var fpsCounter: UInt64 = 0
    private var fpsLastTime: CFAbsoluteTime = 0
    private(set) var currentFPS: Float = 0

    func setup(context: MetalContext) {
        self.metalContext = context
        self.device = context.device
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.098, green: 0.106, blue: 0.118, alpha: 1)
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        fpsLastTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        syncDimensions()
    }

    /// Call setDimensions on the client to match this view's current size.
    /// Safe to call at any time — guards against nil client or zero size.
    func syncDimensions() {
        guard let client = client else { return }
        let w = bounds.size.width, h = bounds.size.height
        guard w > 0 && h > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        print("[dim] setDimensions \(Int(w))x\(Int(h)) scale=\(scale)")
        client.setDimensions(width: UInt32(w), height: UInt32(h), scale: Float(scale))
    }

    func draw(in view: MTKView) {
        pollFrameGPU()

        guard let context = metalContext,
              let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cb = context.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        drawStream(enc: enc)

        fpsCounter += 1; frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsLastTime >= 1.0 {
            currentFPS = Float(fpsCounter) / Float(now - fpsLastTime)
            fpsCounter = 0; fpsLastTime = now
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        onFrameRendered?()
    }

    // MARK: - Frame Polling

    private struct PollCtx {
        let sf: StreamFrame
        let dev: MTLDevice
    }

    private func pollFrameGPU() {
        guard let client = client, let dev = device else { return }

        var ctx = PollCtx(sf: streamFrame, dev: dev)
        let status = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            pmux_poll_frame(client.dsoHandle, 0, { frame, image, opaque in
                guard let frame = frame, let image = image, let opaque = opaque else { return }
                let ctx = opaque.assumingMemoryBound(to: PollCtx.self).pointee
                let f = frame.pointee
                let sf = ctx.sf
                let dev = ctx.dev

                sf.width = Int(f.width); sf.height = Int(f.height)
                sf.fullWidth = Int(f.fullWidth); sf.fullHeight = Int(f.fullHeight)
                sf.format = f.format.rawValue
                sf.hasFrame = true

                let w = sf.width, h = sf.height, fw = sf.fullWidth, fh = sf.fullHeight
                let src = image.assumingMemoryBound(to: UInt8.self)

                if f.format.rawValue == 1 { // NV12 — upload Y and UV planes directly
                    if sf.yTex == nil || sf.yTex!.width != fw || sf.yTex!.height != fh {
                        let d = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .r8Unorm, width: fw, height: fh, mipmapped: false)
                        d.usage = [.shaderRead]
                        sf.yTex = dev.makeTexture(descriptor: d)
                    }
                    sf.yTex?.replace(region: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0,
                                     withBytes: src, bytesPerRow: fw)

                    let uvW = fw / 2, uvH = fh / 2
                    if sf.uvTex == nil || sf.uvTex!.width != uvW || sf.uvTex!.height != uvH {
                        let d = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .rg8Unorm, width: uvW, height: uvH, mipmapped: false)
                        d.usage = [.shaderRead]
                        sf.uvTex = dev.makeTexture(descriptor: d)
                    }
                    sf.uvTex?.replace(region: MTLRegionMake2D(0, 0, uvW, uvH), mipmapLevel: 0,
                                      withBytes: src + fw * fh, bytesPerRow: fw)
                } else { // BGRA/RGBA CPU fallback
                    if sf.rgbaTex == nil || sf.rgbaTex!.width != w || sf.rgbaTex!.height != h {
                        sf.rgbaPixels?.deallocate()
                        sf.rgbaPixels = .allocate(capacity: w * h * 4)
                        let d = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
                        d.usage = [.shaderRead]
                        sf.rgbaTex = dev.makeTexture(descriptor: d)
                    }
                    if let dst = sf.rgbaPixels {
                        if f.format.rawValue == 5 { // BGRA
                            for row in 0..<h {
                                let sp = src + row * fw * 4, dp = dst + row * w * 4
                                for col in 0..<w {
                                    dp[col*4]=sp[col*4+2]; dp[col*4+1]=sp[col*4+1]
                                    dp[col*4+2]=sp[col*4]; dp[col*4+3]=255
                                }
                            }
                        } else {
                            for row in 0..<h { memcpy(dst + row * w * 4, src + row * fw * 4, w * 4) }
                        }
                        sf.rgbaTex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                            withBytes: dst, bytesPerRow: w * 4)
                    }
                }
            }, 0, ctxPtr)
        }
        lastRenderStatus = status
    }

    // MARK: - Rendering

    private func drawStream(enc: MTLRenderCommandEncoder) {
        guard let context = metalContext else { return }
        let sf = streamFrame
        guard sf.hasFrame else { return }

        let vw = Float(drawableSize.width)
        let vh = Float(drawableSize.height)
        let fit = aspectFitRect(streamW: sf.width, streamH: sf.height, viewW: vw, viewH: vh)
        fittedRect = fit

        let uMax = sf.width > 0 && sf.fullWidth > 0 ? Float(sf.width) / Float(sf.fullWidth) : 1.0
        let vMax = sf.height > 0 && sf.fullHeight > 0 ? Float(sf.height) / Float(sf.fullHeight) : 1.0

        if sf.format == 1, let yTex = sf.yTex, let uvTex = sf.uvTex {
            enc.setRenderPipelineState(context.pipelineNV12)
            var rects: [SIMD4<Float>] = [SIMD4(fit.x0, fit.y0, fit.x1, fit.y1), SIMD4(0, 0, uMax, vMax)]
            enc.setVertexBytes(&rects, length: 32, index: 0)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(uvTex, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else if let tex = sf.rgbaTex {
            enc.setRenderPipelineState(context.pipelineRGBA)
            var rects: [SIMD4<Float>] = [SIMD4(fit.x0, fit.y0, fit.x1, fit.y1), SIMD4(0, 0, 1, 1)]
            enc.setVertexBytes(&rects, length: 32, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Calculate letterboxed rect preserving stream aspect ratio within clip space (-1..1)
    private func aspectFitRect(streamW: Int, streamH: Int,
                                viewW: Float, viewH: Float) -> (x0: Float, y0: Float, x1: Float, y1: Float) {
        guard streamW > 0 && streamH > 0 && viewW > 0 && viewH > 0 else { return (-1, -1, 1, 1) }

        let streamAR = Float(streamW) / Float(streamH)
        let viewAR = viewW / viewH

        var fitW: Float, fitH: Float
        if streamAR > viewAR {
            fitW = 2.0
            fitH = fitW * (viewW / viewH) / streamAR
        } else {
            fitH = 2.0
            fitW = fitH * streamAR * (viewH / viewW)
        }

        return (-fitW/2, -fitH/2, fitW/2, fitH/2)
    }

    var streamFrameSize: (w: Int, h: Int) {
        (streamFrame.width, streamFrame.height)
    }
}
