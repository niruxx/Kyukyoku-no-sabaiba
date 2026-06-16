-- modules/abilities/server/init.lua
-- Server-side abilities: registers bindings + dynamic ability registry, and
-- approves/rejects predicted projectile spawns from clients. Client initiates
-- every projectile via net_predict; the server validates against the registry.

local BINDINGS = require("modules/abilities/shared/bindings.lua")

local registry = define_resource("AbilityRegistry", {
    abilities = {},   -- name → { key, cooldown, last_used }
    elapsed_time = 0,
})

register_system("PreUpdate", function(world)
    registry.elapsed_time = registry.elapsed_time + world:delta_time()
end)

---------------------------------------------------------------------------
-- Init: register bindings + default abilities + net_sync authority
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "abilities" } })
    for _, entity in ipairs(entities) do
        -- Register ability bindings (server-side validation whitelist)
        entity:patch({
            input = { abilities = BINDINGS },
            net_sync = {
                input_abilities = { authority = "client" },
            }
        })

        -- Register default fireball ability
        registry.abilities["fireball"] = {
            key = "KeyQ",
            cooldown = 1.0,
            last_used = 0,
        }

        print(string.format("[ABILITIES/SERVER] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Dynamic ability registration via events
---------------------------------------------------------------------------
register_system("Update", function(world)
    local reg_events = world:read_events("ability:register") or {}
    for _, evt in ipairs(reg_events) do
        if evt.name and evt.key then
            registry.abilities[evt.name] = {
                key = evt.key,
                cooldown = evt.cooldown or 1.0,
                last_used = 0,
            }
            local entities = world:query({ with = { "abilities", "input" } })
            for _, entity in ipairs(entities) do
                entity:patch({ input = { abilities = {
                    [evt.name] = { key = evt.key, mode = "game" },
                }}})
            end
            print(string.format("[ABILITIES/SERVER] Registered ability '%s' (key=%s)", evt.name, evt.key))
        end
    end

    local unreg_events = world:read_events("ability:unregister") or {}
    for _, evt in ipairs(unreg_events) do
        if evt.name and registry.abilities[evt.name] then
            registry.abilities[evt.name] = nil
            local entities = world:query({ with = { "abilities", "input" } })
            for _, entity in ipairs(entities) do
                entity:patch({ input = { abilities = { [evt.name] = null } } })
            end
            print(string.format("[ABILITIES/SERVER] Unregistered ability '%s'", evt.name))
        end
    end
end, { before = { "Ability" } })

---------------------------------------------------------------------------
-- Approval: validate predicted projectiles and approve (or reject) the spawn.
-- The client tags projectiles with { net_predict = {}, projectile = { ability } };
-- net/server materializes a pending entity, this system inspects it.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local current_time = registry.elapsed_time

    local entities = world:query({ added = { "net_predict" } })
    for _, entity in ipairs(entities) do
        local predict = entity:get("net_predict") or {}
        local req = predict.requested or {}
        local req_proj = req.projectile
        if not req_proj then goto continue end

        local ability_name = req_proj.ability
        local ability = ability_name and registry.abilities[ability_name]

        if not ability then
            print(string.format("[ABILITIES/SERVER] Unknown ability '%s' from client %s — rejecting",
                tostring(ability_name), tostring(predict.client_id)))
            despawn(entity)
            goto continue
        end

        if current_time - (ability.last_used or 0) < ability.cooldown then
            print(string.format("[ABILITIES/SERVER] Cooldown not ready for '%s' — rejecting", ability_name))
            despawn(entity)
            goto continue
        end
        ability.last_used = current_time

        entity:set({
            Transform = req.Transform or { translation = { x = 0, y = 0, z = 0 } },
            Velocity3d = req.Velocity3d,
            Collider3d = req.Collider3d,
            RigidBody3d = req.RigidBody3d,
            GravityScale3d = req.GravityScale3d,
            projectile = {
                ability = ability_name,
                owner_id = predict.client_id,
                lifetime = 3.0,
                spawn_time = current_time,
            },
            net_sync = {
                Transform = { authority = "server", reliable = false },
                projectile = { authority = "server" },
            },
        })
        entity:remove("net_predict")
        print(string.format("[ABILITIES/SERVER] Approved %s from client %s",
            ability_name, tostring(predict.client_id)))

        ::continue::
    end
end, { label = "Ability", after = { "Movement" } })

---------------------------------------------------------------------------
-- Projectile cleanup: despawn after lifetime
---------------------------------------------------------------------------
register_system("Update", function(world)
    local current_time = registry.elapsed_time

    local projectiles = world:query({ with = { "projectile" }, without = { "net_predict" } })
    for _, proj in ipairs(projectiles) do
        local p = proj:get("projectile")
        if p and p.spawn_time and p.lifetime then
            if current_time - p.spawn_time >= p.lifetime then
                despawn(proj)
            end
        end
    end
end, { after = { "Ability" } })
