-- modules/placement/server/init.lua
-- Generic placement spawner.
--   1. When loaded as a panel net_mod (on the player entity), watches its own
--      component for spawn requests. Spawns placement entities with the
--      provided net_mod config.
--   2. When loaded on a placed entity, finalizes placement when the client
--      patches `placement.confirmed = true`.

local Placement = require("modules/placement/shared/init.lua")

local json = require "modules/dkjson.lua"

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
    end
end, {label = "Placement"})

---------------------------------------------------------------------------
-- Ensure input is cleaned up after placement
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        removed = { "placement" },
    })
    for _, entity in ipairs(entities) do
        entity:remove("input_placement")
    end
end, { label = "Placement" })
