-- modules/input/tests/test.lua
-- Stage-based test for input mod.
-- Tests client-side behavior (bindings, input defaults, runtime patch).
-- Run: cargo run -p hello -- --script modules/input/tests/test.lua
--
-- Tests:
--   Phase 1: Spawn input mod → has input, bindings, mod, net_sync
--   Phase 2: Runtime binding patch → new binding added, defaults preserved

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

-- Use client side so bindings (set by input/client/init.lua) are loaded
local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "client"

local state = define_resource("InputTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    input_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then
        state.passed = state.passed + 1
        print("info", "[INPUT TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[INPUT TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("info", "[INPUT TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("error", "[INPUT TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    ---------------------------------------------------------------------------
    -- Phase 0: Spawn input mod
    ---------------------------------------------------------------------------
    if state.phase == 0 then
        print("info", "[INPUT TEST] === Phase 1: Spawn input mod ===")
        state.input_eid = spawn({
            net_mod = { input = {} },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 1: Verify input entity has all components
    ---------------------------------------------------------------------------
    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.input_eid)
        assert_not_nil("P1: input entity exists", e)
        if e then
            assert_true("P1: has input component", e:has("input"))
            assert_true("P1: has bindings component", e:has("bindings"))
            assert_true("P1: has mod component", e:has("mod"))

            -- Verify net_sync has client authority for input
            local ns = e:get("net_sync")
            assert_not_nil("P1: has net_sync", ns)
            if ns and ns.input then
                assert_eq("P1: input authority is client", ns.input.authority, "client")
            end

            -- Verify default bindings are set
            local bindings = e:get("bindings")
            assert_not_nil("P1: bindings has data", bindings)
            if bindings then
                assert_eq("P1: forward default", bindings.forward, "KeyW")
                assert_eq("P1: backward default", bindings.backward, "KeyS")
                assert_eq("P1: jump default", bindings.jump, "Space")
            end
        end

        -- Phase 2: verify runtime binding patch
        print("info", "[INPUT TEST] === Phase 2: Patch bindings at runtime ===")
        if e then
            e:patch({ bindings = { ability_test = "KeyQ" } })
        end
        state.phase = 2
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Verify runtime patch preserved defaults
    ---------------------------------------------------------------------------
    if state.phase == 2 then
        if state.frames < 3 then return end
        local e = world:get_entity(state.input_eid)
        if e then
            local bindings = e:get("bindings")
            assert_not_nil("P2: bindings exist", bindings)
            if bindings then
                assert_eq("P2: ability_test binding added", bindings.ability_test, "KeyQ")
                -- Default bindings should still be present (deep merge)
                assert_eq("P2: forward binding preserved", bindings.forward, "KeyW")
            end
        end

        if e then despawn(e) end
        state.phase = 3
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 3: Results
    ---------------------------------------------------------------------------
    if state.phase == 3 then
        print("info", "")
        print("info", "=========================================")
        print("info", "[INPUT TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("info", "=========================================")
        if state.failed > 0 then print("error", "[INPUT TEST] SOME TESTS FAILED")
        else print("info", "[INPUT TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
