-- modules/audio_test/client/init.lua
-- Audio test mod: demonstrates music, sound effects, and spatial audio.
--
-- Spawns a self-contained audio demo when the "audio_test" component is
-- added to an entity.  Three categories are tested:
--
--   1. MUSIC      – Background ambient music (looping, global)
--   2. SFX        – One-shot sound effects triggered by timer
--   3. SPATIAL    – 3D positioned audio sources that orbit the listener
--
-- Usage:
--   spawn({ net_mod = { ["audio_test"] = {} } }):with_parent(some_entity)
--
-- Or standalone (non-networked):
--   spawn({ mod = { name = "audio_test", script = "modules/audio_test/client/init.lua" } })

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------
local MUSIC_VOLUME   = 0.4
local SFX_VOLUME     = 0.8
local SPATIAL_VOLUME  = 0.9
local ORBIT_RADIUS   = 8.0   -- spatial sources orbit at this radius
local ORBIT_SPEED    = 0.5   -- radians per second

------------------------------------------------------------------------
-- State tracking
------------------------------------------------------------------------
local state = define_resource("AudioTestState", {
    -- entity_id → { music_id, sfx_timer, spatial_ids, elapsed }
    instances = {},
})

------------------------------------------------------------------------
-- INIT: On added, spawn music + spatial sources
------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "audio_test" } })
    for _, entity in ipairs(entities) do
        local eid = entity:id()
        print(string.format("[AUDIO_TEST] Initializing audio demo on entity %d", eid))

        -- Read optional config overrides
        local cfg = entity:get("audio_test") or {}

        ---------------------------------------------------------------
        -- 1. MUSIC: Spawn a looping background music entity
        ---------------------------------------------------------------
        local music_asset = load_asset("audio/music_ambient.wav")
        local music_entity = spawn({
            AudioPlayer = music_asset,
            PlaybackSettings = {
                mode   = "Loop",
                volume = { Linear = cfg.music_volume or MUSIC_VOLUME },
            },
        }):with_parent(eid)
        print(string.format("[AUDIO_TEST]   ✓ Music spawned (entity %d)", music_entity:id()))

        ---------------------------------------------------------------
        -- 2. SPATIAL AUDIO: Spawn positioned sound sources
        ---------------------------------------------------------------
        -- Hum source (loops, positioned in world space)
        local hum_asset = load_asset("audio/spatial_hum.wav")
        local hum_entity = spawn({
            AudioPlayer = hum_asset,
            PlaybackSettings = {
                mode    = "Loop",
                volume  = { Linear = cfg.spatial_volume or SPATIAL_VOLUME },
                spatial = true,
            },
            Transform = {
                translation = { x = ORBIT_RADIUS, y = 1.0, z = 0 },
            },
        }):with_parent(eid)
        print(string.format("[AUDIO_TEST]   ✓ Spatial hum spawned (entity %d)", hum_entity:id()))

        -- Drip source (loops, positioned opposite to hum)
        local drip_asset = load_asset("audio/spatial_drip.wav")
        local drip_entity = spawn({
            AudioPlayer = drip_asset,
            PlaybackSettings = {
                mode    = "Loop",
                volume  = { Linear = (cfg.spatial_volume or SPATIAL_VOLUME) * 0.7 },
                spatial = true,
            },
            Transform = {
                translation = { x = -ORBIT_RADIUS, y = 0.5, z = 0 },
            },
        }):with_parent(eid)
        print(string.format("[AUDIO_TEST]   ✓ Spatial drip spawned (entity %d)", drip_entity:id()))

        ---------------------------------------------------------------
        -- 3. SFX: Preload assets; we'll spawn one-shot entities later
        ---------------------------------------------------------------
        local click_asset    = load_asset("audio/sfx_click.wav")
        local pickup_asset   = load_asset("audio/sfx_pickup.wav")
        local footstep_asset = load_asset("audio/sfx_footstep.wav")

        ---------------------------------------------------------------
        -- Store instance state
        ---------------------------------------------------------------
        state.instances[eid] = {
            music_id     = music_entity:id(),
            hum_id       = hum_entity:id(),
            drip_id      = drip_entity:id(),
            click_asset  = click_asset,
            pickup_asset = pickup_asset,
            footstep_asset = footstep_asset,
            elapsed      = 0,
            sfx_timer    = 0,
            sfx_index    = 0,
            orbit_angle  = 0,
        }

        -- Mark initialization complete
        entity:patch({ audio_test = {
            status      = "playing",
            music_id    = music_entity:id(),
            hum_id      = hum_entity:id(),
            drip_id     = drip_entity:id(),
        }})

        print("[AUDIO_TEST] ✓ Audio demo fully initialized!")
        print("[AUDIO_TEST]   - Background music (looping)")
        print("[AUDIO_TEST]   - Spatial hum (orbiting clockwise)")
        print("[AUDIO_TEST]   - Spatial drip (orbiting counter-clockwise)")
        print("[AUDIO_TEST]   - SFX: click/pickup/footstep every 2s")
    end
end)

------------------------------------------------------------------------
-- UPDATE: Orbit spatial sources + trigger periodic SFX
------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    for eid, inst in pairs(state.instances) do
        local entity = world:get_entity(eid)
        if not entity then
            -- Owner despawned; clean up tracking
            state.instances[eid] = nil
            goto continue
        end

        inst.elapsed = inst.elapsed + dt
        inst.orbit_angle = inst.orbit_angle + ORBIT_SPEED * dt

        -------------------------------------------------------------------
        -- Orbit the spatial sources around the parent
        -------------------------------------------------------------------
        local angle = inst.orbit_angle

        -- Hum orbits clockwise
        local hum = world:get_entity(inst.hum_id)
        if hum then
            hum:patch({ Transform = { translation = {
                x = ORBIT_RADIUS * math.cos(angle),
                y = 1.0,
                z = ORBIT_RADIUS * math.sin(angle),
            }}})
        end

        -- Drip orbits counter-clockwise (opposite direction)
        local drip = world:get_entity(inst.drip_id)
        if drip then
            drip:patch({ Transform = { translation = {
                x = ORBIT_RADIUS * math.cos(-angle + math.pi),
                y = 0.5,
                z = ORBIT_RADIUS * math.sin(-angle + math.pi),
            }}})
        end

        -------------------------------------------------------------------
        -- Trigger a one-shot SFX every 2 seconds (cycles through 3 types)
        -------------------------------------------------------------------
        inst.sfx_timer = inst.sfx_timer + dt
        if inst.sfx_timer >= 2.0 then
            inst.sfx_timer = inst.sfx_timer - 2.0
            inst.sfx_index = inst.sfx_index + 1

            local sfx_type = (inst.sfx_index % 3) + 1
            local asset, name
            if sfx_type == 1 then
                asset = inst.click_asset
                name = "click"
            elseif sfx_type == 2 then
                asset = inst.pickup_asset
                name = "pickup"
            else
                asset = inst.footstep_asset
                name = "footstep"
            end

            -- Spawn a one-shot audio entity that auto-despawns when done
            spawn({
                AudioPlayer = asset,
                PlaybackSettings = {
                    mode   = "Despawn",
                    volume = { Linear = SFX_VOLUME },
                },
            }):with_parent(eid)

            print(string.format("[AUDIO_TEST] ♪ SFX: %s (t=%.1fs)", name, inst.elapsed))
        end

        ::continue::
    end
end, { label = "AudioTest" })

------------------------------------------------------------------------
-- CLEANUP: When audio_test component is removed, clean up state
------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    local removed = world:query({
        ["or"] = { removed = { "audio_test" } },
    })
    for _, entity in ipairs(removed) do
        local eid = entity:id()
        if state.instances[eid] then
            print(string.format("[AUDIO_TEST] Cleaning up audio for entity %d", eid))
            state.instances[eid] = nil
        end
    end
end)
