-- modules/abilities/tests/test.lua
-- Stage-based test for abilities mod.
-- Run: cargo run -p hello -- --script modules/abilities/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("AbilityTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    ab_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[AB TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[AB TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[AB TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[AB TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[AB TEST] === Phase 1: Spawn abilities mod ===")
        state.ab_eid = spawn({
            net_mod = { abilities = {} },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.ab_eid)
        assert_not_nil("P1: abilities entity exists", e)
        if e then
            assert_true("P1: has abilities component", e:has("abilities"))
            assert_true("P1: has mod component", e:has("mod"))

            -- Verify default fireball binding was added
            local bindings = e:get("bindings")
            assert_not_nil("P1: has bindings component", bindings)
            if bindings then
                assert_eq("P1: fireball binding is KeyQ", bindings.ability_fireball, "KeyQ")
            end
        end

        -- Phase 2: dynamic registration via event
        print("[AB TEST] === Phase 2: Register ability via event ===")
        world:write_event("ability:register", {
            name = "ability_test",
            key = "KeyE",
            cooldown = 2.0,
        })
        state.phase = 2
        state.frames = 0
        return
    end

    if state.phase == 2 then
        if state.frames < 3 then return end
        local e = world:get_entity(state.ab_eid)
        if e then
            local bindings = e:get("bindings")
            assert_not_nil("P2: bindings exist", bindings)
            if bindings then
                assert_eq("P2: test ability binding added", bindings.ability_test, "KeyE")
                assert_eq("P2: fireball binding preserved", bindings.ability_fireball, "KeyQ")
            end
        end

        -- Phase 3: unregister
        print("[AB TEST] === Phase 3: Unregister ability ===")
        world:write_event("ability:unregister", { name = "ability_test" })
        state.phase = 3
        state.frames = 0
        return
    end

    if state.phase == 3 then
        if state.frames < 3 then return end
        local e = world:get_entity(state.ab_eid)
        if e then
            local bindings = e:get("bindings")
            if bindings then
                assert_eq("P3: test ability removed", bindings.ability_test, nil)
                assert_eq("P3: fireball still present", bindings.ability_fireball, "KeyQ")
            end
        end

        if e then despawn(e) end
        state.phase = 4
        state.frames = 0
        return
    end

    if state.phase == 4 then
        print("")
        print("=========================================")
        print("[AB TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[AB TEST] SOME TESTS FAILED")
        else print("[AB TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
