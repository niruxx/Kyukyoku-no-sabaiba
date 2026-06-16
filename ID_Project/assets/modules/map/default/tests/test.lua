-- modules/map/default/tests/test.lua
-- Stage-based test for map/default mod.
-- Run: cargo run -p hello -- --script modules/map/default/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

-- Set up NetInfo so net_mod can resolve side
local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("MapTestState", {
    phase = 0,
    frames = 0,
    passed = 0,
    failed = 0,
    map_eid = nil,
})
-- Force reset on hot-reload
state.phase = 0
state.frames = 0
state.passed = 0
state.failed = 0

---------------------------------------------------------------------------
-- Assert helpers
---------------------------------------------------------------------------
local function assert_eq(label, got, expected)
    if got == expected then
        state.passed = state.passed + 1
        print("[MAP TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("[MAP TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

local function assert_true(label, val) assert_eq(label, val, true) end

local function assert_not_nil(label, val)
    if val ~= nil then
        state.passed = state.passed + 1
        print("[MAP TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("[MAP TEST] FAIL: " .. label .. " expected non-nil")
    end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    ---------------------------------------------------------------------------
    -- Phase 0: Spawn map mod
    ---------------------------------------------------------------------------
    if state.phase == 0 then
        print("[MAP TEST] === Phase 1: Spawn map/default ===")
        state.map_eid = spawn({
            net_mod = { ["map/default"] = {} },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 1: Verify map entity has components + children
    ---------------------------------------------------------------------------
    if state.phase == 1 then
        if state.frames < 15 then return end -- wait for async loading

        local e = world:get_entity(state.map_eid)
        assert_not_nil("P1: map entity exists", e)
        if e then
            assert_true("P1: has map/default component", e:has("map/default"))
            assert_true("P1: has mod component", e:has("mod"))

            -- Check for descendants (ground plane + lights)
            local real_id = e:id()
            local descendants = world:query({
                entities = { real_id },
            })
            -- descendants includes the root entity itself, so we expect at least 3
            assert_true("P1: has at least 2 children (ground + light)", #descendants >= 3)
        end

        -- Clean up
        if e then despawn(e) end
        state.phase = 2
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Done
    ---------------------------------------------------------------------------
    if state.phase == 2 then
        print("")
        print("=========================================")
        print("[MAP TEST] RESULTS: " ..
            state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then
            print("[MAP TEST] SOME TESTS FAILED")
        else
            print("[MAP TEST] ALL TESTS PASSED")
        end
        state.phase = 99
        return
    end
end)
