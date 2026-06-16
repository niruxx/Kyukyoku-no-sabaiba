-- modules/map/lobby/shared/init.lua
-- Collision is baked on BOTH sides: the server needs it for authority, and the client
-- needs it for its local (predicted) player copy — otherwise the client-side player
-- falls through the floor. Colliders are local (not net-synced) and deterministic, so
-- both sides read the same GLB and build identical trimesh geometry from the `_col` nodes.

local LOBBY_GLB = "modules/map/lobby/assets/lobby.glb"

register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "map/lobby" } })) do
        spawn({
            Transform = {}, -- identity; collider children are placed in world space
            mod = { ["gltf_colliders"] = { scene = LOBBY_GLB, include = "_col" } },
        }):with_parent(entity:id())

        print("[MAP/LOBBY] requested trimesh colliders from " .. LOBBY_GLB)
    end
    return true -- one-shot
end)
