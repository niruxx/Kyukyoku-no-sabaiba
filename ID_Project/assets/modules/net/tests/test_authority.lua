-- modules/net/test_authority.lua
-- Edge-case tests for net authority, targets, and multi-client scenarios.
-- These test the shared logic directly (no live network needed).
-- Run: cargo run -p hello -- --script modules/net/test_authority.lua
--
-- Tests:
--   1. Server-auth component: only server can write
--   2. Client-auth component: only owner can write
--   3. Owner target: only owner receives
--   4. Others target: everyone except owner receives
--   5. Mixed authority+target on same entity
--   6. Authority check: non-owner client rejected
--   7. Unreliable components excluded from reliable batch
--   8. Multiple entities with different owners
--   9. Custom target filter edge cases
--  10. Ownership change updates target routing
--  11. Collect changed components with mixed sync config
--  12. Edge: entity with no synced components
--  13. Edge: empty id_map operations
--  14. Edge: filter with nil/missing values

local Net = require("modules/net/shared/net.lua")
local Tracking = require("modules/net/shared/tracking.lua")

--- Create a mock entity with :get() support for testing.
--- Net.should_send_to calls entity:get("net_owner"), so mocks need this method.
local function mock_entity(components)
    components = components or {}
    return {
        get = function(self, name)
            return components[name]
        end,
    }
end

--- Shorthand: mock entity with a specific owner
local function mock_owned(owner_id)
    if owner_id then
        return mock_entity({ net_owner = { client_id = owner_id } })
    end
    return mock_entity()
end

local passed, failed = 0, 0

local function assert_eq(label, got, expected)
    if got == expected then
        passed = passed + 1
        print("info", "[AUTH TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[AUTH TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_false(label, val) assert_eq(label, val, false) end

local function assert_nil(label, val)
    if val == nil then
        passed = passed + 1
        print("info", "[AUTH TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[AUTH TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end

local function assert_not_nil(label, val)
    if val ~= nil then
        passed = passed + 1
        print("info", "[AUTH TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[AUTH TEST] FAIL: " .. label .. " expected non-nil")
    end
end

---------------------------------------------------------------------------
-- Test 1: Server-auth component filter behavior
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 1. Server-auth filter ===")
do
    local cfg = { authority = "server", target = "all" }
    -- Server-auth: should send to ALL clients, including owner
    assert_true("server-auth sends to owner", Net.should_send_to(cfg.target, 1, mock_entity(), 1))
    assert_true("server-auth sends to non-owner", Net.should_send_to(cfg.target, 2, mock_entity(), 1))
    assert_true("server-auth sends to random", Net.should_send_to(cfg.target, 99, mock_entity(), 1))
end

---------------------------------------------------------------------------
-- Test 2: Client-auth component
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 2. Client-auth: skip owner on outbound ===")
do
    -- The outbound loop checks: if authority == "client" and client_id == owner_id, skip
    -- This is application-level logic, not in Net.should_send_to.
    -- We test the target filter behavior:
    local cfg = { authority = "client", target = "all" }
    -- The target says "all", so should_send_to returns true for everyone
    assert_true("client-auth target=all sends to everyone", Net.should_send_to(cfg.target, 1, mock_entity(), 1))
    -- But the server outbound loop additionally skips the owner â€” that's tested in integration
end

---------------------------------------------------------------------------
-- Test 3: Owner target filter
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 3. Owner target ===")
do
    -- owner=1
    assert_true("owner filter: owner receives", Net.should_send_to("owner", 1, mock_entity(), 1))
    assert_false("owner filter: non-owner rejected", Net.should_send_to("owner", 2, mock_entity(), 1))
    assert_false("owner filter: another non-owner", Net.should_send_to("owner", 3, mock_entity(), 1))

    -- owner=nil (no owner set)
    assert_false("owner filter: nil owner â†’ nobody", Net.should_send_to("owner", 1, mock_entity(), nil))
end

---------------------------------------------------------------------------
-- Test 4: Others target filter
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 4. Others target ===")
do
    -- owner=1
    assert_false("others filter: owner excluded", Net.should_send_to("others", 1, mock_entity(), 1))
    assert_true("others filter: non-owner included", Net.should_send_to("others", 2, mock_entity(), 1))
    assert_true("others filter: another non-owner", Net.should_send_to("others", 3, mock_entity(), 1))

    -- owner=nil
    assert_true("others filter: nil owner â†’ everyone", Net.should_send_to("others", 1, mock_entity(), nil))
end

---------------------------------------------------------------------------
-- Test 5: Mixed authority + target on same entity
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 5. Mixed authority+target ===")
do
    local sync_config = {
        Transform = { authority = "server", target = "all" },
        camera_input = { authority = "client", target = "owner" },
        health = { authority = "server", target = "all" },
        secret_data = { authority = "server", target = "owner" },
    }

    -- Client 1 is the owner
    local owner_id = 1
    local client_ids = { 1, 2, 3 }

    for _, cid in ipairs(client_ids) do
        local receives = {}
        for comp, cfg in pairs(sync_config) do
            local should_send = Net.should_send_to(cfg.target, cid, mock_entity(), owner_id)

            -- Additional outbound skip for client-auth â†’ owner
            local skipped_by_authority = (cfg.authority == "client" and cid == owner_id)

            if should_send and not skipped_by_authority then
                receives[#receives + 1] = comp
            end
        end

        if cid == owner_id then
            -- Owner should receive: Transform, health, secret_data
            -- NOT camera_input (client-auth + owner â†’ skip)
            local found = {}
            for _, c in ipairs(receives) do found[c] = true end
            assert_true("mixed: owner gets Transform", found["Transform"] == true)
            assert_true("mixed: owner gets health", found["health"] == true)
            assert_true("mixed: owner gets secret_data", found["secret_data"] == true)
            assert_nil("mixed: owner NOT get camera_input", found["camera_input"])
        else
            -- Non-owner should receive: Transform, health
            -- NOT camera_input (target=owner), NOT secret_data (target=owner)
            local found = {}
            for _, c in ipairs(receives) do found[c] = true end
            assert_true("mixed: client " .. cid .. " gets Transform", found["Transform"] == true)
            assert_true("mixed: client " .. cid .. " gets health", found["health"] == true)
            assert_nil("mixed: client " .. cid .. " NOT get secret_data", found["secret_data"])
            assert_nil("mixed: client " .. cid .. " NOT get camera_input", found["camera_input"])
        end
    end
end

---------------------------------------------------------------------------
-- Test 6: Authority check simulation (non-owner rejected)
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 6. Non-owner client rejected ===")
do
    local sync_config = {
        input = { authority = "client" },
        Transform = { authority = "server" },
    }

    -- Simulate server inbound: client 2 tries to update "input" but owner is client 1
    local owner_id = 1
    local sender_id = 2
    local accepted = {}

    for comp, cfg in pairs(sync_config) do
        if cfg.authority == "client" then
            -- Server checks: is sender the owner?
            if sender_id == owner_id then
                accepted[comp] = true
            end
        end
    end

    assert_nil("authority: non-owner input rejected", accepted["input"])

    -- Now test with correct owner
    sender_id = 1
    accepted = {}
    for comp, cfg in pairs(sync_config) do
        if cfg.authority == "client" then
            if sender_id == owner_id then
                accepted[comp] = true
            end
        end
    end
    assert_true("authority: owner input accepted", accepted["input"] == true)
end

---------------------------------------------------------------------------
-- Test 7: Reliable vs unreliable channel split
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 7. Reliable/unreliable split ===")
do
    local sync_config = {
        Transform = { authority = "server", reliable = false },
        health = { authority = "server" },  -- reliable = true (default)
        mana = { authority = "server", reliable = true },
        velocity = { authority = "server", reliable = false },
    }

    local reliable, unreliable = {}, {}
    for comp, cfg in pairs(sync_config) do
        if cfg.reliable == false then
            unreliable[comp] = true
        else
            reliable[comp] = true
        end
    end

    assert_true("channel: Transform is unreliable", unreliable["Transform"] == true)
    assert_true("channel: velocity is unreliable", unreliable["velocity"] == true)
    assert_true("channel: health is reliable", reliable["health"] == true)
    assert_true("channel: mana is reliable", reliable["mana"] == true)
    assert_nil("channel: Transform NOT in reliable", reliable["Transform"])
    assert_nil("channel: health NOT in unreliable", unreliable["health"])
end

---------------------------------------------------------------------------
-- Test 8: Multiple entities with different owners
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 8. Multiple entities, different owners ===")
do
    -- Entity A owned by client 1, Entity B owned by client 2
    local entities = {
        { net_id = 1, owner = 1, sync = { hp = { target = "owner" } } },
        { net_id = 2, owner = 2, sync = { hp = { target = "owner" } } },
    }

    -- Client 1 should receive entity A's hp but NOT entity B's hp
    for _, ent in ipairs(entities) do
        for comp, cfg in pairs(ent.sync) do
            local client1_gets = Net.should_send_to(cfg.target, 1, mock_entity(), ent.owner)
            local client2_gets = Net.should_send_to(cfg.target, 2, mock_entity(), ent.owner)

            if ent.net_id == 1 then
                assert_true("multi-entity: c1 gets entity_A." .. comp, client1_gets)
                assert_false("multi-entity: c2 NOT get entity_A." .. comp, client2_gets)
            else
                assert_false("multi-entity: c1 NOT get entity_B." .. comp, client1_gets)
                assert_true("multi-entity: c2 gets entity_B." .. comp, client2_gets)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Test 9: Custom target filter edge cases
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 9. Custom filter edge cases ===")
do
    -- "nearby" filter: only clients within "range" (simulated via a set)
    local nearby_clients = { [1] = true, [3] = true }
    Net.register_filter("nearby", function(client_id, entity, owner_id)
        return nearby_clients[client_id] == true
    end)

    assert_true("nearby: client 1 in range", Net.should_send_to("nearby", 1, mock_entity(), nil))
    assert_false("nearby: client 2 out of range", Net.should_send_to("nearby", 2, mock_entity(), nil))
    assert_true("nearby: client 3 in range", Net.should_send_to("nearby", 3, mock_entity(), nil))

    -- Update nearby set (simulates movement)
    nearby_clients[1] = nil
    nearby_clients[2] = true
    assert_false("nearby: client 1 moved out", Net.should_send_to("nearby", 1, mock_entity(), nil))
    assert_true("nearby: client 2 moved in", Net.should_send_to("nearby", 2, mock_entity(), nil))
end

---------------------------------------------------------------------------
-- Test 10: Ownership change re-routes targets
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 10. Ownership change re-routes ===")
do
    local sync_config = {
        private_data = { target = "owner" },
    }

    local old_owner = 1
    local new_owner = 2

    -- Before change: client 1 receives, client 2 doesn't
    assert_true("ownership: old owner receives", Net.should_send_to("owner", 1, mock_entity(), old_owner))
    assert_false("ownership: new owner doesn't yet", Net.should_send_to("owner", 2, mock_entity(), old_owner))

    -- After change: client 2 receives, client 1 doesn't
    assert_false("ownership: old owner no longer", Net.should_send_to("owner", 1, mock_entity(), new_owner))
    assert_true("ownership: new owner now receives", Net.should_send_to("owner", 2, mock_entity(), new_owner))
end

---------------------------------------------------------------------------
-- Test 11: Synced name rebuild edge cases
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 11. Rebuild synced names edge cases ===")
do
    -- Empty tracked
    local empty = Tracking.rebuild_synced_names({})
    assert_eq("rebuild empty: count", #empty, 0)

    -- Duplicate component names across entities
    local dupes = {
        [1] = { sync_config = { Transform = {}, health = {} } },
        [2] = { sync_config = { Transform = {}, health = {}, mana = {} } },
        [3] = { sync_config = { Transform = {} } },
    }
    local names = Tracking.rebuild_synced_names(dupes)
    -- Should have exactly 3 unique names
    assert_eq("rebuild dupes: unique count", #names, 3)
end

---------------------------------------------------------------------------
-- Test 12: ID map edge cases
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 12. ID map edge cases ===")
do
    local id_map = Net.create_id_map()

    -- Unmap non-existent entry (should not error)
    Net.unmap(id_map, 999, 999)
    assert_nil("id_map: unmap nonexistent", id_map.net_to_entity[999])

    -- Map, then re-map same net_id to different entity
    Net.map(id_map, 1, 100)
    Net.map(id_map, 1, 200)  -- Overwrite
    assert_eq("id_map: remap overwrites", id_map.net_to_entity[1], 200)
    -- Old entity still points to net_id 1 (no auto-cleanup)
    assert_eq("id_map: old entity still mapped", id_map.entity_to_net[100], 1)
    -- New entity points to net_id 1
    assert_eq("id_map: new entity mapped", id_map.entity_to_net[200], 1)

    -- Multiple net_ids for same entity (shouldn't happen but test it)
    Net.map(id_map, 2, 200)
    assert_eq("id_map: entity_to_net overwritten", id_map.entity_to_net[200], 2)
end

---------------------------------------------------------------------------
-- Test 13: Pending queue edge cases
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 13. Pending queue edge cases ===")
do
    local pending = Tracking.create_pending_queue()

    -- Flush empty queue â†’ nil
    assert_nil("pending: flush empty", Tracking.flush_pending(pending, "nobody"))

    -- Queue single item
    Tracking.queue_pending(pending, "parent_a", { id = 1 })
    local items = Tracking.flush_pending(pending, "parent_a")
    assert_not_nil("pending: single item", items)
    if items then assert_eq("pending: single item count", #items, 1) end

    -- Queue many items under same key
    for i = 1, 100 do
        Tracking.queue_pending(pending, "bulk", { id = i })
    end
    local bulk = Tracking.flush_pending(pending, "bulk")
    assert_not_nil("pending: bulk items", bulk)
    if bulk then assert_eq("pending: bulk count", #bulk, 100) end

    -- Numeric keys
    Tracking.queue_pending(pending, 42, { data = "numeric key" })
    local num_items = Tracking.flush_pending(pending, 42)
    assert_not_nil("pending: numeric key", num_items)
end

---------------------------------------------------------------------------
-- Test 14: Filter with nil/missing values
---------------------------------------------------------------------------
print("info", "[AUTH TEST] === 14. Filter nil/missing edge cases ===")
do
    -- nil filter name â†’ defaults to "all"
    assert_true("nil filter â†’ all", Net.should_send_to(nil, 1, mock_entity(), nil))

    -- owner filter where both args are nil
    assert_false("owner: both nil", Net.should_send_to("owner", nil, mock_entity(), nil))

    -- others filter where client_id is nil
    assert_false("others: nil client != nil owner", Net.should_send_to("others", nil, mock_entity(), nil))
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print("info", "")
print("info", "=========================================")
print("info", "[AUTH TEST] RESULTS: " .. passed .. " passed, " .. failed .. " failed")
print("info", "=========================================")
if failed > 0 then
    print("error", "[AUTH TEST] SOME TESTS FAILED")
else
    print("info", "[AUTH TEST] ALL TESTS PASSED")
end
