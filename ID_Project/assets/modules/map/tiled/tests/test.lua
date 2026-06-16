-- modules/map/tiled/tests/test.lua
-- Stage-based test for map/tiled mod.
-- Run: cargo run -p hello -- --script modules/map/tiled/tests/test.lua

require("modules/mod/init.lua")
local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("TiledMapTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    map_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[MAP/TILED TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[MAP/TILED TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[MAP/TILED TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[MAP/TILED TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[MAP/TILED TEST] === Phase 1: Spawn map/tiled ===")
        state.map_eid = spawn({
            mod = {
                ["map/tiled"] = { tmx_path = "map.tmx" },
                script = "modules/map/tiled/server/init.lua",
            },
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.map_eid)
        assert_not_nil("P1: map entity exists", e)
        if e then
            assert_true("P1: has map/tiled component", e:has("map/tiled"))
            local children = world:query({ entities = { e:id() } })
            assert_true("P1: has child tiled map entity", #children >= 2)
            local tiled = world:query({ with = { "TiledMap" } })
            assert_true("P1: has TiledMap component", #tiled > 0)
        end
        if e then despawn(e) end
        state.phase = 2
        state.frames = 0
        return
    end

    if state.phase == 2 then
        print("")
        print("=========================================")
        print("[MAP/TILED TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[MAP/TILED TEST] SOME TESTS FAILED")
        else print("[MAP/TILED TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
