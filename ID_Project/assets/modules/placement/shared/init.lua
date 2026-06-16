-- modules/placement/shared/init.lua
-- Generic placement spawner.
--   1. When set on an entity, client can choose a spot to
--      spawn a new entity.

local BINDINGS = require("modules/placement/shared/bindings.lua")

---------------------------------------------------------------------------
-- Init: register placement input bindings
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "placement" } })) do
        entity:patch({
            input = { placement = BINDINGS },
            net_sync = {
                Transform = { authority = "client", reliable = false },
                input_placement = { authority = "client" },
            }
        })
        print(string.format("[Placement] Initialized placement for entity %d", entity:id()))
    end
end, {label = "Placement"})

---------------------------------------------------------------------------
-- Update: raycast to track cursor, confirm/cancel via input bindings
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with = { "placement", "input_placement" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_placement")

        -- Check confirm/cancel via input bindings (digital actions → booleans).
        if input.confirm then
            entity:remove("placement")
        end
        if input.cancel then
            despawn(entity)
        end
    end
end, {label = "PlacementUpdate"})
