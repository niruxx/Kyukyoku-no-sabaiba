// Dissolve shader variant for DynamicMaterial
//
// base_color = base color (rgba)
// edge_color = edge glow color (rgba)
// threshold.x = threshold (0=fully visible, 1=fully dissolved)
// threshold.y = edge_width
// threshold.z = noise_scale

#import bevy_pbr::mesh_view_bindings::globals

// Simple hash-based noise (no texture needed)
fn hash(p: vec2<f32>) -> f32 {
    var h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);

    let a = hash(i);
    let b = hash(i + vec2<f32>(1.0, 0.0));
    let c = hash(i + vec2<f32>(0.0, 1.0));
    let d = hash(i + vec2<f32>(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    var value = 0.0;
    var amplitude: f32 = 0.5;
    var pos = p;
    for (var i = 0; i < 4; i++) {
        value += amplitude * noise(pos);
        pos *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

fn fragment(in: bevy_pbr::forward_io::VertexOutput, base_color: vec4<f32>, edge_color: vec4<f32>, threshold: vec4<f32>, p3: vec4<f32>, p4: vec4<f32>, p5: vec4<f32>, p6: vec4<f32>, p7: vec4<f32>) -> vec4<f32> {
    let threshold_val = threshold.x;
    let edge_width = threshold.y;
    let noise_scale = threshold.z;

    // Generate noise from world position for 3D consistency
    let noise_pos = in.world_position.xz * noise_scale + in.world_position.y * 0.5;
    let noise_val = fbm(noise_pos);

    // Discard pixels below threshold (dissolve effect)
    if noise_val < threshold_val {
        discard;
    }

    // Glowing edge at dissolve boundary
    let edge_factor = smoothstep(threshold_val, threshold_val + edge_width, noise_val);
    let edge_glow = (1.0 - edge_factor) * step(threshold_val, noise_val);

    // Mix base color with edge glow
    var color = mix(edge_color * 3.0, base_color, edge_factor);

    // Add some animated sparkle near the edge
    let time = globals.time;
    let sparkle = sin(noise_val * 50.0 + time * 10.0) * 0.5 + 0.5;
    color = color + edge_color * edge_glow * sparkle * 2.0;

    color.a = base_color.a;
    return color;
}
