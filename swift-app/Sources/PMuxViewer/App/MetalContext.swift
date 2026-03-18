/// MetalContext — Shared Metal device, command queue, and render pipelines.
/// One instance shared across all SingleStreamMTKViews.

import Metal

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VSOut vs(uint vid [[vertex_id]],
               constant float4 *rects [[buffer(0)]]) {
    float4 r = rects[0];
    float4 t = rects[1];
    float2 corners[] = { float2(r.x,r.y), float2(r.z,r.y), float2(r.x,r.w), float2(r.z,r.w) };
    float2 uvs[]     = { float2(t.x,t.w), float2(t.z,t.w), float2(t.x,t.y), float2(t.z,t.y) };
    VSOut o;
    o.pos = float4(corners[vid], 0, 1);
    o.uv  = uvs[vid];
    return o;
}

// NV12 -> RGB (BT.709) on GPU
fragment float4 fs_nv12(VSOut in [[stage_in]],
                        texture2d<float> yTex  [[texture(0)]],
                        texture2d<float> uvTex [[texture(1)]]) {
    constexpr sampler s(filter::linear);
    float y  = yTex.sample(s, in.uv).r;
    float2 uv = uvTex.sample(s, in.uv).rg;

    float Y  = (y  - 0.0625) * 1.1644;
    float Cb = uv.r - 0.5;
    float Cr = uv.g - 0.5;
    float R = Y + 1.7928 * Cr;
    float G = Y - 0.2133 * Cb - 0.5330 * Cr;
    float B = Y + 2.1124 * Cb;
    return float4(R, G, B, 1.0);
}

// Pre-converted RGBA texture
fragment float4 fs_rgba(VSOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return tex.sample(s, in.uv);
}

// Solid color (overlays, borders)
fragment float4 fs_solid(VSOut in [[stage_in]],
                         constant float4 &color [[buffer(0)]]) {
    return color;
}
"""

final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineNV12: MTLRenderPipelineState
    let pipelineRGBA: MTLRenderPipelineState
    let pipelineSolid: MTLRenderPipelineState

    enum MetalError: Error, LocalizedError {
        case metalNotAvailable
        var errorDescription: String? { "Metal is not available on this device" }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.metalNotAvailable
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        func makePipeline(_ fragName: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: fragName)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }

        pipelineNV12  = try makePipeline("fs_nv12")
        pipelineRGBA  = try makePipeline("fs_rgba")
        pipelineSolid = try makePipeline("fs_solid")
    }
}
