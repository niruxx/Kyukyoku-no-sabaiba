-- modules/camera/2d/tests/test.lua
-- Stage-based test for camera/2d mod.
-- Run: cargo run -p hello -- --script modules/camera/2d/tests/test.lua

require("modules/mod/init.lua")
local net_info = define_resource("NetInfo", { side = nil, port = 5001 })
net_info.side = "client"
net_info.port = 5001

local state = define_resource("Camera2dTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    camera_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[CAMERA2D TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[CAMERA2D TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[CAMERA2D TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[CAMERA2D TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[CAMERA2D TEST] === Phase 1: Spawn camera2d ===")
        state.camera_eid = spawn({
            Transform = { translation = { x = 10, y = 20, z = 0 } },
            mod = {
                ["camera/2d"] = {},
                script = "modules/camera/2d/client/init.lua",
            },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.camera_eid)
        assert_not_nil("P1: camera owner exists", e)
        if e then
            assert_true("P1: has camera2d component", e:has("camera/2d"))
            local cam = e:get("camera/2d")
            assert_not_nil("P1: camera2d has data", cam)
            if cam then
                assert_not_nil("P1: camera entity id set", cam.camera_entity)
                local camera_entity = world:get_entity(cam.camera_entity)
                assert_not_nil("P1: Camera2d entity exists", camera_entity)
                if camera_entity then
                    assert_true("P1: child camera has Camera2d", camera_entity:has("Camera2d"))
                end
            end
        end
        if e then despawn(e) end
        state.phase = 2
        state.frames = 0
        return
    end

    if state.phase == 2 then
        print("")
        print("=========================================")
        print("[CAMERA2D TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[CAMERA2D TEST] SOME TESTS FAILED")
        else print("[CAMERA2D TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
