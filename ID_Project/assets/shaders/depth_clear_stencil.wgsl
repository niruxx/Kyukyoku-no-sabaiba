// Depth-clear fullscreen triangle shader for portal rendering.
//
// Renders a fullscreen triangle that writes far-depth (0.0 in reversed-Z)
// to the depth buffer, but ONLY where the stencil buffer matches the
// portal's stencil reference value. No color output.
//
// This clears the depth inside the portal mask so "other side" entities
// are not occluded by "this side" geometry at the same positions.

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
}

// Fullscreen triangle: 3 vertices that cover the entire screen
// Vertex IDs 0, 1, 2 produce a triangle covering clip space [-1,1]
@vertex
fn vertex(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var output: VertexOutput;
    // Generate fullscreen triangle vertices from vertex index
    let x = f32(i32(vertex_index & 1u) * 4 - 1);
    let y = f32(i32(vertex_index >> 1u) * 4 - 1);
    output.position = vec4<f32>(x, y, 0.0, 1.0);
    return output;
}

// Fragment outputs far-depth (0.0 in Bevy's reversed-Z).
// The pipeline's stencil Equal test ensures this only writes
// where the portal mask was stamped.
@fragment
fn fragment() -> @builtin(frag_depth) f32 {
    return 0.0; // Far plane in reversed-Z
}
