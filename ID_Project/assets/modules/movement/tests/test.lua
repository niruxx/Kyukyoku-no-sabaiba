-- modules/movement/tests/test.lua
-- Stage-based test for movement mod.
-- Run: cargo run -p hello -- --script modules/movement/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("MovementTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    mv_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[MV TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[MV TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[MV TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[MV TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[MV TEST] === Phase 1: Spawn movement mod ===")
        state.mv_eid = spawn({
            net_mod = { movement = { speed = 8.0 } },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.mv_eid)
        assert_not_nil("P1: movement entity exists", e)
        if e then
            assert_true("P1: has movement component", e:has("movement"))

            local mv = e:get("movement")
            assert_not_nil("P1: movement has data", mv)
            if mv then
                assert_eq("P1: speed is 8.0", mv.speed, 8.0)
                assert_not_nil("P1: has jump_force", mv.jump_force)
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
        print("[MV TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[MV TEST] SOME TESTS FAILED")
        else print("[MV TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
