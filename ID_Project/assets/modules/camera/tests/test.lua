-- modules/camera/tests/test.lua
-- Stage-based test for camera base mod.
-- Run: cargo run -p hello -- --script modules/camera/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("CameraTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    cam_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[CAM TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[CAM TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[CAM TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[CAM TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[CAM TEST] === Phase 1: Spawn camera mod ===")
        state.cam_eid = spawn({
            net_mod = {
                { camera = {}, net_sync = { authority = "client", target = "owner" } },
            },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.cam_eid)
        assert_not_nil("P1: camera entity exists", e)
        if e then
            assert_true("P1: has camera component", e:has("camera"))
            assert_true("P1: has mod component", e:has("mod"))

            -- Verify net_sync authority
            local ns = e:get("net_sync")
            assert_not_nil("P1: has net_sync", ns)
            if ns and ns.camera then
                assert_eq("P1: camera authority is client", ns.camera.authority, "client")
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
        print("[CAM TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[CAM TEST] SOME TESTS FAILED")
        else print("[CAM TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
