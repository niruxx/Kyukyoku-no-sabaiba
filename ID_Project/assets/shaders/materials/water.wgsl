// Water shader — clean port from Unreal Engine MaterialTemplate.usf
// Requires: texture_0 (normal map), texture_1 (sparkle map)
// Uses depth prepass for depth-fade colour, edge foam, and opacity fade
//
// Parameter layout (8 × vec4):
//   water_colour:    WaterColour.rgb, WaterRoughness
//   depth_colour:    DepthFadeColour.rgb, FresnelExpo
//   foam_colour:     FoamColour.rgb, FresnelColourSubtractAmount
//   wave_params:     NormalWaveSpeed, NormalWaveScale, NormalWaveStrength, NormalRefractionStrength
//   foam_params:     EdgeFoamThreshold, FoamOutDistance, AmountOfFoamLines, SpeedOfFoamLines
//   sparkle_params:  FlashMovingSpeed, WaterSparklesScale, ShineLimit, FlashStrength
//   opacity_params:  WaterDefaultOpac, MinTransparency, FadeDistance, DepthFadeContrast
//   misc_params:     RefractionAmount, FoamBitsSpeed, FoamBitsScale, AmountOfFoamBits

#import bevy_pbr::mesh_view_bindings::globals
#import bevy_pbr::mesh_view_bindings::view
#import bevy_pbr::prepass_utils

// Texture bindings — declared here because naga_oil does NOT expose
// dispatcher-scope globals to imported variant module functions.
@group(#{MATERIAL_BIND_GROUP}) @binding(1) var texture_0: texture_2d<f32>;
@group(#{MATERIAL_BIND_GROUP}) @binding(2) var material_sampler_0: sampler;
@group(#{MATERIAL_BIND_GROUP}) @binding(3) var texture_1: texture_2d<f32>;
@group(#{MATERIAL_BIND_GROUP}) @binding(4) var material_sampler_1: sampler;

// ──────────────────────────────────────────────────────────────
// Vertex (buoyancy disabled — all 8 param slots used by fragment)
// ──────────────────────────────────────────────────────────────
fn vertex(
    world_pos: vec3<f32>,
    world_normal: vec3<f32>,
    water_colour: vec4<f32>, depth_colour: vec4<f32>, foam_colour: vec4<f32>,
    wave_params: vec4<f32>,  foam_params: vec4<f32>,  sparkle_params: vec4<f32>,
    opacity_params: vec4<f32>, misc_params: vec4<f32>,
) -> vec3<f32> {
    return vec3<f32>(0.0, 0.0, 0.0);
}

// ──────────────────────────────────────────────────────────────
// Smooth 2-D value noise  (replaces UE MaterialExpressionNoise)
// ──────────────────────────────────────────────────────────────
fn hash_2d(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);           // smoothstep
    let a = hash_2d(i);
    let b = hash_2d(i + vec2<f32>(1.0, 0.0));
    let c = hash_2d(i + vec2<f32>(0.0, 1.0));
    let d = hash_2d(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 3-D vector noise (replaces UE MaterialExpressionVectorNoise for foam warp)
fn vector_noise_3d(p: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        value_noise(p.xz) * 2.0 - 1.0,
        value_noise(p.xz + vec2<f32>(17.3, 43.7)) * 2.0 - 1.0,
        value_noise(p.xz + vec2<f32>(89.1, 113.5)) * 2.0 - 1.0,
    );
}

// ──────────────────────────────────────────────────────────────
// Fragment
// ──────────────────────────────────────────────────────────────
fn fragment(
    in: bevy_pbr::forward_io::VertexOutput,
    water_colour: vec4<f32>, depth_colour: vec4<f32>, foam_colour: vec4<f32>,
    wave_params: vec4<f32>,  foam_params: vec4<f32>,  sparkle_params: vec4<f32>,
    opacity_params: vec4<f32>, misc_params: vec4<f32>,
) -> vec4<f32> {
    let t  = globals.time;
    let wp = in.world_position.xyz;

    // ── Unpack parameters ────────────────────────────────────
    let water_col            = water_colour.rgb;
    let water_roughness      = water_colour.a;
    let depth_fade_col       = depth_colour.rgb;
    let fresnel_expo         = depth_colour.a;
    let foam_col             = foam_colour.rgb;
    let fresnel_col_subtract = foam_colour.a;

    let normal_wave_speed    = wave_params.x;
    let normal_wave_scale    = max(wave_params.y, 0.0001);
    let normal_wave_strength = wave_params.z;
    let refraction_strength  = wave_params.w;

    let edge_foam_threshold  = max(foam_params.x, 0.0001);
    let foam_out_dist        = max(foam_params.y, 0.0001);
    let amount_of_foam_lines = foam_params.z;
    let speed_of_foam_lines  = foam_params.w;

    let flash_speed          = sparkle_params.x;
    let sparkle_scale        = max(sparkle_params.y, 0.0001);
    let shine_limit          = sparkle_params.z;
    let flash_strength       = sparkle_params.w;

    let water_default_opac   = opacity_params.x;
    let min_transparency     = opacity_params.y;
    let fade_distance        = max(opacity_params.z, 0.0001);
    let depth_fade_contrast  = opacity_params.w;

    let refraction_amount    = misc_params.x;
    let foam_bits_speed      = misc_params.y;
    let foam_bits_scale      = max(misc_params.z, 0.0001);
    let amount_of_foam_bits  = misc_params.w;

    // ═════════════════════════════════════════════════════════
    // 1. Normal Waves  (UE Local0-20)
    //    Two normal-map samples with animated world-XZ UVs,
    //    blended and scaled by NormalWaveStrength → saturated
    // ═════════════════════════════════════════════════════════
    let uv_base = wp.xz / normal_wave_scale;
    let uv1 = uv_base + t * vec2<f32>(-0.1, 0.3) * normal_wave_speed;
    let uv2 = uv_base + t * vec2<f32>( 0.2, -0.1) * normal_wave_speed;
    let n1 = textureSample(texture_0, material_sampler_0, fract(uv1)).rg * 2.0 - 1.0;
    let n2 = textureSample(texture_0, material_sampler_0, fract(uv2)).rg * 2.0 - 1.0;
    let blended_xy = clamp(
        (n1 + n2) * normal_wave_strength,
        vec2<f32>(-1.0), vec2<f32>(1.0),
    );
    let perturbed_normal = normalize(in.world_normal + vec3<f32>(
        blended_xy.x * refraction_strength,
        0.0,
        blended_xy.y * refraction_strength,
    ));

    // ═════════════════════════════════════════════════════════
    // 2. Sparkle / Shine  (UE Local21-39)
    //    Two sparkle-texture samples; sum ≥ threshold → flash
    // ═════════════════════════════════════════════════════════
    let suv = wp.xz / sparkle_scale;
    let s1 = textureSample(texture_1, material_sampler_1,
        fract(suv + t * vec2<f32>(0.03, 0.005) * flash_speed)).r;
    let s2 = textureSample(texture_1, material_sampler_1,
        fract(suv + t * vec2<f32>(0.001, -0.002) * flash_speed)).r;
    let sparkle_val    = s1 + s2;
    let shine_present  = select(0.0, 1.0, sparkle_val >= shine_limit);
    let flash_emissive = shine_present * flash_strength;

    // ═════════════════════════════════════════════════════════
    // 3. Depth sampling  (depth prepass)
    //    UE uses SceneDepth−PixelDepth for colour/opacity and
    //    GetDistanceToNearestSurfaceGlobal (SDF) for foam.
    //    Bevy has no SDF, so depth_diff drives both systems.
    // ═════════════════════════════════════════════════════════
#ifdef DEPTH_PREPASS
    let scene_ndc     = prepass_utils::prepass_depth(in.position, 0u);
    let near          = view.clip_from_view[3][2];
    let scene_linear  = near / max(scene_ndc, 0.0001);
    let frag_linear   = near / max(in.position.z, 0.0001);
    let depth_diff    = max(scene_linear - frag_linear, 0.0);
#else
    let depth_diff    = 1000.0;
#endif

    // ═════════════════════════════════════════════════════════
    // 4. Foam  (noise-threshold technique)
    //    Depth gradient modulates a cutoff against animated noise.
    //    Near intersection: cutoff low → lots of foam.
    //    Far away: cutoff high → foam fades to nothing.
    //    Animated sine rings sweep outward from the intersection.
    // ═════════════════════════════════════════════════════════

    // 4a. Normalised depth gradient: 0 at intersection, 1 at foam_out_dist
    let foam_gradient = clamp(depth_diff / foam_out_dist, 0.0, 1.0);

    // 4b. Animated foam noise — two octaves with panning UVs
    let foam_uv = wp.xz / foam_bits_scale;
    let foam_n1 = value_noise(foam_uv * 6.0 + t * vec2<f32>( 0.12, -0.08) * foam_bits_speed);
    let foam_n2 = value_noise(foam_uv * 4.0 + t * vec2<f32>(-0.09,  0.14) * foam_bits_speed);
    let foam_tex = (foam_n1 + foam_n2) * 0.5;

    // 4c. Animated concentric rings sweeping outward
    //     sin((gradient - time * speed) * lines * 2π) → rings move away from intersection
    //     × (1 - gradient) → rings fade with distance
    let rings = clamp(
        sin((foam_gradient - t * speed_of_foam_lines) * amount_of_foam_lines * 6.28318),
        0.0, 1.0,
    );
    let ring_contribution = rings * (1.0 - foam_gradient);

    // 4d. Threshold = gradient lowered by rings → more foam where rings are
    //     (matches Unity water.unity: step(foamDiff - ring, foamTex))
    let threshold = foam_gradient - ring_contribution;

    // 4e. Hard edge right at the intersection line
    let edge_foam = 1.0 - smoothstep(0.0, edge_foam_threshold, depth_diff);

    // 4f. Combine: noise exceeds threshold → foam, plus hard edge
    let noise_foam = smoothstep(threshold - 0.02, threshold + 0.02, foam_tex);
    let foam_raw = max(noise_foam * (1.0 - foam_gradient), edge_foam);

    // 4g. Floating foam bits — only near intersections (gated by proximity)
    let bits_uv = wp.xz / foam_bits_scale;
    let b1 = value_noise(bits_uv + t * vec2<f32>( 0.17, -0.12) * foam_bits_speed);
    let b2 = value_noise(bits_uv + t * vec2<f32>(-0.17, -0.12) * foam_bits_speed);
    let b3 = value_noise(bits_uv + t * vec2<f32>(  0.0,  0.24) * foam_bits_speed);
    let foam_bits = clamp((b1 + b2 + b3) / 3.0 - amount_of_foam_bits, 0.0, 1.0)
                  * (1.0 - foam_gradient);  // suppress far from intersections

    let foam_mask = clamp(foam_raw + foam_bits, 0.0, 1.0);

    // ═════════════════════════════════════════════════════════
    // 5. Depth-fade colour  (UE Local96-103)
    //    Shallow water → depth_fade_col, deep → water_col
    // ═════════════════════════════════════════════════════════
    let depth_t = clamp(depth_diff / fade_distance, 0.0, 1.0);
    let depth_contrasted = clamp(
        mix(-depth_fade_contrast, depth_fade_contrast + 1.0, depth_t),
        0.0, 1.0,
    );
    let base_col = mix(depth_fade_col, water_col, depth_contrasted);

    // ═════════════════════════════════════════════════════════
    // 6. Fresnel colour darkening  (UE Local105-113)
    // ═════════════════════════════════════════════════════════
    let view_dir   = normalize(view.world_position.xyz - wp);
    let n_dot_v    = max(dot(perturbed_normal, view_dir), 0.0);
    let fresnel_in = max(abs(1.0 - n_dot_v), 0.0001);
    let fresnel    = pow(fresnel_in, fresnel_expo);

    let darker_col  = base_col - vec3<f32>(fresnel_col_subtract);
    let fresnel_col = mix(base_col, darker_col, fresnel);
    var final_color = mix(fresnel_col, foam_col, foam_mask);

    // ═════════════════════════════════════════════════════════
    // 7. Emissive sparkles, masked by foam  (UE Local94-95)
    // ═════════════════════════════════════════════════════════
    final_color += vec3<f32>(flash_emissive * (1.0 - foam_mask));

    // ═════════════════════════════════════════════════════════
    // 8. Opacity  (UE Local115-128)
    //    Foam is always opaque; water fades with depth
    // ═════════════════════════════════════════════════════════
    let opacity_raw = mix(water_default_opac, 1.0, foam_mask);
    let opacity     = clamp(opacity_raw, min_transparency, 1.0);

    // ═════════════════════════════════════════════════════════
    // 9. Refraction  (UE Local134-143, Schlick Fresnel)
    // ═════════════════════════════════════════════════════════
    let ref_n   = normalize(vec3<f32>(blended_xy * refraction_strength, 1.0));
    let ref_dot = max(abs(1.0 - max(dot(ref_n, view_dir), 0.0)), 0.0001);
    let schlick = ref_dot * (1.0 - 0.04) + 0.04;
    final_color = final_color * mix(1.0, refraction_amount, schlick);

    return vec4<f32>(final_color, opacity);
}
