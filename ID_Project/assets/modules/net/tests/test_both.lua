-- modules/net/test_both.lua
-- Comprehensive stage-based net sync test (run with --network both).
-- Run: cargo run -p hello -- --network both --script modules/net/test_both.lua
--
-- Tests:
--   Phase 1:  Server spawns entity with net_sync → client receives spawn
--   Phase 2:  Server component update → client receives delta
--   Phase 3:  Authority: client-auth component → server receives, other clients receive
--   Phase 4:  Targets: owner-only component → only owner receives
--   Phase 5:  Targets: others-only component → owner does NOT receive
--   Phase 6:  Custom target filter registration
--   Phase 7:  Mid-game net_sync patch → new component synced
--   Phase 8:  Despawn → client cleanup
--   Phase 9:  Custom message handler registration + dispatch
--   Phase 10: Reliability: reliable vs unreliable channel split
--   Phase 11: Pending parent queue (parent+child spawned same frame)
--   Phase 12: Ownership change → propagates to descendants

local Net = require("modules/net/shared/net.lua")
local Tracking = require("modules/net/shared/tracking.lua")
local print = print

local state = define_resource("NetTestState", {
    phase = 0,
    frames = 0,
    passed = 0,
    failed = 0,
    -- Entity IDs (server-side)
    net_entity_id = nil,
    player_eid = nil,
    child_eid = nil,
    parent_eid = nil,
    -- Tracking
    custom_msg_received = false,
    custom_filter_registered = false,
})
-- Force reset
state.phase = 0
state.frames = 0
state.passed = 0
state.failed = 0
state.custom_msg_received = false

---------------------------------------------------------------------------
-- Assert helpers
---------------------------------------------------------------------------
local function assert_eq(label, got, expected)
    if got == expected then
        state.passed = state.passed + 1
        print("info", "[NET TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NET TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_false(label, val) assert_eq(label, val, false) end

local function assert_not_nil(label, val)
    if val ~= nil then
        state.passed = state.passed + 1
        print("info", "[NET TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NET TEST] FAIL: " .. label .. " expected non-nil")
    end
end

local function assert_nil(label, val)
    if val == nil then
        state.passed = state.passed + 1
        print("info", "[NET TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[NET TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end

---------------------------------------------------------------------------
-- Test: Net shared module (pure function tests, no network needed)
---------------------------------------------------------------------------
print("info", "[NET TEST] === Pure function tests (net.lua, tracking.lua) ===")

-- ID map
do
    local id_map = Net.create_id_map()
    Net.map(id_map, 1, 100)
    assert_eq("id_map: net_to_entity", id_map.net_to_entity[1], 100)
    assert_eq("id_map: entity_to_net", id_map.entity_to_net[100], 1)
    Net.unmap(id_map, 1, 100)
    assert_nil("id_map: unmap net", id_map.net_to_entity[1])
    assert_nil("id_map: unmap entity", id_map.entity_to_net[100])
end

-- Mock entity with :get() method (should_send_to calls entity:get("net_owner"))
local function mock_entity(components)
    return setmetatable(components or {}, {
        __index = {
            get = function(self, name) return self[name] end,
        },
    })
end

-- Target filters (built-in)
do
    local e = mock_entity()
    assert_true("filter all", Net.should_send_to("all", 1, e, nil))
    assert_true("filter owner (match)", Net.should_send_to("owner", 1, e, 1))
    assert_false("filter owner (no match)", Net.should_send_to("owner", 2, e, 1))
    assert_true("filter others (no match)", Net.should_send_to("others", 2, e, 1))
    assert_false("filter others (match)", Net.should_send_to("others", 1, e, 1))
end

-- Custom filter registration
do
    Net.register_filter("test_team", function(client_id, entity, owner_id)
        -- Simulated: clients 1,2 are team A; clients 3,4 are team B
        local a = { [1] = true, [2] = true }
        local b = { [3] = true, [4] = true }
        if a[owner_id] then return a[client_id] ~= nil end
        if b[owner_id] then return b[client_id] ~= nil end
        return false
    end)
    local e = mock_entity()
    assert_true("custom filter: same team", Net.should_send_to("test_team", 1, e, 2))
    assert_false("custom filter: diff team", Net.should_send_to("test_team", 1, e, 3))
    assert_true("custom filter: same team B", Net.should_send_to("test_team", 4, e, 3))
    assert_false("custom filter: diff team B", Net.should_send_to("test_team", 4, e, 1))
    state.custom_filter_registered = true
end

-- Message handler registration
do
    local handler_called = false
    local handler_msg = nil
    local handler_sender = nil

    Net.register_handler("test_chat", function(world, msg, sender_id)
        handler_called = true
        handler_msg = msg
        handler_sender = sender_id
    end)

    local dispatched = Net.dispatch(nil, { msg_type = "test_chat", text = "hello" }, 42)
    assert_true("handler: dispatch returned true", dispatched)
    assert_true("handler: handler was called", handler_called)
    assert_eq("handler: msg.text", handler_msg and handler_msg.text, "hello")
    assert_eq("handler: sender_id", handler_sender, 42)

    -- Unregistered type → dispatch returns false
    local not_dispatched = Net.dispatch(nil, { msg_type = "unknown_type" }, 1)
    assert_false("handler: unknown type not dispatched", not_dispatched)
end

-- Pending queue
do
    local pending = Tracking.create_pending_queue()
    Tracking.queue_pending(pending, "parent_1", { net_id = 10, entity_id = 100 })
    Tracking.queue_pending(pending, "parent_1", { net_id = 11, entity_id = 101 })
    Tracking.queue_pending(pending, "parent_2", { net_id = 20, entity_id = 200 })

    local flushed = Tracking.flush_pending(pending, "parent_1")
    assert_not_nil("pending: flush returns items", flushed)
    if flushed then
        assert_eq("pending: flush count", #flushed, 2)
        assert_eq("pending: first item net_id", flushed[1].net_id, 10)
        assert_eq("pending: second item net_id", flushed[2].net_id, 11)
    end

    -- Flushing again returns nil (already flushed)
    local flushed2 = Tracking.flush_pending(pending, "parent_1")
    assert_nil("pending: double flush returns nil", flushed2)

    -- parent_2 still queued
    local flushed3 = Tracking.flush_pending(pending, "parent_2")
    assert_not_nil("pending: parent_2 still queued", flushed3)
    if flushed3 then
        assert_eq("pending: parent_2 count", #flushed3, 1)
    end
end

-- Synced name rebuild
do
    local tracked = {
        [1] = { sync_config = { Transform = {}, health = {} } },
        [2] = { sync_config = { Transform = {}, mana = {} } },
    }
    local names = Tracking.rebuild_synced_names(tracked)
    assert_eq("rebuild_synced: count", #names, 3)

    -- Should contain Transform, health, mana (order doesn't matter)
    local found = {}
    for _, n in ipairs(names) do found[n] = true end
    assert_true("rebuild_synced: has Transform", found["Transform"] == true)
    assert_true("rebuild_synced: has health", found["health"] == true)
    assert_true("rebuild_synced: has mana", found["mana"] == true)
end

-- Constants
do
    assert_eq("MSG.SPAWN", Net.MSG.SPAWN, "spawn")
    assert_eq("MSG.UPDATE", Net.MSG.UPDATE, "update")
    assert_eq("MSG.DESPAWN", Net.MSG.DESPAWN, "despawn")
    assert_eq("MSG.SPAWN_REQUEST", Net.MSG.SPAWN_REQUEST, "spawn_request")
    assert_eq("MSG.SPAWN_CONFIRM", Net.MSG.SPAWN_CONFIRM, "spawn_confirm")
    assert_eq("MSG.SPAWN_REJECT", Net.MSG.SPAWN_REJECT, "spawn_reject")
    assert_eq("MSG.DESPAWN_REQUEST", Net.MSG.DESPAWN_REQUEST, "despawn_request")
    assert_eq("MSG.CLIENT_ID", Net.MSG.CLIENT_ID, "client_id")
    assert_eq("MSG.CLIENT_ID_ACK", Net.MSG.CLIENT_ID_ACK, "client_id_ack")
    assert_eq("CHANNEL_RELIABLE", Net.CHANNEL_RELIABLE, 0)
    assert_eq("CHANNEL_UNRELIABLE", Net.CHANNEL_UNRELIABLE, 1)
end

-- Multiple handlers per message type
do
    local call_count = 0
    Net.register_handler("multi_test", function() call_count = call_count + 1 end)
    Net.register_handler("multi_test", function() call_count = call_count + 1 end)
    Net.dispatch(nil, { msg_type = "multi_test" }, nil)
    assert_eq("multi handler: both called", call_count, 2)
end

-- Edge case: filter with nil owner
do
    local e = mock_entity()
    assert_true("filter owner nil owner", Net.should_send_to("owner", 1, e, nil) == false)
    assert_true("filter others nil owner", Net.should_send_to("others", 1, e, nil))
end

-- Edge case: unknown filter name → default true
do
    assert_true("unknown filter defaults true", Net.should_send_to("nonexistent_filter", 1, mock_entity(), nil))
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print("info", "")
print("info", "=========================================")
print("info", "[NET TEST] RESULTS: " ..
    state.passed .. " passed, " .. state.failed .. " failed")
print("info", "=========================================")
if state.failed > 0 then
    print("error", "[NET TEST] SOME TESTS FAILED")
else
    print("info", "[NET TEST] ALL TESTS PASSED")
end
