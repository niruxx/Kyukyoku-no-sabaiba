-- modules/map/lobby/client/init.lua
-- Client side of the lobby map: bake colliders (shared — needed for the local predicted
-- player) AND load the GLB scene for visuals + lighting.
require("modules/map/lobby/shared/init.lua")

local LOBBY_GLB = "modules/map/lobby/assets/lobby.glb"

register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "map/lobby" } })) do
        -- Visuals: spawn the lobby scene.
        spawn({
            SceneRoot = load_asset(LOBBY_GLB .. "#Scene0"),
            Transform = {},
        }):with_parent(entity:id())

        -- Lighting (client-only — the server doesn't render).
        spawn({
            DirectionalLight = { illuminance = 10000, shadows_enabled = true },
            Transform = { rotation = { x = -0.5, y = 0.5, z = 0, w = 0.7 } },
        }):with_parent(entity:id())
        spawn({ AmbientLight = { brightness = 300 } })

        print("[MAP/LOBBY] Client: spawned lobby visuals + lighting")
    end
    return true -- one-shot
end)
