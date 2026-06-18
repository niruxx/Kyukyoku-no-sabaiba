-- modules/weapons/client/init.lua
-- Client-side weapons: Q=Rail Gun, E=Explosives, R=Nova.
-- Enforces cooldowns client-side before spawning predicted entities.
-- Handles all weapon/FX animations: bolt rotation, grenade pulse, nova
-- expand/fade, muzzle flashes, explosion rings.

local BINDINGS = require("modules/weapons/shared/bindings.lua")

---------------------------------------------------------------------------
-- Shared cooldown resource (also read by hud/client for the cooldown bars)
---------------------------------------------------------------------------
local cd = define_resource("ClientWeaponCooldowns", {
    elapsed    = 0.0,
    last_fired = { railgun = -999.0, explosives = -999.0, nova = -999.0 },
    cooldowns  = { railgun = 0.5,    explosives = 2.5,    nova  = 8.0   },
})

---------------------------------------------------------------------------
-- Module-local animation tables (never synced to server)
---------------------------------------------------------------------------
local proj_anims        = {}   -- [entity_id] → { timer, visual_id, kind }
local nova_visuals      = {}   -- [entity_id] → { vis_id, full_size }
local explosion_visuals = {}   -- [entity_id] → { vis_id, total_lifetime, radius }
local flash_timers      = {}   -- [flash_entity_id] → { timer, total, base_size }

---------------------------------------------------------------------------
-- Elapsed time counter (owned here; hud/client reads from the shared resource)
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    cd.elapsed = cd.elapsed + world:delta_time()
end)

---------------------------------------------------------------------------
-- Init: register weapon input bindings on the player's input component
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "weapons" } })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { weapons = BINDINGS } })
        print(string.format("[WEAPONS/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Helper: facing direction → (vx, vy)
---------------------------------------------------------------------------
local function facing_to_vel(facing, speed)
    if     facing == "right" then return  speed, 0
    elseif facing == "left"  then return -speed, 0
    elseif facing == "up"    then return  0,  speed
    else                          return  0, -speed
    end
end

---------------------------------------------------------------------------
-- Helper: spawn a short-lived muzzle flash at world position
---------------------------------------------------------------------------
local function spawn_flash(x, y, z, size, r, g, b)
    local img   = load_asset("character-spritesheet.png")
    local flash = spawn({
        Transform = { translation = { x = x, y = y, z = z } },
        Sprite    = {
            image       = img,
            rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
            custom_size = { x = size, y = size },
            color       = { r = r, g = g, b = b, a = 1.0 },
        },
    })
    flash_timers[flash:id()] = { timer = 0.0, total = 0.10, base_size = size }
end

---------------------------------------------------------------------------
-- Weapon firing: client-side cooldown gate, predicted entity spawns
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with    = { "weapons", "Transform", "animation/sprite" },
        changed = { "input_weapons" },
    })

    for _, entity in ipairs(entities) do
        local ab = entity:get("input_weapons")
        if not ab then goto continue end

        local t = entity:get("Transform")
        if not t or not t.translation then goto continue end

        local anim   = entity:get("animation/sprite")
        local facing = (anim and anim.facing) or "down"
        local pos    = t.translation

        -- ── Rail Gun (Q) ─────────────────────────────────────────────────
        if ab.railgun then
            local name  = "railgun"
            local ready = cd.elapsed - cd.last_fired[name] >= cd.cooldowns[name]
            if ready then
                cd.last_fired[name] = cd.elapsed

                local vx, vy = facing_to_vel(facing, 420)
                local sx = vx ~= 0 and (vx > 0 and 1 or -1) or 0
                local sy = vy ~= 0 and (vy > 0 and 1 or -1) or 0

                spawn({
                    Transform      = { translation = { x = pos.x + sx*22, y = pos.y + sy*22, z = pos.z } },
                    RigidBody2d    = "Dynamic",
                    Collider2d     = { ball = { radius = 5.0 } },
                    Sensor2d       = {},
                    GravityScale2d = 0.0,
                    LockedAxes2d   = "ROTATION_LOCKED",
                    Velocity2d     = { linvel = { x = vx, y = vy }, angvel = 0 },
                    projectile     = { ability = "railgun" },
                    net_sync       = {
                        Transform  = { authority = "server", reliable = false },
                        Velocity2d = { authority = "server" },
                        projectile = { authority = "server" },
                    },
                })

                spawn_flash(pos.x + sx*30, pos.y + sy*30, pos.z + 1, 14, 0.3, 0.9, 1.0)
            end
        end

        -- ── Explosives Launcher (E) ───────────────────────────────────────
        if ab.explosives then
            local name  = "explosives"
            local ready = cd.elapsed - cd.last_fired[name] >= cd.cooldowns[name]
            if ready then
                cd.last_fired[name] = cd.elapsed

                local vx, vy = facing_to_vel(facing, 190)
                local sx = vx ~= 0 and (vx > 0 and 1 or -1) or 0
                local sy = vy ~= 0 and (vy > 0 and 1 or -1) or 0

                spawn({
                    Transform      = { translation = { x = pos.x + sx*22, y = pos.y + sy*22, z = pos.z } },
                    RigidBody2d    = "Dynamic",
                    Collider2d     = { ball = { radius = 8.0 } },
                    Sensor2d       = {},
                    GravityScale2d = 0.0,
                    LockedAxes2d   = "ROTATION_LOCKED",
                    Velocity2d     = { linvel = { x = vx, y = vy }, angvel = 0 },
                    projectile     = { ability = "explosives" },
                    net_sync       = {
                        Transform  = { authority = "server", reliable = false },
                        Velocity2d = { authority = "server" },
                        projectile = { authority = "server" },
                    },
                })

                spawn_flash(pos.x + sx*30, pos.y + sy*30, pos.z + 1, 20, 1.0, 0.55, 0.1)
            end
        end

        -- ── Nova Circle (R) ───────────────────────────────────────────────
        if ab.nova then
            local name  = "nova"
            local ready = cd.elapsed - cd.last_fired[name] >= cd.cooldowns[name]
            if ready then
                cd.last_fired[name] = cd.elapsed

                spawn({
                    Transform  = { translation = { x = pos.x, y = pos.y, z = pos.z } },
                    projectile = { ability = "nova" },
                    net_sync   = {
                        Transform  = { authority = "server" },
                        projectile = { authority = "server" },
                        nova_zone  = { authority = "server" },
                    },
                })
            end
        end

        ::continue::
    end
end, { label = "WeaponFire", after = { "Movement" } })

---------------------------------------------------------------------------
-- Projectile visuals: spawn sprite children for railgun and explosives
---------------------------------------------------------------------------
register_system("Update", function(world)
    local img = load_asset("character-spritesheet.png")

    for _, entity in ipairs(world:query({
        added   = { "projectile" },
        without = { "weapon_visual_spawned" },
    })) do
        local p = entity:get("projectile")
        if not p or not p.ability then goto continue end

        if p.ability == "railgun" then
            -- Elongated bolt rotated to face velocity
            local vel   = entity:get("Velocity2d")
            local vx    = (vel and vel.linvel and vel.linvel.x) or 0
            local vy    = (vel and vel.linvel and vel.linvel.y) or 0
            local angle = math.atan2(vy, vx)
            local rot   = world:call_static_method("Quat", "from_rotation_z", angle)

            local vis = spawn({
                Transform = { translation = { x = 0, y = 0, z = 0.5 }, rotation = rot },
                Sprite    = {
                    image       = img,
                    rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                    custom_size = { x = 36, y = 5 },
                    color       = { r = 0.2, g = 0.9, b = 1.0, a = 1.0 },
                },
            }):with_parent(entity:id())

            proj_anims[entity:id()] = { timer = 0.0, visual_id = vis:id(), kind = "railgun" }

        elseif p.ability == "explosives" then
            local vis = spawn({
                Transform = { translation = { x = 0, y = 0, z = 0.5 } },
                Sprite    = {
                    image       = img,
                    rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                    custom_size = { x = 16, y = 16 },
                    color       = { r = 1.0, g = 0.45, b = 0.0, a = 1.0 },
                },
            }):with_parent(entity:id())

            proj_anims[entity:id()] = { timer = 0.0, visual_id = vis:id(), kind = "explosives" }
        end

        entity:patch({ weapon_visual_spawned = true })
        ::continue::
    end
end, { after = { "WeaponFire" } })

---------------------------------------------------------------------------
-- Projectile animations: railgun glow pulse, explosive wobble scale
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    for eid, anim in pairs(proj_anims) do
        anim.timer = anim.timer + dt

        if not world:get_entity(eid) then
            proj_anims[eid] = nil
            goto cont_anim
        end

        local vis = world:get_entity(anim.visual_id)
        if not vis then
            proj_anims[eid] = nil
            goto cont_anim
        end

        if anim.kind == "railgun" then
            local pulse = 0.75 + 0.25 * math.sin(anim.timer * 20.0)
            vis:patch({ Sprite = {
                color = { r = 0.2 * pulse, g = 0.9 * pulse, b = 1.0, a = 1.0 },
            }})

        elseif anim.kind == "explosives" then
            local s = 16 + 4 * math.abs(math.sin(anim.timer * 8.0))
            vis:patch({ Sprite = { custom_size = { x = s, y = s } } })
        end

        ::cont_anim::
    end
end, { after = { "WeaponFire" } })

---------------------------------------------------------------------------
-- Nova visual: expand from tiny dot to full ring over 0.35 s, then fade
---------------------------------------------------------------------------
register_system("Update", function(world)
    local EXPAND_DUR    = 0.35
    local FADE_THRESH   = 0.5
    local NOVA_LIFETIME = 2.0   -- must match server NOVA_LIFETIME constant
    local img = load_asset("character-spritesheet.png")

    -- Spawn visual on newly-arrived nova_zone entities
    for _, entity in ipairs(world:query({
        added   = { "nova_zone" },
        without = { "nova_visual_spawned" },
    })) do
        local nz        = entity:get("nova_zone")
        local r         = (nz and nz.radius) or 100
        local full_size = r * 2

        local vis = spawn({
            Transform = { translation = { x = 0, y = 0, z = 0.3 } },
            Sprite    = {
                image       = img,
                rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                custom_size = { x = full_size * 0.05, y = full_size * 0.05 },
                color       = { r = 1.0, g = 0.95, b = 0.2, a = 0.9 },
            },
        }):with_parent(entity:id())

        nova_visuals[entity:id()] = { vis_id = vis:id(), full_size = full_size }
        entity:patch({ nova_visual_spawned = true })
    end

    -- Animate existing nova visuals
    for eid, anim in pairs(nova_visuals) do
        local zone = world:get_entity(eid)
        if not zone then
            nova_visuals[eid] = nil
            goto cont_nova
        end

        local nz = zone:get("nova_zone")
        if not nz then
            nova_visuals[eid] = nil
            goto cont_nova
        end

        local vis = world:get_entity(anim.vis_id)
        if not vis then
            nova_visuals[eid] = nil
            goto cont_nova
        end

        local elapsed  = NOVA_LIFETIME - nz.lifetime
        local scale_t  = math.min(1.0, elapsed / EXPAND_DUR)
        local s        = 0.05 + 0.95 * scale_t   -- 0.05 → 1.0
        local full     = anim.full_size
        local alpha    = nz.lifetime < FADE_THRESH
                         and (nz.lifetime / FADE_THRESH) * 0.9
                         or  0.9

        vis:patch({ Sprite = {
            custom_size = { x = full * s, y = full * s },
            color       = { r = 1.0, g = 0.95, b = 0.2, a = alpha },
        }})

        ::cont_nova::
    end
end)

---------------------------------------------------------------------------
-- Explosion ring: react to server-spawned explosion_effect entities
---------------------------------------------------------------------------
register_system("Update", function(world)
    local img = load_asset("character-spritesheet.png")

    -- Spawn ring visual on newly-arriving explosion_effect entities
    for _, entity in ipairs(world:query({
        added   = { "explosion_effect" },
        without = { "explosion_visual_spawned" },
    })) do
        local ef    = entity:get("explosion_effect")
        local r     = (ef and ef.radius)   or 95
        local total = (ef and ef.lifetime) or 0.5

        local vis = spawn({
            Transform = { translation = { x = 0, y = 0, z = 0.4 } },
            Sprite    = {
                image       = img,
                rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                custom_size = { x = r * 2 * 0.1, y = r * 2 * 0.1 },
                color       = { r = 1.0, g = 0.55, b = 0.05, a = 1.0 },
            },
        }):with_parent(entity:id())

        explosion_visuals[entity:id()] = { vis_id = vis:id(), total_lifetime = total, radius = r }
        entity:patch({ explosion_visual_spawned = true })
    end

    -- Animate expanding rings
    for eid, anim in pairs(explosion_visuals) do
        local entity = world:get_entity(eid)
        if not entity then
            explosion_visuals[eid] = nil
            goto cont_expl
        end

        local ef = entity:get("explosion_effect")
        if not ef then
            explosion_visuals[eid] = nil
            goto cont_expl
        end

        local vis = world:get_entity(anim.vis_id)
        if not vis then
            explosion_visuals[eid] = nil
            goto cont_expl
        end

        local progress = 1.0 - (ef.lifetime / anim.total_lifetime)
        local s        = (0.1 + 0.9 * progress) * anim.radius * 2
        local alpha    = 1.0 - progress * 0.85
        local g        = 0.55 - progress * 0.35

        vis:patch({ Sprite = {
            custom_size = { x = s, y = s },
            color       = { r = 1.0, g = g, b = 0.05, a = alpha },
        }})

        ::cont_expl::
    end
end)

---------------------------------------------------------------------------
-- Muzzle flash: expand and fade over a short lifetime
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    for eid, flash in pairs(flash_timers) do
        flash.timer = flash.timer + dt

        local entity = world:get_entity(eid)
        if not entity or flash.timer >= flash.total then
            if entity then despawn(entity) end
            flash_timers[eid] = nil
            goto cont_flash
        end

        local progress = flash.timer / flash.total
        local alpha    = 1.0 - progress
        local s        = flash.base_size * (1.0 + progress * 1.5)

        entity:patch({ Sprite = {
            custom_size = { x = s, y = s },
            color       = { r = 1.0, g = 0.9, b = 0.5, a = alpha },
        }})

        ::cont_flash::
    end
end)
