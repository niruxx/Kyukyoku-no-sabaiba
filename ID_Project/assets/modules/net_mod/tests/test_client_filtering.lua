-- modules/net_mod/tests/test_client_filtering.lua
-- Tests for client-side net_mod entry filtering by target.
-- Verifies that filter_entries_for_client correctly skips entries
-- whose net_sync target excludes the local client.
-- Run: cargo run -p hello -- --script modules/net_mod/tests/test_client_filtering.lua

local Net = require("modules/net/shared/net.lua")
local helpers = require("modules/net_mod/helpers.lua")

---------------------------------------------------------------------------
-- Mock entity helper
---------------------------------------------------------------------------
local function mock_entity(components)
    components = components or {}
    return {
        get = function(self, name)
            return components[name]
        end,
        id = function(self) return 1 end,
    }
end

---------------------------------------------------------------------------
-- Replicate filter_entries_for_client from instance.lua for unit testing.
-- This is the same algorithm — we test it in isolation so the test can
-- run without the full ECS runtime.
---------------------------------------------------------------------------
local function filter_entries_for_client(entries, entity, my_id)
    if not my_id then return entries end

    local net_owner = entity:get("net_owner")
    local owner_id = net_owner and net_owner.client_id
    local existing_sync = entity:get("net_sync") or {}

    local filtered = {}
    for _, entry in ipairs(entries) do
        local target
        local has_override = (entry.net_sync_override ~= nil)

        -- Explicit net_sync = false → local-only, always include
        if entry.net_sync_override == false then
            table.insert(filtered, entry)
            goto continue
        end

        -- Check inline net_sync override first (array-form entries)
        if has_override and type(entry.net_sync_override) == "table" then
            target = entry.net_sync_override.targets or entry.net_sync_override.target
        end

        -- Fallback to entity's net_sync config
        if not target then
            local cfg = existing_sync[entry.name]
            if cfg and type(cfg) == "table" then
                target = cfg.targets or cfg.target
            elseif not cfg and not has_override then
                -- Entry is NOT in net_sync and has no inline override.
                -- The server filtered it from our net_sync (target doesn't
                -- match us). Skip this entry.
                goto continue
            end
        end

        -- nil target means "all" — include the entry
        if not target or Net.should_send_to(target, my_id, entity, owner_id) then
            table.insert(filtered, entry)
        end

        ::continue::
    end
    return filtered
end

---------------------------------------------------------------------------
-- Test helpers
---------------------------------------------------------------------------
local passed, failed = 0, 0

local function assert_eq(label, got, expected)
    if got == expected then
        passed = passed + 1
        print("info", "[CLIENT FILTER TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[CLIENT FILTER TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

---------------------------------------------------------------------------
-- Test 1: Owner-only entries filtered for non-owner
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 1. Owner-only entries filtered for non-owner ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            player = { authority = "server" },
            ["camera/third_person"] = { authority = "client", target = "owner" },
            movement = { authority = "server" },
        },
    })

    -- Simulates parsed net_mod entries
    local entries = {
        { name = "player", config = {} },
        { name = "camera/third_person", config = {} },
        { name = "movement", config = {} },
    }

    -- Owner (client 100) gets all entries
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T1: owner gets 3 entries", #owner_result, 3)

    -- Non-owner (client 200) should NOT get camera/third_person
    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T1: non-owner gets 2 entries", #other_result, 2)

    -- Verify the filtered entries
    local has_camera = false
    for _, e in ipairs(other_result) do
        if e.name == "camera/third_person" then has_camera = true end
    end
    assert_eq("T1: non-owner missing camera", has_camera, false)
end

---------------------------------------------------------------------------
-- Test 2: Inline net_sync override takes precedence
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 2. Inline net_sync override ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = { health = { authority = "server" } },
    })

    local entries = {
        { name = "sidebar", config = {}, net_sync_override = { authority = "client", target = "owner" } },
        { name = "health", config = {} },
    }

    -- Owner gets both
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T2: owner gets 2 entries", #owner_result, 2)

    -- Non-owner gets only health
    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T2: non-owner gets 1 entry", #other_result, 1)
    assert_eq("T2: non-owner gets health", other_result[1].name, "health")
end

---------------------------------------------------------------------------
-- Test 3: Dict-form entries (sidebar patches like { [mod] = config })
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 3. Dict-form entries via parse_net_mod_entries ===")
do
    -- Simulate a net_mod that has been patched with a dict-form entry
    local net_mod = {
        -- Array entries (from spawner)
        [1] = { player = {} },
        [2] = { sidebar = {}, net_sync = { authority = "client", target = "owner" } },
        -- Dict entry (from sidebar:open_panels patch)
        ["git/scope/selector"] = { container_id = 6 },
    }

    local entries = helpers.parse_net_mod_entries(net_mod)

    -- Should have 3 entries: player, sidebar, git/scope/selector
    assert_eq("T3: parsed 3 entries", #entries, 3)

    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            player = { authority = "server" },
            sidebar = { authority = "client", target = "owner" },
            ["git/scope/selector"] = { authority = "client", target = "owner" },
        },
    })

    -- Owner gets all 3
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T3: owner gets 3 entries", #owner_result, 3)

    -- Non-owner should only get player (sidebar and git/scope/selector are owner-only)
    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T3: non-owner gets 1 entry", #other_result, 1)
    assert_eq("T3: non-owner gets player", other_result[1].name, "player")
end

---------------------------------------------------------------------------
-- Test 4: No owner set — all entries pass
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 4. No owner — all pass ===")
do
    local entity = mock_entity({
        -- No net_owner
        net_sync = {
            player = { authority = "server" },
            camera = { authority = "client", target = "owner" },
        },
    })

    local entries = {
        { name = "player", config = {} },
        { name = "camera", config = {} },
    }

    -- No owner → "owner" target returns false for everyone (cid ~= nil owner)
    local result = filter_entries_for_client(entries, entity, 100)
    -- owner filter: cid == oid, but oid is nil → false
    -- So camera should be filtered out
    assert_eq("T4: no owner, camera filtered", #result, 1)
    assert_eq("T4: only player remains", result[1].name, "player")
end

---------------------------------------------------------------------------
-- Test 5: "others" target
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 5. 'others' target ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            nametag = { authority = "server", target = "others" },
            health = { authority = "server" },
        },
    })

    local entries = {
        { name = "nametag", config = {} },
        { name = "health", config = {} },
    }

    -- Owner should NOT get nametag
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T5: owner gets 1 (no nametag)", #owner_result, 1)
    assert_eq("T5: owner gets health", owner_result[1].name, "health")

    -- Non-owner gets both
    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T5: non-owner gets 2", #other_result, 2)
end

---------------------------------------------------------------------------
-- Test 6: No client_id — passthrough (server side)
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 6. No client_id — passthrough ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            camera = { authority = "client", target = "owner" },
        },
    })

    local entries = {
        { name = "camera", config = {} },
    }

    -- nil client_id = server side, no filtering
    local result = filter_entries_for_client(entries, entity, nil)
    assert_eq("T6: nil client_id passthrough", #result, 1)
end

---------------------------------------------------------------------------
-- Test 7: targets array
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 7. targets array ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            debug = { authority = "server", targets = { "owner" } },
            health = { authority = "server" },
        },
    })

    local entries = {
        { name = "debug", config = {} },
        { name = "health", config = {} },
    }

    -- Owner gets both
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T7: owner gets 2", #owner_result, 2)

    -- Non-owner gets only health
    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T7: non-owner gets 1", #other_result, 1)
    assert_eq("T7: non-owner gets health", other_result[1].name, "health")
end

---------------------------------------------------------------------------
-- Test 8: Sidebar bug — dict-form entry missing from non-owner's net_sync
-- The server filters owner-only entries from net_sync before sending to
-- non-owners. But net_mod is sent in full (infrastructure). The client
-- must exclude entries not in its net_sync and without inline overrides.
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 8. Sidebar bug: dict entry filtered from net_sync ===")
do
    -- Non-owner entity: server filtered git/scope/selector from net_sync
    local non_owner_entity = mock_entity({
        net_owner = { client_id = 100 },  -- Owner is player 100
        net_sync = {
            player = { authority = "server" },
            -- git/scope/selector is ABSENT — server filtered it (target=owner)
        },
    })

    -- net_mod has ALL entries (sent as infrastructure)
    local entries = helpers.parse_net_mod_entries({
        [1] = { player = {} },
        ["git/scope/selector"] = { container_id = 6 },
    })

    -- Non-owner (client 200): must NOT load git/scope/selector
    local non_owner_result = filter_entries_for_client(entries, non_owner_entity, 200)
    assert_eq("T8: non-owner gets 1 entry (not selector)", #non_owner_result, 1)
    assert_eq("T8: non-owner gets player", non_owner_result[1].name, "player")

    -- Owner entity: server INCLUDES git/scope/selector in net_sync
    local owner_entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            player = { authority = "server" },
            ["git/scope/selector"] = { authority = "client", target = "owner" },
        },
    })

    -- Owner (client 100): gets both
    local owner_result = filter_entries_for_client(entries, owner_entity, 100)
    assert_eq("T8: owner gets 2 entries", #owner_result, 2)
end

---------------------------------------------------------------------------
-- Test 9: net_sync = false (local-only) entries still load
---------------------------------------------------------------------------
print("info", "[CLIENT FILTER TEST] === 9. net_sync=false local-only entries ===")
do
    local entity = mock_entity({
        net_owner = { client_id = 100 },
        net_sync = {
            player = { authority = "server" },
        },
    })

    local entries = {
        { name = "player", config = {} },
        { name = "local_vfx", config = {}, net_sync_override = false },
    }

    -- Both clients should get local_vfx (net_sync=false is local-only, always loads)
    local owner_result = filter_entries_for_client(entries, entity, 100)
    assert_eq("T9: owner gets 2 (player + local_vfx)", #owner_result, 2)

    local other_result = filter_entries_for_client(entries, entity, 200)
    assert_eq("T9: non-owner gets 2 (player + local_vfx)", #other_result, 2)
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print("info", "")
print("info", "=========================================")
print("info", "[CLIENT FILTER TEST] RESULTS: " .. passed .. " passed, " .. failed .. " failed")
print("info", "=========================================")
if failed > 0 then
    print("error", "[CLIENT FILTER TEST] SOME TESTS FAILED")
else
    print("info", "[CLIENT FILTER TEST] ALL TESTS PASSED")
end
