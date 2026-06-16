-- modules/net/tests/test_target_filtering.lua
-- Tests for net_mod entry filtering by target in spawn messages.
-- Verifies that the server correctly strips owner-only net_mod entries
-- (like camera/third_person) from spawn messages sent to non-owners.
-- Run: cargo run -p hello -- --script modules/net/tests/test_target_filtering.lua

local Net = require("modules/net/shared/net.lua")

---------------------------------------------------------------------------
-- Mock entity helper
---------------------------------------------------------------------------
local function mock_entity(components)
    components = components or {}
    return {
        get = function(self, name)
            return components[name]
        end,
    }
end

---------------------------------------------------------------------------
-- Replicate server's filter_net_mod_for_client logic for testability.
-- This is the exact same algorithm used in net/server/init.lua.
---------------------------------------------------------------------------
local function filter_net_mod_for_client(net_mod, sync_config, client_id, entity, owner_id)
    if not net_mod then return nil end

    local is_array = false
    for k, _ in pairs(net_mod) do
        if type(k) == "number" then is_array = true; break end
    end
    if not is_array then return net_mod end

    local filtered = {}
    for _, entry in ipairs(net_mod) do
        local dominated_by_target = false

        local entry_sync = entry.net_sync
        if entry_sync and type(entry_sync) == "table" then
            local target = entry_sync.targets or entry_sync.target
            if target then
                for name, config in pairs(entry) do
                    if name ~= "net_sync" and type(config) == "table" then
                        if not Net.should_send_to(target, client_id, entity, owner_id) then
                            dominated_by_target = true
                        end
                        break
                    end
                end
            end
        else
            for name, config in pairs(entry) do
                if name ~= "net_sync" and type(config) == "table" then
                    local cfg = sync_config[name]
                    if cfg then
                        local target = cfg.targets or cfg.target
                        if target and not Net.should_send_to(target, client_id, entity, owner_id) then
                            dominated_by_target = true
                        end
                    end
                    break
                end
            end
        end

        if not dominated_by_target then
            filtered[#filtered + 1] = entry
        end
    end

    return #filtered > 0 and filtered or nil
end

---------------------------------------------------------------------------
-- Test helpers
---------------------------------------------------------------------------
local passed, failed = 0, 0

local function assert_eq(label, got, expected)
    if got == expected then
        passed = passed + 1
        print("info", "[FILTER TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[FILTER TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_false(label, val) assert_eq(label, val, false) end
local function assert_nil(label, val)
    if val == nil then
        passed = passed + 1
        print("info", "[FILTER TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[FILTER TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end
local function assert_not_nil(label, val)
    if val ~= nil then
        passed = passed + 1
        print("info", "[FILTER TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[FILTER TEST] FAIL: " .. label .. " expected non-nil")
    end
end

--- Count entries in an array or return 0 for nil
local function count(t)
    if not t then return 0 end
    local n = 0
    for _ in ipairs(t) do n = n + 1 end
    return n
end

--- Check if an array of net_mod entries contains a specific mod name
local function has_entry(net_mod, mod_name)
    if not net_mod then return false end
    for _, entry in ipairs(net_mod) do
        for name, config in pairs(entry) do
            if name == mod_name and type(config) == "table" then
                return true
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Test 1: Owner-only entries stripped for non-owner
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 1. Owner-only entries stripped for non-owner ===")
do
    local owner_id = 1
    local entity = mock_entity()

    -- Simulates the player spawner's net_mod:
    local net_mod = {
        { player = {} },
        { input = {} },
        { ["camera/third_person"] = {}, net_sync = { authority = "client", target = "owner" } },
        { movement = {} },
        { animation = { model = "test" } },
    }
    local sync_config = {
        player = { authority = "server" },
        input = { authority = "server" },
        ["camera/third_person"] = { authority = "client", target = "owner" },
        movement = { authority = "server" },
        animation = { authority = "server" },
    }

    -- Owner (client 1) should get ALL entries including camera/third_person
    local owner_result = filter_net_mod_for_client(net_mod, sync_config, 1, entity, owner_id)
    assert_not_nil("T1: owner gets net_mod", owner_result)
    assert_eq("T1: owner gets 5 entries", count(owner_result), 5)
    assert_true("T1: owner has camera/third_person", has_entry(owner_result, "camera/third_person"))
    assert_true("T1: owner has player", has_entry(owner_result, "player"))

    -- Non-owner (client 2) should NOT get camera/third_person
    local other_result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, owner_id)
    assert_not_nil("T1: non-owner gets net_mod", other_result)
    assert_eq("T1: non-owner gets 4 entries", count(other_result), 4)
    assert_false("T1: non-owner missing camera/third_person", has_entry(other_result, "camera/third_person"))
    assert_true("T1: non-owner has player", has_entry(other_result, "player"))
    assert_true("T1: non-owner has movement", has_entry(other_result, "movement"))
end

---------------------------------------------------------------------------
-- Test 2: targets array (e.g. targets = { "owner" })
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 2. targets array ===")
do
    local owner_id = 1
    local entity = mock_entity()

    local net_mod = {
        { ["camera/third_person"] = {}, net_sync = { authority = "client", targets = { "owner" } } },
        { movement = {} },
    }
    local sync_config = {
        ["camera/third_person"] = { authority = "client", targets = { "owner" } },
        movement = { authority = "server" },
    }

    -- Owner gets both
    local owner_result = filter_net_mod_for_client(net_mod, sync_config, 1, entity, owner_id)
    assert_eq("T2: owner gets 2 entries", count(owner_result), 2)

    -- Non-owner gets only movement
    local other_result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, owner_id)
    assert_eq("T2: non-owner gets 1 entry", count(other_result), 1)
    assert_false("T2: non-owner missing camera", has_entry(other_result, "camera/third_person"))
    assert_true("T2: non-owner has movement", has_entry(other_result, "movement"))
end

---------------------------------------------------------------------------
-- Test 3: Numeric client_id targets
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 3. Numeric client_id targets ===")
do
    local entity = mock_entity()

    local net_mod = {
        { debug_panel = {}, net_sync = { authority = "server", targets = { 42, 99 } } },
        { health = {} },
    }
    local sync_config = {
        debug_panel = { authority = "server", targets = { 42, 99 } },
        health = { authority = "server" },
    }

    -- Client 42 gets both
    local r42 = filter_net_mod_for_client(net_mod, sync_config, 42, entity, nil)
    assert_eq("T3: client 42 gets 2 entries", count(r42), 2)

    -- Client 99 gets both
    local r99 = filter_net_mod_for_client(net_mod, sync_config, 99, entity, nil)
    assert_eq("T3: client 99 gets 2 entries", count(r99), 2)

    -- Client 1 gets only health
    local r1 = filter_net_mod_for_client(net_mod, sync_config, 1, entity, nil)
    assert_eq("T3: client 1 gets 1 entry", count(r1), 1)
    assert_false("T3: client 1 missing debug_panel", has_entry(r1, "debug_panel"))
end

---------------------------------------------------------------------------
-- Test 4: All entries filtered → returns nil
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 4. All entries filtered → nil ===")
do
    local entity = mock_entity()

    local net_mod = {
        { secret = {}, net_sync = { authority = "server", target = "owner" } },
    }
    local sync_config = {
        secret = { authority = "server", target = "owner" },
    }

    -- Non-owner with single owner-only entry → nil
    local result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, 1)
    assert_nil("T4: all filtered → nil", result)
end

---------------------------------------------------------------------------
-- Test 5: No target → all pass
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 5. No target specified → all pass ===")
do
    local entity = mock_entity()

    local net_mod = {
        { player = {} },
        { movement = {} },
        { animation = {} },
    }
    local sync_config = {
        player = { authority = "server" },
        movement = { authority = "server" },
        animation = { authority = "server" },
    }

    -- Every client gets all entries when no target is specified
    local result = filter_net_mod_for_client(net_mod, sync_config, 99, entity, 1)
    assert_eq("T5: no target → all pass", count(result), 3)
end

---------------------------------------------------------------------------
-- Test 6: "others" target — only non-owners get the entry
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 6. 'others' target ===")
do
    local entity = mock_entity()

    local net_mod = {
        { nametag = {}, net_sync = { authority = "server", target = "others" } },
        { health = {} },
    }
    local sync_config = {
        nametag = { authority = "server", target = "others" },
        health = { authority = "server" },
    }

    -- Owner should NOT get nametag
    local owner_result = filter_net_mod_for_client(net_mod, sync_config, 1, entity, 1)
    assert_eq("T6: owner gets 1 entry (no nametag)", count(owner_result), 1)
    assert_false("T6: owner missing nametag", has_entry(owner_result, "nametag"))

    -- Non-owner gets both
    local other_result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, 1)
    assert_eq("T6: non-owner gets 2 entries", count(other_result), 2)
    assert_true("T6: non-owner has nametag", has_entry(other_result, "nametag"))
end

---------------------------------------------------------------------------
-- Test 7: Fallback to sync_config when no inline net_sync override
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 7. Fallback to sync_config ===")
do
    local entity = mock_entity()

    -- No inline net_sync override on the entry, but sync_config has target
    local net_mod = {
        { secret_component = {} },
        { public_component = {} },
    }
    local sync_config = {
        secret_component = { authority = "server", target = "owner" },
        public_component = { authority = "server" },
    }

    -- Owner gets both
    local owner_result = filter_net_mod_for_client(net_mod, sync_config, 1, entity, 1)
    assert_eq("T7: owner gets 2", count(owner_result), 2)

    -- Non-owner only gets public
    local other_result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, 1)
    assert_eq("T7: non-owner gets 1", count(other_result), 1)
    assert_false("T7: non-owner missing secret", has_entry(other_result, "secret_component"))
    assert_true("T7: non-owner has public", has_entry(other_result, "public_component"))
end

---------------------------------------------------------------------------
-- Test 8: Mixed targets in same net_mod array
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 8. Mixed targets ===")
do
    local entity = mock_entity()

    local net_mod = {
        { hud = {}, net_sync = { authority = "client", target = "owner" } },
        { nametag = {}, net_sync = { authority = "server", target = "others" } },
        { health = {} },
    }
    local sync_config = {
        hud = { authority = "client", target = "owner" },
        nametag = { authority = "server", target = "others" },
        health = { authority = "server" },
    }

    -- Owner: gets hud + health, NOT nametag
    local owner_result = filter_net_mod_for_client(net_mod, sync_config, 1, entity, 1)
    assert_eq("T8: owner gets 2 entries", count(owner_result), 2)
    assert_true("T8: owner has hud", has_entry(owner_result, "hud"))
    assert_false("T8: owner missing nametag", has_entry(owner_result, "nametag"))
    assert_true("T8: owner has health", has_entry(owner_result, "health"))

    -- Non-owner: gets nametag + health, NOT hud
    local other_result = filter_net_mod_for_client(net_mod, sync_config, 2, entity, 1)
    assert_eq("T8: non-owner gets 2 entries", count(other_result), 2)
    assert_false("T8: non-owner missing hud", has_entry(other_result, "hud"))
    assert_true("T8: non-owner has nametag", has_entry(other_result, "nametag"))
    assert_true("T8: non-owner has health", has_entry(other_result, "health"))
end

---------------------------------------------------------------------------
-- Test 9: nil net_mod → nil
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 9. nil net_mod ===")
do
    local result = filter_net_mod_for_client(nil, {}, 1, mock_entity(), nil)
    assert_nil("T9: nil net_mod → nil", result)
end

---------------------------------------------------------------------------
-- Test 10: Dictionary form net_mod passes through unchanged
---------------------------------------------------------------------------
print("info", "[FILTER TEST] === 10. Dict form passes through ===")
do
    local net_mod = { camera = {}, player = {} }
    local result = filter_net_mod_for_client(net_mod, {}, 1, mock_entity(), nil)
    assert_not_nil("T10: dict form passes through", result)
    assert_not_nil("T10: camera preserved", result.camera)
    assert_not_nil("T10: player preserved", result.player)
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print("info", "")
print("info", "=========================================")
print("info", "[FILTER TEST] RESULTS: " .. passed .. " passed, " .. failed .. " failed")
print("info", "=========================================")
if failed > 0 then
    print("error", "[FILTER TEST] SOME TESTS FAILED")
else
    print("info", "[FILTER TEST] ALL TESTS PASSED")
end
