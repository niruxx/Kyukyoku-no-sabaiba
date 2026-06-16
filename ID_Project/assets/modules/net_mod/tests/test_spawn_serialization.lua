-- modules/net_mod/tests/test_spawn_serialization.lua
-- Tests that net_mod is correctly included in spawn messages after decoupling.
-- Verifies the full flow: spawn entity → NetModLoader patches net_sync →
-- serialize_spawn_components includes net_mod as infrastructure.
--
-- KEY INSIGHT: net_mod CANNOT be stored as a key inside net_sync because
-- the ECS strips component names used as keys in other components' data.
-- Instead, net_mod is explicitly included as an infrastructure component
-- (like net_sync and net_owner).
--
-- Run: cargo run -p hello -- --script modules/net_mod/tests/test_spawn_serialization.lua

require("modules/mod/init.lua")

-- Set up NetInfo with side = "server" BEFORE requiring instance.lua.
local net_info = define_resource("NetInfo", {})
net_info.side = "server"

require("modules/net_mod/instance.lua")

local helpers = require("modules/net_mod/helpers.lua")
local Net = require("modules/net/shared/net.lua")

local state = define_resource("SpawnSerTest", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

---------------------------------------------------------------------------
-- Assert helpers
---------------------------------------------------------------------------
local function assert_eq(label, got, expected)
    if got == expected then
        state.passed = state.passed + 1
        print("info", "[SPAWN_SER TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[SPAWN_SER TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end
local function assert_not_nil(label, val)
    if val ~= nil then
        state.passed = state.passed + 1
        print("info", "[SPAWN_SER TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[SPAWN_SER TEST] FAIL: " .. label .. " expected non-nil")
    end
end
local function assert_nil(label, val)
    if val == nil then
        state.passed = state.passed + 1
        print("info", "[SPAWN_SER TEST] PASS: " .. label)
    else
        state.failed = state.failed + 1
        print("error", "[SPAWN_SER TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end
local function assert_true(label, val) assert_eq(label, val, true) end

---------------------------------------------------------------------------
-- Replicate serialize_spawn_components from server (matches net/server/init.lua)
-- net_mod is included as an infrastructure component, NOT via sync_config.
---------------------------------------------------------------------------
local function serialize_spawn_components(world, entity, sync_config)
    entity = world:get_entity(entity:id())
    local components = {}
    for comp_name, _ in pairs(sync_config) do
        local data = entity:get(comp_name)
        if data then
            components[comp_name] = data
        end
    end
    components.net_sync = sync_config
    local net_owner = entity:get("net_owner")
    if net_owner then
        components.net_owner = net_owner
    end
    -- Infrastructure: always include net_mod
    local net_mod = entity:get("net_mod")
    if net_mod then
        components.net_mod = net_mod
    end
    return components
end

---------------------------------------------------------------------------
-- Replicate broadcast_spawn filtering from server
---------------------------------------------------------------------------
local function filter_spawn_for_client(components, sync_config, client_id, entity, owner_id)
    local filtered = {}
    for comp_name, comp_data in pairs(components) do
        local cfg = sync_config[comp_name]
        if cfg then
            local target = cfg.targets or cfg.target or "all"
            if Net.should_send_to(target, client_id, entity, owner_id) then
                filtered[comp_name] = comp_data
            end
        else
            -- Infrastructure components (net_sync, net_owner, net_mod) — always send
            filtered[comp_name] = comp_data
        end
    end

    -- Filter net_sync entries by target
    if filtered.net_sync then
        local filtered_sync = {}
        for comp_name, cfg in pairs(filtered.net_sync) do
            local target = cfg.targets or cfg.target or "all"
            if Net.should_send_to(target, client_id, entity, owner_id) then
                filtered_sync[comp_name] = cfg
            end
        end
        filtered.net_sync = filtered_sync
    end

    return filtered
end

---------------------------------------------------------------------------
-- Test system
---------------------------------------------------------------------------
register_system("Update", function(world)
    state.frames = state.frames + 1

    ---------------------------------------------------------------------------
    -- Phase 0: Spawn entity with net_mod containing owner-only camera
    ---------------------------------------------------------------------------
    if state.phase == 0 then
        print("info", "[SPAWN_SER TEST] === Phase 1: Spawn with owner-only camera mod ===")
        local e = spawn({
            net_mod = {
                { player = {} },
                { ["camera/third_person"] = {}, net_sync = { authority = "client", target = "owner" } },
                { movement = {} },
            },
            net_owner = { client_id = 100 },
        })
        state.eid = e:id()
        state.phase = 1
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 1: Verify net_mod, net_sync, and spawn serialization
    ---------------------------------------------------------------------------
    if state.phase == 1 then
        if state.frames < 5 then return end

        local e = world:get_entity(state.eid)
        assert_not_nil("P1: entity exists", e)
        if not e then state.phase = 99; return end

        -- 1. Verify net_sync was created by NetModLoader (mod entries only, NOT net_mod)
        local ns = e:get("net_sync")
        assert_not_nil("P1: has net_sync", ns)
        if ns then
            assert_not_nil("P1: net_sync has player", ns["player"])
            assert_not_nil("P1: net_sync has camera/third_person", ns["camera/third_person"])
            assert_not_nil("P1: net_sync has movement", ns["movement"])
            -- net_mod should NOT be in net_sync (ECS strips component names as keys)
            assert_nil("P1: net_sync does NOT have net_mod (ECS limitation)", ns["net_mod"])

            if ns["camera/third_person"] then
                assert_eq("P1: cam target is owner", ns["camera/third_person"].target, "owner")
            end
        end

        -- 2. Verify net_mod component still exists
        local nm = e:get("net_mod")
        assert_not_nil("P1: has net_mod component", nm)

        -- 3. Simulate serialize_spawn_components (now includes net_mod as infrastructure)
        print("info", "[SPAWN_SER TEST] === Phase 1b: Serialize spawn components ===")
        if ns then
            local components = serialize_spawn_components(world, e, ns)

            -- net_mod MUST be in serialized components (via infrastructure path)
            assert_not_nil("P1: serialized has net_mod", components.net_mod)
            assert_not_nil("P1: serialized has net_sync", components.net_sync)
            assert_not_nil("P1: serialized has net_owner", components.net_owner)

            -- 4. Filter for OWNER (client_id = 100)
            print("info", "[SPAWN_SER TEST] === Phase 1c: Filter for owner ===")
            local owner_filtered = filter_spawn_for_client(components, ns, 100, e, 100)

            -- Owner should get net_mod (infrastructure, always passes filter)
            assert_not_nil("P1: owner gets net_mod", owner_filtered.net_mod)
            assert_not_nil("P1: owner gets net_sync", owner_filtered.net_sync)

            -- Owner's net_sync should have camera/third_person
            if owner_filtered.net_sync then
                assert_not_nil("P1: owner net_sync has camera/third_person",
                    owner_filtered.net_sync["camera/third_person"])
                assert_not_nil("P1: owner net_sync has player",
                    owner_filtered.net_sync["player"])
            end

            -- 5. Filter for NON-OWNER (client_id = 200)
            print("info", "[SPAWN_SER TEST] === Phase 1d: Filter for non-owner ===")
            local other_filtered = filter_spawn_for_client(components, ns, 200, e, 100)

            -- Non-owner should still get net_mod (infrastructure, always sent)
            assert_not_nil("P1: non-owner gets net_mod", other_filtered.net_mod)
            assert_not_nil("P1: non-owner gets net_sync", other_filtered.net_sync)

            -- Non-owner's net_sync should NOT have camera/third_person
            if other_filtered.net_sync then
                assert_nil("P1: non-owner net_sync missing camera/third_person",
                    other_filtered.net_sync["camera/third_person"])
                assert_not_nil("P1: non-owner net_sync has player",
                    other_filtered.net_sync["player"])
            end

            -- 6. Verify non-owner's net_mod still has ALL entries
            -- (client-side filtering handles per-entry removal)
            if other_filtered.net_mod then
                local entries = helpers.parse_net_mod_entries(other_filtered.net_mod)
                local has_camera = false
                local has_player = false
                for _, entry in ipairs(entries) do
                    if entry.name == "camera/third_person" then has_camera = true end
                    if entry.name == "player" then has_player = true end
                end
                assert_true("P1: non-owner net_mod has camera entry", has_camera)
                assert_true("P1: non-owner net_mod has player entry", has_player)
                print("info", "[SPAWN_SER TEST] Note: Client-side filter_entries_for_client will strip camera for non-owner")
            end
        end

        if e then despawn(e) end
        state.phase = 2
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Test sidebar-style dict patch
    ---------------------------------------------------------------------------
    if state.phase == 2 then
        if state.frames == 1 then
            print("info", "[SPAWN_SER TEST] === Phase 2: Sidebar-style dict patch ===")
            local e = spawn({
                net_mod = {
                    { player = {} },
                },
                net_sync = {
                    player = { authority = "server" },
                },
                net_owner = { client_id = 100 },
            })
            state.eid = e:id()
            return
        end
        -- Wait for NetModLoader to process
        if state.frames < 5 then return end

        if state.frames == 5 then
            -- Now patch like sidebar does
            local e = world:get_entity(state.eid)
            if e then
                e:patch({
                    net_mod = { ["git/scope/selector"] = { container_id = 6 } },
                    net_sync = { ["git/scope/selector"] = { authority = "client", target = "owner" } },
                })
            end
            return
        end

        if state.frames < 10 then return end

        local e = world:get_entity(state.eid)
        assert_not_nil("P2: entity exists", e)
        if not e then state.phase = 99; return end

        local ns = e:get("net_sync")
        assert_not_nil("P2: has net_sync", ns)
        if ns then
            assert_not_nil("P2: net_sync has player", ns["player"])
            assert_not_nil("P2: net_sync has git/scope/selector", ns["git/scope/selector"])

            if ns["git/scope/selector"] then
                assert_eq("P2: selector target is owner", ns["git/scope/selector"].target, "owner")
            end
        end

        local nm = e:get("net_mod")
        assert_not_nil("P2: has net_mod", nm)
        if nm then
            -- Verify dict entry was merged into net_mod
            assert_not_nil("P2: net_mod has git/scope/selector", nm["git/scope/selector"])
        end

        if e then despawn(e) end
        state.phase = 3
        state.frames = 0
        return
    end

    ---------------------------------------------------------------------------
    -- Phase 3: Query result entity vs full entity for net_mod access
    -- This catches the bug where entity:get("net_mod") returns nil on
    -- query result entities because net_mod isn't in the query spec.
    ---------------------------------------------------------------------------
    if state.phase == 3 then
        if state.frames == 1 then
            print("info", "[SPAWN_SER TEST] === Phase 3: Query result vs full entity ===")
            local e = spawn({
                net_mod = {
                    { player = {} },
                },
                net_owner = { client_id = 100 },
            })
            state.eid = e:id()
            return
        end
        if state.frames < 5 then return end

        if state.frames == 5 then
            -- Sidebar-style patch
            local e = world:get_entity(state.eid)
            if e then
                e:patch({
                    net_mod = { ["git/scope/selector"] = { container_id = 6 } },
                    net_sync = { ["git/scope/selector"] = { authority = "client", target = "owner" } },
                })
            end
            return
        end
        if state.frames < 8 then return end

        -- Simulate what the net_sync changed handler does:
        -- It gets entities from detect_sync_changes (query with optional = { ChildOf, net_owner })
        -- Then tries to read net_mod from the query result entity.

        -- 1. Query result entity (limited to query spec)
        local query_entities = world:query({
            with = { "net_sync" },
            optional = { "ChildOf", "net_owner" },
        })
        local query_entity = nil
        for _, qe in ipairs(query_entities) do
            if qe:id() == state.eid then
                query_entity = qe
                break
            end
        end
        assert_not_nil("P3: found entity in query", query_entity)

        if query_entity then
            -- Query result entity might NOT be able to access net_mod
            local qr_net_mod = query_entity:get("net_mod")
            -- This may or may not work depending on ECS implementation.
            -- The important thing is the full entity path ALWAYS works:

            -- 2. Full entity (can access any component)
            local full_entity = world:get_entity(state.eid)
            assert_not_nil("P3: full entity exists", full_entity)
            if full_entity then
                local full_net_mod = full_entity:get("net_mod")
                assert_not_nil("P3: full entity has net_mod", full_net_mod)
                if full_net_mod then
                    assert_not_nil("P3: full entity net_mod has git/scope/selector",
                        full_net_mod["git/scope/selector"])
                end

                -- Verify the net_sync also has the new entry
                local full_ns = full_entity:get("net_sync")
                assert_not_nil("P3: full entity has net_sync", full_ns)
                if full_ns then
                    assert_not_nil("P3: full entity net_sync has git/scope/selector",
                        full_ns["git/scope/selector"])
                end
            end

            -- Log whether query result entity can access net_mod (informational)
            if qr_net_mod then
                print("info", "[SPAWN_SER TEST] INFO: query result entity CAN access net_mod")
            else
                print("info", "[SPAWN_SER TEST] INFO: query result entity CANNOT access net_mod (expected — use world:get_entity)")
            end
        end

        local e = world:get_entity(state.eid)
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
        print("info", "[SPAWN_SER TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("info", "=========================================")
        if state.failed > 0 then
            print("error", "[SPAWN_SER TEST] SOME TESTS FAILED")
        else
            print("info", "[SPAWN_SER TEST] ALL TESTS PASSED")
        end
        state.phase = 99
    end
end)
