-- modules/map/lobby/tests/test.lua
-- HEADLESS verification that the lobby GLB bakes trimesh colliders from its _col nodes.
-- Confirms the Blender export preserved object names as glTF node names (so the
-- "_col" opt-in marker is matched) and that ~33 collidable objects produce colliders.
--
-- Run (headless / dedicated server):
--   .\hello.exe --network server --script modules/map/lobby/tests/test.lua --skip-update

local LOBBY_GLB = "modules/map/lobby/assets/lobby.glb"
local EXPECT_MIN = 30 -- 33 objects are tagged _col

local state = define_resource("LobbyColTestState", { started = false, done = false, frames = 0 })
state.started = false; state.done = false; state.frames = 0

register_system("Update", function(world)
    if state.done then return end
    state.frames = state.frames + 1

    if not state.started then
        spawn({
            Transform = {},
            mod = { ["gltf_colliders"] = { scene = LOBBY_GLB, include = "_col" } },
        })
        state.started = true
        print("[LOBBY TEST] Requested _col colliders from " .. LOBBY_GLB .. " (headless)")
        return
    end

    local n = #world:query({ with = { "Collider3d" } })
    if n >= EXPECT_MIN then
        print("")
        print("=========================================")
        print("[LOBBY TEST] PASS: baked " .. n .. " trimesh colliders from _col nodes")
        print("[LOBBY TEST] ALL TESTS PASSED")
        print("=========================================")
        state.done = true
        return
    end

    if state.frames > 200000 then
        print("")
        print("=========================================")
        print("[LOBBY TEST] FAIL: only " .. n .. " colliders after " .. state.frames ..
            " frames (expected >= " .. EXPECT_MIN .. ")")
        print("[LOBBY TEST] -> glTF node names may not match Blender object names")
        print("[LOBBY TEST] SOME TESTS FAILED")
        print("=========================================")
        state.done = true
        return
    end
end)
