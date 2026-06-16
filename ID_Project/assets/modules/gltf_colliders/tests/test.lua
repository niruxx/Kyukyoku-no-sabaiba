-- modules/gltf_colliders/tests/test.lua
-- HEADLESS test for the GLB -> trimesh collider pipeline.
-- Verifies that the gltf_colliders module spawns a scene, walks the ChildOf tree,
-- and builds static trimesh colliders from mesh nodes via Collider::from_bevy_mesh.
--
-- Run (headless / dedicated server):
--   cargo run -p hello -- --network server --script modules/gltf_colliders/tests/test.lua
--
-- An existing character GLB is used as the geometry source. include = "" matches
-- every node name, so every mesh node contributes a collider.

local TEST_GLB = "Placeholder-Character/Model.glb"

local state = define_resource("GltfColliderTestState", {
    started = false,
    done = false,
    frames = 0,
})
-- reset on hot-reload
state.started = false
state.done = false
state.frames = 0

register_system("Update", function(world)
    if state.done then return end
    state.frames = state.frames + 1

    -- Frame 1: spawn an entity with the gltf_colliders mod config.
    if not state.started then
        spawn({
            Transform = {},
            mod = { ["gltf_colliders"] = { scene = TEST_GLB, include = "" } },
        })
        state.started = true
        print("[GLTFCOL TEST] Requested colliders from '" .. TEST_GLB .. "' (headless)")
        return
    end

    -- Poll for baked colliders.
    local colliders = world:query({ with = { "Collider3d" } })
    local n = #colliders

    if n > 0 then
        print("")
        print("=========================================")
        print("[GLTFCOL TEST] PASS: baked " .. n .. " trimesh collider(s) headless")
        print("[GLTFCOL TEST] ALL TESTS PASSED")
        print("=========================================")
        state.done = true
        return
    end

    -- Timeout guard (server loops fast; allow plenty of frames for async file load).
    if state.frames > 200000 then
        print("")
        print("=========================================")
        print("[GLTFCOL TEST] FAIL: no colliders baked after " .. state.frames .. " frames")
        print("[GLTFCOL TEST] SOME TESTS FAILED")
        print("=========================================")
        state.done = true
        return
    end
end)
