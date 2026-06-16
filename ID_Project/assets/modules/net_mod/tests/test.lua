-- modules/net_mod/tests/test.lua
-- Stage-based test for net_mod orchestrator.
-- Run: cargo run -p hello -- --script modules/net_mod/tests/test.lua
--
-- Tests:
--   Phase 1: net_mod with default sync → produces mod + net_sync
--   Phase 2: net_mod with net_sync = false → produces mod, no net_sync
--   Phase 3: net_mod with custom authority + target
--   Phase 4: net_mod array with mixed overrides
--   Phase 5: net_mod change detection (swap entries)

require("modules/mod/init.lua")

-- Set up NetInfo with side = "server" BEFORE requiring instance.lua.
-- In production, net/server/init.lua sets this; here we do it directly.
local net_info = define_resource("NetInfo", {})
net_info.side = "server"

-- Require instance.lua at our state_id (0 in tests).
-- This registers NetModLoader which reads net_info.side via define_resource.
require("modules/net_mod/instance.lua")

local state = define_resource("NetModTestState", {
    phase = 0,
    frames = 0,
    passed = 0,
    failed = 0,
    e1 = nil,
    e2 = nil,
    e3 = nil,
    e4 = nil,
    e5 = nil,
    e6a = nil,
    e6b = nil,
})
-- Force reset
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
        print("info", "[NETMOD TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NETMOD TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_false(label, val) assert_eq(label, val, false) end

local function assert_not_nil(label, val)
    if val ~= nil then
        state.passed = state.passed + 1
        print("info", "[NETMOD TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NETMOD TEST] FAIL: " .. label .. " expected non-nil")
    end
end

local function assert_nil(label, val)
    if val == nil then
        state.passed = state.passed + 1
        print("info", "[NETMOD TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NETMOD TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    ---------------------------------------------------------------------------
    -- Phase 0: Spawn with default net_mod
    ---------------------------------------------------------------------------
    if state.phase == 0 then
        print("info", "[NETMOD TEST] === Phase 1: Default net_mod → mod + net_sync ===")
        state.e1 = spawn({
            net_mod = { ["test_controller"] = { speed = 10 } },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 1: Verify default translation
    ---------------------------------------------------------------------------
    if state.phase == 1 then
        if state.frames < 3 then return end

        local e = world:get_entity(state.e1)
        assert_not_nil("P1: entity exists", e)
        if e then
            -- net_mod should have produced a mod component
            assert_true("P1: has mod", e:has("mod"))

            -- net_sync should have default server authority
            local ns = e:get("net_sync")
            assert_not_nil("P1: has net_sync", ns)
            if ns then
                local tc = ns["test_controller"]
                assert_not_nil("P1: net_sync has test_controller", tc)
                if tc then
                    assert_eq("P1: authority is server", tc.authority, "server")
                end
            end

            -- mod should have correct script path for server side (array form)
            local mod_val = e:get("mod")
            assert_not_nil("P1: has mod value", mod_val)
        end

        print("info", "[NETMOD TEST] === Phase 2: net_sync = false → no sync ===")
        state.e2 = spawn({
            net_mod = {
                { ["test_visual"] = { color = "red" }, net_sync = false },
            },
        }):id()
        state.phase = 2
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Verify net_sync = false
    ---------------------------------------------------------------------------
    if state.phase == 2 then
        if state.frames < 3 then return end

        local e = world:get_entity(state.e2)
        assert_not_nil("P2: entity exists", e)
        if e then
            assert_true("P2: has mod", e:has("mod"))
            -- net_sync should NOT have test_visual entry
            local ns = e:get("net_sync")
            if ns then
                assert_nil("P2: net_sync does NOT have test_visual", ns["test_visual"])
            else
                -- No net_sync at all is also valid
                print("info", "[NETMOD TEST] PASS: P2: no net_sync component (correct)")
                state.passed = state.passed + 1
            end
        end

        print("info", "[NETMOD TEST] === Phase 3: Custom authority + target ===")
        state.e3 = spawn({
            net_mod = {
                { ["test_camera"] = {}, net_sync = { authority = "client", target = "owner" } },
            },
        }):id()
        state.phase = 3
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 3: Verify custom authority + target
    ---------------------------------------------------------------------------
    if state.phase == 3 then
        if state.frames < 3 then return end

        local e = world:get_entity(state.e3)
        assert_not_nil("P3: entity exists", e)
        if e then
            local ns = e:get("net_sync")
            assert_not_nil("P3: has net_sync", ns)
            if ns then
                local tc = ns["test_camera"]
                assert_not_nil("P3: net_sync has test_camera", tc)
                if tc then
                    assert_eq("P3: authority is client", tc.authority, "client")
                    assert_eq("P3: target is owner", tc.target, "owner")
                end
            end
        end

        print("info", "[NETMOD TEST] === Phase 4: Mixed array ===")
        state.e4 = spawn({
            net_mod = {
                { ["test_movement"] = { speed = 5 } },                                     -- default sync
                { ["test_vfx"] = { effect = "smoke" }, net_sync = false },                  -- no sync
                { ["test_health"] = {}, net_sync = { authority = "server", target = "all" } }, -- custom
            },
        }):id()
        state.phase = 4
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 4: Verify mixed array
    ---------------------------------------------------------------------------
    if state.phase == 4 then
        if state.frames < 3 then return end

        local e = world:get_entity(state.e4)
        assert_not_nil("P4: entity exists", e)
        if e then
            local ns = e:get("net_sync")
            assert_not_nil("P4: has net_sync", ns)
            if ns then
                -- test_movement should be synced (default)
                local mv = ns["test_movement"]
                assert_not_nil("P4: has test_movement sync", mv)
                if mv then
                    assert_eq("P4: test_movement authority", mv.authority, "server")
                end

                -- test_vfx should NOT be synced
                assert_nil("P4: test_vfx NOT synced", ns["test_vfx"])

                -- test_health should have custom config
                local hp = ns["test_health"]
                assert_not_nil("P4: has test_health sync", hp)
                if hp then
                    assert_eq("P4: test_health authority", hp.authority, "server")
                    assert_eq("P4: test_health target", hp.target, "all")
                end
            end
        end

        state.phase = 5
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 5: Base class resolution
    ---------------------------------------------------------------------------
    if state.phase == 5 then
        if state.frames == 1 then
            print("info", "[NETMOD TEST] === Phase 5: Base class resolution ===")
            state.e5 = spawn({
                net_mod = {
                    { ["net_mod/tests/test_sub_mod"] = { custom = true } },
                },
            }):id()
            return
        end
        if state.frames < 15 then return end

        local e = world:get_entity(state.e5)
        assert_not_nil("P5: entity exists", e)
        if e then
            -- Sub mod component should exist
            assert_true("P5: has test_sub_mod", e:has("net_mod/tests/test_sub_mod"))

            -- Base mod component should be auto-loaded
            assert_true("P5: has test_base_mod (base resolved)", e:has("net_mod/tests/test_base_mod"))

            -- Base server script should have run (patches base_loaded = true)
            local base = e:get("net_mod/tests/test_base_mod")
            assert_not_nil("P5: test_base_mod has data", base)
            if base then
                assert_true("P5: base_loaded is true", base.base_loaded == true)
            end

            -- net_sync should have entries for both sub and base
            local ns = e:get("net_sync")
            assert_not_nil("P5: has net_sync", ns)
            if ns then
                assert_not_nil("P5: net_sync has test_sub_mod", ns["net_mod/tests/test_sub_mod"])
                assert_not_nil("P5: net_sync has test_base_mod (reactive)", ns["net_mod/tests/test_base_mod"])
            end

            -- mod component should contain both entries
            assert_true("P5: has mod", e:has("mod"))
        end

        if e then despawn(e) end
        state.phase = 6
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 6: Shared base deref
    ---------------------------------------------------------------------------
    if state.phase == 6 then
        if state.frames == 1 then
            print("info", "[NETMOD TEST] === Phase 6: Shared base deref ===")
            state.e6a = spawn({
                net_mod = { { ["net_mod/tests/test_sub_mod"] = {} } },
            }):id()
            state.e6b = spawn({
                net_mod = { { ["net_mod/tests/test_sub_mod"] = {} } },
            }):id()
            return
        end
        if state.frames < 15 then return end

        if state.frames == 15 then
            -- Both should have the base
            local ea = world:get_entity(state.e6a)
            local eb = world:get_entity(state.e6b)
            assert_not_nil("P6: entity A exists", ea)
            assert_not_nil("P6: entity B exists", eb)
            if ea then
                assert_true("P6: A has test_base_mod", ea:has("net_mod/tests/test_base_mod"))
            end
            if eb then
                assert_true("P6: B has test_base_mod", eb:has("net_mod/tests/test_base_mod"))
            end

            -- Despawn entity A
            if ea then despawn(ea) end
            return
        end

        if state.frames < 20 then return end

        -- Entity B should still have its base
        local eb = world:get_entity(state.e6b)
        assert_not_nil("P6: B still exists after A despawned", eb)
        if eb then
            assert_true("P6: B still has test_base_mod", eb:has("net_mod/tests/test_base_mod"))
            despawn(eb)
        end

        state.phase = 7
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 7: Done
    ---------------------------------------------------------------------------
    if state.phase == 7 then
        print("info", "")
        print("info", "=========================================")
        print("info", "[NETMOD TEST] RESULTS: " ..
            state.passed .. " passed, " .. state.failed .. " failed")
        print("info", "=========================================")
        if state.failed > 0 then
            print("error", "[NETMOD TEST] SOME TESTS FAILED")
        else
            print("info", "[NETMOD TEST] ALL TESTS PASSED")
        end
        state.phase = 99
        return
    end
end)
