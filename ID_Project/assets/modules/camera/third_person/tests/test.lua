-- modules/camera/third_person/tests/test.lua
-- Stage-based test for camera/third_person mod.
-- Tests both server-side and client-side behavior by switching NetInfo.side.
-- Run: cargo run -p hello -- --script modules/camera/third_person/tests/test.lua
--
-- Tests:
--   Phase 1 (server): Base chain resolves, net_sync authority override
--   Phase 2 (client): Base chain resolves, camera defaults (yaw/pitch/distance)

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })

local state = define_resource("CamTPTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    server_eid = nil,
    client_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

---------------------------------------------------------------------------
-- Assert helpers
---------------------------------------------------------------------------
local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("info", "[CAM_TP TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("error", "[CAM_TP TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("info", "[CAM_TP TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("error", "[CAM_TP TEST] FAIL: " .. label .. " expected non-nil") end
end

---------------------------------------------------------------------------
-- Test system
---------------------------------------------------------------------------
register_system("Update", function(world)
    state.frames = state.frames + 1

    ---------------------------------------------------------------------------
    -- Phase 0: Spawn camera entity on SERVER side
    ---------------------------------------------------------------------------
    if state.phase == 0 then
        print("info", "[CAM_TP TEST] === Phase 1: Server-side base chain + net_sync ===")
        net_info.side = "server"
        state.server_eid = spawn({
            net_mod = {
                { ["camera/third_person"] = {}, net_sync = { authority = "client", target = "owner" } },
            },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 1: Verify server-side behavior
    ---------------------------------------------------------------------------
    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.server_eid)
        assert_not_nil("P1: server entity exists", e)
        if e then
            -- Mod infrastructure
            assert_true("P1: has mod component", e:has("mod"))

            -- Sub mod loaded
            assert_true("P1: has camera/third_person", e:has("camera/third_person"))

            -- Base chain resolved
            assert_true("P1: has camera (base)", e:has("camera"))

            -- net_sync should exist with entries for both
            local ns = e:get("net_sync")
            assert_not_nil("P1: has net_sync", ns)
            if ns then
                assert_not_nil("P1: net_sync has camera/third_person", ns["camera/third_person"])
                assert_not_nil("P1: net_sync has camera (base synced)", ns["camera"])
            end

            -- Server camera base overrides authority to client (camera/server/init.lua)
            -- Check that the server's authority override was applied
            if ns and ns["camera"] then
                assert_eq("P1: camera authority is client", ns["camera"].authority, "client")
            end
        end

        -- Cleanup server entity
        if e then despawn(e) end

        state.phase = 2
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Switch to CLIENT side, spawn camera entity
    ---------------------------------------------------------------------------
    if state.phase == 2 then
        if state.frames < 3 then return end  -- wait for cleanup
        print("info", "[CAM_TP TEST] === Phase 2: Client-side base chain + defaults ===")
        net_info.side = "client"
        state.client_eid = spawn({
            net_mod = {
                { ["camera/third_person"] = {}, net_sync = { authority = "client", target = "owner" } },
            },
        }):id()
        state.phase = 3
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 3: Verify client-side behavior
    ---------------------------------------------------------------------------
    if state.phase == 3 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.client_eid)
        assert_not_nil("P2: client entity exists", e)
        if e then
            -- Mod infrastructure
            assert_true("P2: has mod component", e:has("mod"))

            -- Sub mod loaded
            assert_true("P2: has camera/third_person", e:has("camera/third_person"))

            -- Base chain resolved
            assert_true("P2: has camera (base)", e:has("camera"))

            -- Client-side camera defaults (camera/client/init.lua)
            local cam = e:get("camera")
            assert_not_nil("P2: camera has data", cam)
            if cam then
                assert_not_nil("P2: camera has yaw", cam.yaw)
                assert_not_nil("P2: camera has pitch", cam.pitch)
                assert_not_nil("P2: camera has distance", cam.distance)
                assert_not_nil("P2: camera has height", cam.height)

                -- Verify specific defaults
                assert_eq("P2: yaw default", cam.yaw, 0)
                assert_eq("P2: pitch default", cam.pitch, -0.3)
                assert_eq("P2: distance default", cam.distance, 8.0)
                assert_eq("P2: height default", cam.height, 1.5)
            end
        end

        -- Cleanup
        if e then despawn(e) end

        state.phase = 4
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 4: Results
    ---------------------------------------------------------------------------
    if state.phase == 4 then
        print("info", "")
        print("info", "=========================================")
        print("info", "[CAM_TP TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("info", "=========================================")
        if state.failed > 0 then print("error", "[CAM_TP TEST] SOME TESTS FAILED")
        else print("info", "[CAM_TP TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
