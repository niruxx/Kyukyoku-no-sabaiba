// Stencil Write Shader — portal mask
//
// This fragment shader is used by StencilWriteMaterial.
// Color writes are disabled in the pipeline, so the output color is irrelevant.
// The fragment must NOT discard — we need it to pass through so the
// stencil DepthStencilState replace op actually fires.

#import bevy_pbr::forward_io::VertexOutput

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    // Color writes are disabled in the pipeline specialization,
    // so this value never appears on screen. We output a dummy value
    // to ensure the fragment passes and triggers the stencil replace op.
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
