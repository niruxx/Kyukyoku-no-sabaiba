-- assets/test/audio_test.lua
-- Standalone audio test script.
--
-- Run with:  cargo run -p hello -- --script test/audio_test.lua --network both
--
-- Tests three audio categories:
--   1. Background MUSIC  — looping ambient pad
--   2. Sound EFFECTS     — periodic click / pickup / footstep
--   3. SPATIAL AUDIO     — two 3D sound sources orbiting the listener
--
-- This test spawns audio entities DIRECTLY (no mod system) to isolate
-- and verify the audio pipeline end-to-end.

print("═══════════════════════════════════════════════")
print("  AUDIO TEST — Music / SFX / Spatial Demo")
print("═══════════════════════════════════════════════")

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------
local MUSIC_VOLUME   = 0.5
local SFX_VOLUME     = 0.9
local SPATIAL_VOLUME = 0.9
local ORBIT_RADIUS   = 8.0
local ORBIT_SPEED    = 0.5

------------------------------------------------------------------------
-- 1. SpatialListener on a Camera3d (the "ear")
------------------------------------------------------------------------
local listener = spawn({
    SpatialListener = {},
    Camera3d = {},
    Transform = {
        translation = { x = 0, y = 2, z = 0 },
    },
})
print("[AUDIO_TEST] ✓ SpatialListener + Camera3d spawned (entity " .. listener:id() .. ")")

------------------------------------------------------------------------
-- 2. Ambient light so the window isn't black
------------------------------------------------------------------------
spawn({
    DirectionalLight = {
        illuminance = 5000,
        shadows_enabled = true,
    },
    Transform = {
        translation = { x = 5, y = 10, z = 5 },
    },
})

------------------------------------------------------------------------
-- 3. MUSIC: Looping background music
------------------------------------------------------------------------
local music_asset = load_asset("modules/audio_test/tests/audio/music_ambient.wav")
print("[AUDIO_TEST] Music asset loaded: id=" .. tostring(music_asset))

local music_entity = spawn({
    AudioPlayer = music_asset,
    PlaybackSettings = {
        mode   = "Loop",
        volume = { Linear = MUSIC_VOLUME },
    },
})
print("[AUDIO_TEST] ✓ Music spawned (entity " .. music_entity:id() .. ", looping)")

------------------------------------------------------------------------
-- 4. SPATIAL: Hum source (looping, positioned in world)
------------------------------------------------------------------------
local hum_asset = load_asset("modules/audio_test/tests/audio/spatial_hum.wav")
local hum_entity = spawn({
    AudioPlayer = hum_asset,
    PlaybackSettings = {
        mode    = "Loop",
        volume  = { Linear = SPATIAL_VOLUME },
        spatial = true,
    },
    Transform = {
        translation = { x = ORBIT_RADIUS, y = 1.0, z = 0 },
    },
})
print("[AUDIO_TEST] ✓ Spatial hum spawned (entity " .. hum_entity:id() .. ")")

------------------------------------------------------------------------
-- 5. SPATIAL: Drip source (looping, positioned opposite)
------------------------------------------------------------------------
local drip_asset = load_asset("modules/audio_test/tests/audio/spatial_drip.wav")
local drip_entity = spawn({
    AudioPlayer = drip_asset,
    PlaybackSettings = {
        mode    = "Loop",
        volume  = { Linear = SPATIAL_VOLUME * 0.7 },
        spatial = true,
    },
    Transform = {
        translation = { x = -ORBIT_RADIUS, y = 0.5, z = 0 },
    },
})
print("[AUDIO_TEST] ✓ Spatial drip spawned (entity " .. drip_entity:id() .. ")")

------------------------------------------------------------------------
-- 6. State for SFX and orbit
------------------------------------------------------------------------
local state = define_resource("AudioTestState", {
    elapsed      = 0,
    sfx_timer    = 0,
    sfx_index    = 0,
    orbit_angle  = 0,
    click_asset  = load_asset("modules/audio_test/tests/audio/sfx_click.wav"),
    pickup_asset = load_asset("modules/audio_test/tests/audio/sfx_pickup.wav"),
    footstep_asset = load_asset("modules/audio_test/tests/audio/sfx_footstep.wav"),
    hum_id       = hum_entity:id(),
    drip_id      = drip_entity:id(),
    music_id     = music_entity:id(),
})

------------------------------------------------------------------------
-- 7. UPDATE: Orbit spatial sources + trigger periodic SFX
------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    state.elapsed = state.elapsed + dt
    state.orbit_angle = state.orbit_angle + ORBIT_SPEED * dt

    -- Orbit the spatial sources
    local angle = state.orbit_angle

    local hum = world:get_entity(state.hum_id)
    if hum then
        hum:patch({ Transform = { translation = {
            x = ORBIT_RADIUS * math.cos(angle),
            y = 1.0,
            z = ORBIT_RADIUS * math.sin(angle),
        }}})
    end

    local drip = world:get_entity(state.drip_id)
    if drip then
        drip:patch({ Transform = { translation = {
            x = ORBIT_RADIUS * math.cos(-angle + math.pi),
            y = 0.5,
            z = ORBIT_RADIUS * math.sin(-angle + math.pi),
        }}})
    end

    -- Trigger SFX every 2 seconds
    state.sfx_timer = state.sfx_timer + dt
    if state.sfx_timer >= 2.0 then
        state.sfx_timer = state.sfx_timer - 2.0
        state.sfx_index = state.sfx_index + 1

        local sfx_type = (state.sfx_index % 3) + 1
        local asset, name
        if sfx_type == 1 then
            asset = state.click_asset
            name = "click"
        elseif sfx_type == 2 then
            asset = state.pickup_asset
            name = "pickup"
        else
            asset = state.footstep_asset
            name = "footstep"
        end

        -- One-shot SFX entity (auto-despawns when done)
        spawn({
            AudioPlayer = asset,
            PlaybackSettings = {
                mode   = "Despawn",
                volume = { Linear = SFX_VOLUME },
            },
        })
        print(string.format("[AUDIO_TEST] ♪ SFX: %s (t=%.1fs)", name, state.elapsed))
    end

    -- Periodic status log
    if math.floor(state.elapsed) % 10 == 0 and state.sfx_timer < dt * 2 then
        print(string.format("[AUDIO_TEST] Still running... (%.0fs)", state.elapsed))
    end
end, { label = "AudioTest" })

print("")
print("═══════════════════════════════════════════════")
print("  Audio demo is running!")
print("  ♪ Music:    Looping ambient pad (global)")
print("  ♪ SFX:      Click/pickup/footstep every 2s")
print("  ♪ Spatial:  Hum + drip orbiting around you")
print("═══════════════════════════════════════════════")
