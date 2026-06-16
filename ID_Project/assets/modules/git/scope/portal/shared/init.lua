local json = require("modules/dkjson.lua")

---------------------------------------------------------------------------
-- System: PortalMeshInit — spawn portal collider as sensor when placed
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        with = { "git/scope/portal" },
        removed = { "placement" }
    })
    for _, entity in ipairs(entities) do
        if not world:get_entity(entity:id()) then goto continue end -- Placement despawns on cancel

        entity:remove("ScriptOwned")
        entity:patch({
            RigidBody3d = "Fixed",
            Collider3d = { ball = { radius = 1.2 } },
            Sensor3d = {},
            CollidingEntities3d = {},
            ActiveEvents3d = "COLLISION_EVENTS",
        })

        ::continue::
    end
end)
