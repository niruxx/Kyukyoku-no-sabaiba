-- modules/weapons/server/init.lua
-- Server-side weapons: validates predicted spawns from the client, runs
-- all damage logic (railgun hits, explosive AoE, nova zone kills), and
-- tracks the player's survival score.

local BINDINGS = require("modules/weapons/shared/bindings.lua")

-- Tune these to balance feel
local RAILGUN_HIT_RADIUS    = 16   -- px, contact range
local EXPLOSIVE_HIT_RADIUS  = 22   -- px, trigger blast on contact
local EXPLOSIVE_BLAST_RADIUS = 95  -- px, AoE kill zone
local NOVA_RADIUS            = 105 -- px, instant-kill ring
local NOVA_LIFETIME          = 2.0 -- seconds
local SCORE_PER_KILL         = 10

local registry = define_resource("WeaponRegistry", {
    weapons      = {},  -- name → { cooldown, last_used }
    elapsed_time = 0,
    score        = 0,
})

---------------------------------------------------------------------------
-- Elapsed time counter (used for cooldown tracking)
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    registry.elapsed_time = registry.elapsed_time + world:delta_time()
end)

---------------------------------------------------------------------------
-- Init: register bindings + weapon definitions when weapons component added
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "weapons" } })
    for _, entity in ipairs(entities) do
        entity:patch({
            input    = { weapons = BINDINGS },
            net_sync = { input_weapons = { authority = "client" } },
        })

        registry.weapons["railgun"]    = { cooldown = 0.5,  last_used = 0 }
        registry.weapons["explosives"] = { cooldown = 2.5,  last_used = 0 }
        registry.weapons["nova"]       = { cooldown = 8.0,  last_used = 0 }

        print(string.format("[WEAPONS/SERVER] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Approval: validate predicted weapon spawns; approve or reject.
-- Cooldown is shared across all players (registry-level, not per-player).
-- For a multi-player game this would be per-owner, but is fine for
-- the typical single or co-op zombie survival session.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local now = registry.elapsed_time

    for _, entity in ipairs(world:query({ added = { "net_predict" } })) do
        local predict = entity:get("net_predict") or {}
        local req     = predict.requested or {}
        local req_p   = req.projectile
        if not req_p then goto continue end

        local name   = req_p.ability
        local weapon = name and registry.weapons[name]

        if not weapon then
            print(string.format("[WEAPONS/SERVER] Unknown weapon '%s' — rejecting", tostring(name)))
            despawn(entity)
            goto continue
        end

        if now - weapon.last_used < weapon.cooldown then
            print(string.format("[WEAPONS/SERVER] '%s' on cooldown (%.1fs left) — rejecting",
                name, weapon.cooldown - (now - weapon.last_used)))
            despawn(entity)
            goto continue
        end
        weapon.last_used = now

        local pos = (req.Transform and req.Transform.translation) or { x = 0, y = 0, z = 0 }

        if name == "railgun" or name == "explosives" then
            local vel      = req.Velocity2d or { linvel = { x = 0, y = 0 }, angvel = 0 }
            local lifetime = name == "railgun" and 2.0 or 3.5
            local radius   = name == "railgun" and 5.0 or 8.0

            entity:set({
                Transform      = { translation = pos },
                RigidBody2d    = "Dynamic",
                Collider2d     = { ball = { radius = radius } },
                Sensor2d       = {},
                GravityScale2d = 0.0,
                LockedAxes2d   = "ROTATION_LOCKED",
                Velocity2d     = vel,
                projectile     = {
                    ability    = name,
                    owner_id   = predict.client_id,
                    lifetime   = lifetime,
                    spawn_time = now,
                },
                net_sync = {
                    Transform  = { authority = "server", reliable = false },
                    Velocity2d = { authority = "server" },
                    projectile = { authority = "server" },
                },
            })
            entity:remove("net_predict")
            print(string.format("[WEAPONS/SERVER] Approved '%s' for client %s", name, tostring(predict.client_id)))

        elseif name == "nova" then
            entity:set({
                Transform = { translation = pos },
                nova_zone = { radius = NOVA_RADIUS, lifetime = NOVA_LIFETIME },
                net_sync  = {
                    Transform = { authority = "server" },
                    nova_zone = { authority = "server" },
                },
            })
            entity:remove("net_predict")
            print(string.format("[WEAPONS/SERVER] Approved nova for client %s at (%.0f, %.0f)",
                tostring(predict.client_id), pos.x, pos.y))
        end

        ::continue::
    end
end, { label = "WeaponApproval", after = { "Movement" } })

---------------------------------------------------------------------------
-- Projectile lifetime cleanup
---------------------------------------------------------------------------
register_system("Update", function(world)
    local now = registry.elapsed_time
    for _, p in ipairs(world:query({ with = { "projectile" }, without = { "net_predict" } })) do
        local data = p:get("projectile")
        if data and data.spawn_time and data.lifetime then
            if now - data.spawn_time >= data.lifetime then
                despawn(p)
            end
        end
    end
end, { after = { "WeaponApproval" } })

---------------------------------------------------------------------------
-- Helper: 2D Euclidean distance between two translation tables
---------------------------------------------------------------------------
local function dist2d(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- Helper: kill every zombie within `radius` of (cx, cy); return kill count
---------------------------------------------------------------------------
local function kill_in_radius(world, cx, cy, radius)
    local killed = 0
    for _, zombie in ipairs(world:query({ with = { "zombie", "Transform" } })) do
        local zt = zombie:get("Transform")
        if zt and zt.translation then
            if dist2d({ x = cx, y = cy }, zt.translation) < radius then
                despawn(zombie)
                killed = killed + 1
            end
        end
    end
    return killed
end

---------------------------------------------------------------------------
-- Projectile–zombie collision damage
-- Railgun: one-hit-kill on first zombie touched, then despawns.
-- Explosives: first contact triggers blast AoE, then despawns.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local projectiles = world:query({ with = { "projectile", "Transform" }, without = { "net_predict" } })
    local zombies     = world:query({ with = { "zombie", "Transform" } })

    for _, proj in ipairs(projectiles) do
        local pdata = proj:get("projectile")
        if not pdata then goto cont_proj end

        local pt = proj:get("Transform")
        if not pt or not pt.translation then goto cont_proj end

        local ability  = pdata.ability
        local hit      = false

        for _, zombie in ipairs(zombies) do
            if hit then break end

            local zt = zombie:get("Transform")
            if not zt or not zt.translation then goto cont_zombie end

            local d = dist2d(pt.translation, zt.translation)

            if ability == "railgun" and d < RAILGUN_HIT_RADIUS then
                local zd  = zombie:get("zombie")
                local hp  = zd and (zd.hp or 1) or 1
                if hp <= 1 then
                    despawn(zombie)
                    registry.score = registry.score + SCORE_PER_KILL
                    print(string.format("[WEAPONS/SERVER] Railgun kill! Score: %d", registry.score))
                else
                    zombie:patch({ zombie = { hp = hp - 1 } })
                end
                despawn(proj)
                hit = true

            elseif ability == "explosives" and d < EXPLOSIVE_HIT_RADIUS then
                local killed = kill_in_radius(world, pt.translation.x, pt.translation.y, EXPLOSIVE_BLAST_RADIUS)
                registry.score = registry.score + killed * SCORE_PER_KILL

                -- Spawn visual ring — client reacts to explosion_effect component
                spawn({
                    Transform        = { translation = pt.translation },
                    explosion_effect = { lifetime = 0.5, radius = EXPLOSIVE_BLAST_RADIUS },
                    net_sync         = { explosion_effect = { authority = "server", reliable = true } },
                })

                print(string.format("[WEAPONS/SERVER] Explosion! %d kills. Score: %d", killed, registry.score))
                despawn(proj)
                hit = true
            end

            ::cont_zombie::
        end

        ::cont_proj::
    end
end, { label = "WeaponDamage", after = { "WeaponApproval" } })

---------------------------------------------------------------------------
-- Explosion effect lifetime cleanup (counts down and despawns)
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    for _, ef in ipairs(world:query({ with = { "explosion_effect" } })) do
        local data = ef:get("explosion_effect")
        if data then
            local remaining = data.lifetime - dt
            if remaining <= 0 then
                despawn(ef)
            else
                ef:patch({ explosion_effect = { lifetime = remaining } })
            end
        end
    end
end, { after = { "WeaponDamage" } })

---------------------------------------------------------------------------
-- Nova zone: each frame kill all zombies in radius, then count down lifetime
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    for _, zone in ipairs(world:query({ with = { "nova_zone", "Transform" } })) do
        local nz = zone:get("nova_zone")
        if not nz then goto cont_zone end

        local zt = zone:get("Transform")
        if not zt or not zt.translation then goto cont_zone end

        local killed = kill_in_radius(world, zt.translation.x, zt.translation.y, nz.radius)
        if killed > 0 then
            registry.score = registry.score + killed * SCORE_PER_KILL
            print(string.format("[WEAPONS/SERVER] Nova killed %d zombies! Score: %d", killed, registry.score))
        end

        local remaining = nz.lifetime - dt
        if remaining <= 0 then
            despawn(zone)
        else
            zone:patch({ nova_zone = { lifetime = remaining } })
        end

        ::cont_zone::
    end
end, { after = { "WeaponDamage" } })
