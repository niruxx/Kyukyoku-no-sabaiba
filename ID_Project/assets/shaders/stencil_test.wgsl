// Stencil Test Shader — renders only where stencil passes
//
// This fragment shader is used by StencilTestMaterial.
// The pipeline specialization configures a stencil test (Equal),
// so fragments only execute where the stencil buffer was previously
// written by StencilWriteMaterial (i.e., within the portal frame).
//
// This shader renders a simple colored surface. For full PBR lighting
// on "other side" entities, you would import bevy_pbr::pbr_fragment.

struct StencilTestUniforms {
    base_color: vec4<f32>,
};

@group(2) @binding(0)
var<uniform> material: StencilTestUniforms;

#import bevy_pbr::forward_io::VertexOutput

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    // The stencil test in the pipeline ensures this only executes
    // within the portal mask. Output the material's base color.
    return material.base_color;
}
