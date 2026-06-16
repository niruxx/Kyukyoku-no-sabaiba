-- modules/player/tests/test.lua
-- Stage-based test for player mod (spawner + player lifecycle).
-- Run: cargo run -p hello -- --script modules/player/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("PlayerTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    net_entity_id = nil,
    spawner_eid = nil,
    net_client_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[PLAYER TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[PLAYER TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[PLAYER TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[PLAYER TEST] FAIL: " .. label .. " expected non-nil") end
end

-- Create a mock net entity
local net_entity = spawn({
    net = { mode = "server", both_mode = true, name = "test", port = 0 },
    Transform = {},
})

register_system("First", function()
    state.net_entity_id = net_entity:id()
    local net_info = define_resource("NetInfo", {})
    net_info.net_entity_id = state.net_entity_id
    return true
end)

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[PLAYER TEST] === Phase 1: Spawn player_spawner ===")
        state.spawner_eid = spawn({
            mod = { 
                ["player/spawner"] = {}, 
                script = "modules/player/spawner/init.lua"
            },
        }):with_parent(state.net_entity_id):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.spawner_eid)
        assert_not_nil("P1: spawner entity exists", e)
        if e then
            assert_true("P1: has player_spawner component", e:has("player/spawner"))
        end

        -- Check spawn points were created
        local spawn_points = world:query({ with = { "spawn_point" } })
        assert_true("P1: has spawn points", #spawn_points > 0)
        assert_eq("P1: has 8 spawn points", #spawn_points, 8)

        -- Check all unoccupied
        local all_free = true
        for _, sp in ipairs(spawn_points) do
            local spd = sp:get("spawn_point")
            if spd and spd.occupied then all_free = false end
        end
        assert_true("P1: all spawn points free", all_free)

        -- Phase 2: simulate client connect via net_client entity
        print("[PLAYER TEST] === Phase 2: Simulate client connect ===")
        state.net_client_eid = spawn({ net_client = { client_id = 42 } })
            :with_parent(state.net_entity_id):id()
        state.phase = 2
        state.frames = 0
        return
    end

    if state.phase == 2 then
        if state.frames < 15 then return end
        -- Check player entity was created
        local players = world:query({ with = { "player" } })
        assert_true("P2: player entity created", #players > 0)
        if #players > 0 then
            local player = players[1]:get("player")
            assert_not_nil("P2: player has data", player)
            if player then
                assert_eq("P2: player client_id is 42", player.client_id, 42)
                assert_not_nil("P2: player has spawn_index", player.spawn_index)
            end
        end

        -- Check one spawn point is now occupied
        local spawn_points = world:query({ with = { "spawn_point" } })
        local occupied_count = 0
        for _, sp in ipairs(spawn_points) do
            local spd = sp:get("spawn_point")
            if spd and spd.occupied then occupied_count = occupied_count + 1 end
        end
        assert_eq("P2: exactly 1 spawn occupied", occupied_count, 1)

        -- Phase 3: simulate disconnect by despawning net_client entity
        print("[PLAYER TEST] === Phase 3: Simulate disconnect ===")
        local nc = world:get_entity(state.net_client_eid)
        if nc then despawn(nc) end
        state.phase = 3
        state.frames = 0
        return
    end

    if state.phase == 3 then
        if state.frames < 5 then return end
        -- Player should be despawned
        local players = world:query({ with = { "player" } })
        assert_eq("P3: player despawned", #players, 0)

        -- All spawn points should be free
        local spawn_points = world:query({ with = { "spawn_point" } })
        local occupied_count = 0
        for _, sp in ipairs(spawn_points) do
            local spd = sp:get("spawn_point")
            if spd and spd.occupied then occupied_count = occupied_count + 1 end
        end
        assert_eq("P3: all spawn points free", occupied_count, 0)

        state.phase = 4
        state.frames = 0
        return
    end

    if state.phase == 4 then
        print("")
        print("=========================================")
        print("[PLAYER TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[PLAYER TEST] SOME TESTS FAILED")
        else print("[PLAYER TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
