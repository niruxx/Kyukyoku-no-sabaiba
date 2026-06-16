-- modules/abilities/client/init.lua
-- Client-side abilities: registers bindings on input and spawns predicted
-- projectiles tagged with `net_predict`. The net module handles the spawn
-- request / confirm / reject / timeout lifecycle; this mod only fires inputs.

local BINDINGS = require("modules/abilities/shared/bindings.lua")

---------------------------------------------------------------------------
-- Init: register ability bindings on the input component
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "abilities" } })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { abilities = BINDINGS } })
        print(string.format("[ABILITIES/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Dynamic ability registration via events (client-side)
---------------------------------------------------------------------------
register_system("Update", function(world)
    local reg_events = world:read_events("ability:register") or {}
    for _, evt in ipairs(reg_events) do
        if evt.name and evt.key then
            local entities = world:query({ with = { "abilities", "input" } })
            for _, entity in ipairs(entities) do
                entity:patch({ input = { abilities = {
                    [evt.name] = { key = evt.key, mode = "game" },
                }}})
            end
            print(string.format("[ABILITIES/CLIENT] Registered binding '%s' → '%s'", evt.name, evt.key))
        end
    end

    local unreg_events = world:read_events("ability:unregister") or {}
    for _, evt in ipairs(unreg_events) do
        if evt.name then
            local entities = world:query({ with = { "abilities", "input" } })
            for _, entity in ipairs(entities) do
                entity:patch({ input = { abilities = { [evt.name] = null } } })
            end
        end
    end
end, { before = { "Ability" } })

---------------------------------------------------------------------------
-- Prediction: spawn a projectile locally tagged with net_predict.
-- net/client handles SPAWN_REQUEST / CONFIRM / REJECT / timeout.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with = { "abilities", "Transform" },
        changed = { "input_abilities" },
    })
    for _, entity in ipairs(entities) do
        local ab_input = entity:get("input_abilities")
        if not ab_input then goto continue end

        if ab_input.fireball then
            local t = entity:get("Transform")
            if t and t.translation then
                local fwd = world:call_component_method(entity:id(), "Transform", "back")
                if #fwd then
                    fwd = fwd[1]
                    local spawn_pos = {
                        x = t.translation.x + fwd.x * 1.0,
                        y = t.translation.y + 1.0,
                        z = t.translation.z + fwd.z * 1.0,
                    }

                    local mesh = create_asset("bevy_mesh::mesh::Mesh", {
                        primitive = { Sphere = { radius = 0.2 } },
                    })
                    local mat = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
                        base_color = { r = 1.0, g = 0.3, b = 0.1, a = 1.0 },
                        emissive = { r = 2.0, g = 0.5, b = 0.1, a = 1.0 },
                    })

                    spawn({
                        Transform = { translation = spawn_pos },
                        Mesh3d = mesh,
                        MeshMaterial3d = mat,
                        Velocity3d = { linvel = {
                            x = fwd.x * 20,
                            y = fwd.y * 20,
                            z = fwd.z * 20,
                        }},
                        RigidBody3d = "Dynamic",
                        Collider3d = { Ball = { radius = 0.2 } },
                        GravityScale3d = { value = 0.3 },
                        projectile = { ability = "fireball" },
                        net_sync = {
                            Transform = { authority = "server", reliable = false },
                            projectile = { authority = "server" },
                        },
                    })
                end
            end
        end

        ::continue::
    end
end, { label = "Ability", after = { "Movement" } })
