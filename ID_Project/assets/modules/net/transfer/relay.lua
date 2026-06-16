-- modules/net/transfer/relay.lua
-- Top-level relay: detects net_transfer entities across all game scopes,
-- spawns mirrors for non-owned entities, syncs data for owned entities.
-- Required once in server/main.lua (scope 0).

local Tracking = require("modules/net/shared/tracking.lua")

local json = require "modules/dkjson.lua"

local state = define_resource("NetTransferRelay", {
    listeners = {},           -- scope_id → spawn_fn(entity_data) → mirror_eid
    source_to_mirrors = {},   -- source_eid → { [scope_id] = mirror_eid }
    owned_index = {},         -- transfer_id → { [scope_id] = eid }
    primary = {},             -- transfer_id → scope_id (authoritative source)
})

local M = {}

function M.register_scope(scope_id)
    state.listeners[scope_id] = function(entity_data)
        return spawn(entity_data):id()
    end
end

---------------------------------------------------------------------------
-- Non-owned entities (portal etc.): spawn/patch/despawn mirrors
---------------------------------------------------------------------------

register_system("PostUpdate", function(world)
    -- added: snapshot source, spawn mirrors in other scopes
    for _, entity in ipairs(world:query({
        added = { "net_transfer" },
        without = { "net_owner", "_net_transfer_mirror" },
        with = { "net_sync" },
    })) do
        local sw = entity:get("ScopeWorld")
        local source_scope = sw and sw.Scope
        local sync = entity:get("net_sync")
        local snap = Tracking.serialize_synced(world, entity, sync)

        local spawn_data = {}
        for k, v in pairs(snap) do spawn_data[k] = v end
        spawn_data.net_mod = entity:get("net_mod")
        spawn_data.net_transfer = entity:get("net_transfer")
        spawn_data._net_transfer_mirror = { source = entity:id() }

        state.source_to_mirrors[entity:id()] = {}
        for scope_id, spawn_fn in pairs(state.listeners) do
            if scope_id ~= source_scope then
                state.source_to_mirrors[entity:id()][scope_id] = spawn_fn(spawn_data)
            end
        end
    end

    -- changed: patch mirrors directly
    for _, entity in ipairs(world:query({
        changed = { "net_transfer" },
        without = { "net_owner", "_net_transfer_mirror" },
    })) do
        local mirrors = state.source_to_mirrors[entity:id()]
        if not mirrors then goto skip_changed end

        local transfer = entity:get("net_transfer")
        if not transfer or not transfer.data then goto skip_changed end

        for _, mirror_id in pairs(mirrors) do
            local mirror = world:get_entity(mirror_id)
            if mirror then
                mirror:patch({ net_transfer = { data = transfer.data } })
            end
        end
        ::skip_changed::
    end

    -- removed: despawn mirrors
    for _, entity in ipairs(world:query({
        removed = { "net_transfer" },
        without = { "net_owner" },
    })) do
        local mirrors = state.source_to_mirrors[entity:id()]
        if mirrors then
            for _, mid in pairs(mirrors) do despawn(mid) end
            state.source_to_mirrors[entity:id()] = nil
        end
    end
end, { label = "NetTransferRelayNonOwned" })

---------------------------------------------------------------------------
-- Owned entities (player etc.): index + relay from primary
-- Keyed by transfer.id (stable cross-scope identity), NOT client_id
-- (which is scope-local since each net server assigns independently).
---------------------------------------------------------------------------

register_system("PostUpdate", function(world)
    -- added: register in owned_index, claim primary, initial sync
    for _, entity in ipairs(world:query({
        added = { "net_transfer" },
        with = { "net_owner", "ScopeWorld" },
        without = { "_net_transfer_mirror" },
    })) do
        local transfer = entity:get("net_transfer")
        local sw = entity:get("ScopeWorld")
        local tid = transfer.id
        local sid = sw and sw.Scope

        if not tid then goto continue end

        state.owned_index[tid] = state.owned_index[tid] or {}
        state.owned_index[tid][sid] = entity:id()

        if not state.primary[tid] then
            state.primary[tid] = sid
        end

        print(string.format("[NET TRANSFER RELAY] Registered owned entity %d, transfer_id=%s, scope %d (primary=%d)",
            entity:id(), tostring(tid), sid, state.primary[tid]))

        -- If joining a non-primary scope, pull current data from primary
        if state.primary[tid] ~= sid then
            local primary_eid = state.owned_index[tid][state.primary[tid]]
            if primary_eid then
                local pe = world:get_entity(primary_eid)
                if pe then
                    local pt = pe:get("net_transfer")
                    if pt and pt.data then
                        entity:patch({ net_transfer = { data = pt.data } })
                    end
                end
            end
        end

        ::continue::
    end

    -- changed: relay from primary scope to all other scopes
    for _, entity in ipairs(world:query({
        changed = { "net_transfer" },
        with = { "net_owner", "ScopeWorld" },
        without = { "_net_transfer_mirror" },
    })) do
        local transfer = entity:get("net_transfer")
        local sw = entity:get("ScopeWorld")
        local tid = transfer.id
        local sid = sw and sw.Scope

        -- Only relay from the primary scope (prevents feedback loops)
        if not tid or state.primary[tid] ~= sid then goto skip_owned end
        if not transfer.data then goto skip_owned end

        local scopes = state.owned_index[tid]
        if not scopes then goto skip_owned end

        for scope_id, eid in pairs(scopes) do
            if scope_id ~= sid then
                local target = world:get_entity(eid)
                if target then
                    target:patch({ net_transfer = { data = transfer.data } })
                end
            end
        end
        ::skip_owned::
    end

    -- removed: clean up owned_index
    for _, entity in ipairs(world:query({
        removed = { "net_transfer" },
        with = { "net_owner" },
    })) do
        local transfer = entity:get("net_transfer")
        if not transfer then goto skip_remove end
        local tid = transfer.id

        if tid and state.owned_index[tid] then
            for sid, eid in pairs(state.owned_index[tid]) do
                if eid == entity:id() then
                    state.owned_index[tid][sid] = nil
                    break
                end
            end
            -- If primary scope entity was removed, clear primary
            if state.primary[tid] then
                local primary_eid = state.owned_index[tid][state.primary[tid]]
                if not primary_eid then
                    -- Elect a new primary from remaining scopes, or nil
                    state.primary[tid] = nil
                    for remaining_sid, _ in pairs(state.owned_index[tid]) do
                        state.primary[tid] = remaining_sid
                        break
                    end
                end
            end
        end
        ::skip_remove::
    end
end, { label = "NetTransferRelayOwned", after = { "NetTransferRelayNonOwned" } })

return M
