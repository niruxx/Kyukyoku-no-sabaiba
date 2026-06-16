// Energy/plasma shader variant for DynamicMaterial
//
// base_color = base color (rgba)
// pulse_params.x = pulse_speed, .y = pulse_intensity, .z = glow_strength
// secondary_color = secondary color (rgba)

#import bevy_pbr::mesh_view_bindings::globals
#import bevy_pbr::mesh_view_bindings::view

fn fragment(in: bevy_pbr::forward_io::VertexOutput, base_color: vec4<f32>, pulse_params: vec4<f32>, secondary_color: vec4<f32>, p3: vec4<f32>, p4: vec4<f32>, p5: vec4<f32>, p6: vec4<f32>, p7: vec4<f32>) -> vec4<f32> {
    let pulse_speed = pulse_params.x;
    let pulse_intensity = pulse_params.y;
    let glow_strength = pulse_params.z;

    let time = globals.time;

    // Pulsing emissive glow
    let pulse = sin(time * pulse_speed) * 0.5 + 0.5;
    let pulse2 = sin(time * pulse_speed * 1.7 + 1.5) * 0.5 + 0.5;

    // Fresnel rim lighting for energy effect
    let view_dir = normalize(in.world_position.xyz - view.world_position);
    let fresnel = pow(1.0 - abs(dot(normalize(in.world_normal), -view_dir)), 3.0);

    // Plasma pattern using world-space coordinates
    let plasma1 = sin(in.world_position.x * 4.0 + time * 2.0);
    let plasma2 = sin(in.world_position.y * 3.0 + time * 1.5);
    let plasma3 = sin((in.world_position.x + in.world_position.y) * 2.0 + time * 3.0);
    let plasma = (plasma1 + plasma2 + plasma3) / 3.0 * 0.5 + 0.5;

    // Mix base and secondary color using plasma pattern
    var color = mix(base_color, secondary_color, plasma);

    // Add pulsing brightness
    color = color * (1.0 + pulse * pulse_intensity);

    // Add fresnel rim glow
    let rim_glow = fresnel * glow_strength;
    color = color + vec4<f32>(rim_glow, rim_glow * 0.8, rim_glow * 1.2, 0.0);

    // Emissive boost (make it glow beyond 1.0 for bloom)
    color = color * (1.0 + pulse2 * 0.5);

    color.a = base_color.a;
    return color;
}
