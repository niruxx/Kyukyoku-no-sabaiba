-- modules/net_mod/instance.lua
-- Per-instance NetModLoader: runs at the net entity's state_id (M).
-- Required from the on_loaded("net") hook in init.lua, which fires inside
-- the instanced require_async callback.  Because __LUA_STATE_ID__ = M,
-- define_resource("NetInfo", {}) returns the instance's NetInfo with side
-- already set by net/server or net/client.
--
-- Systems registered here run at state_id=M and can access NetInfo directly.
-- This eliminates the need for bridge resources (NetSides), path resolvers,
-- or hierarchy walking.

local mod_api = require("modules/mod/init.lua")          -- cache fallback → API
local helpers = require("modules/net_mod/helpers.lua")    -- shared parse/build helpers
local Net = require("modules/net/shared/net.lua")         -- target filter helpers

local net_info = define_resource("NetInfo", {})
local nm_state = define_resource("NetModState", {
    excluded_sync = {},
    pending_entities = {},  -- entity IDs queued while side is still nil
})

-- NOTE: net_info.side is set lazily by net/server or net/client (loaded async by ModLoader).
-- Do NOT capture it at require-time. Read net_info.side inside system functions.

-- Register path resolver so that ModLoader's base chain resolution also uses
-- side-specific paths.  The resolver captures `side` as an upvalue, so even
-- though it's called from ModLoader at state_id=0, it reads the correct side.
mod_api.register_path_resolver("net_mod", function(mod_name, entity_id)
    if not net_info.side then return nil end
    return "modules/" .. mod_name .. "/" .. net_info.side .. "/init.lua"
end)

-- Record base → child mapping when ModLoader discovers a base chain.
-- entry_name is the child (e.g. "camera/third_person"), result.base is the
-- base (e.g. "camera").  NetModBaseSync uses this to inherit the child's
-- net_sync override for the base.
mod_api.register_on_loaded("net_mod", function(eid, result, entry_name)
    if type(result) == "table" and result.base and entry_name then
        nm_state.base_origins = nm_state.base_origins or {}
        nm_state.base_origins[eid] = nm_state.base_origins[eid] or {}
        nm_state.base_origins[eid][result.base] = entry_name
    end
end)

---------------------------------------------------------------------------
-- Client-side entry filtering
-- On the client, skip entries whose net_sync target excludes this client.
-- This replaces the old server-side filter_net_mod_for_client approach,
-- keeping net/server decoupled from net_mod internals.
---------------------------------------------------------------------------
local function filter_entries_for_client(entries, entity)
    if net_info.side ~= "client" or not net_info.client_id then
        return entries
    end

    local my_id = net_info.client_id
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
-- System: NetModLoader (First, before ModLoader)
-- Translates net_mod → mod + net_sync.  Includes explicit script paths
-- using the side from NetInfo (e.g., modules/{name}/server/init.lua).
---------------------------------------------------------------------------

register_system("First", function(world)
    -- Always consume added queries (even if side isn't ready) to avoid missing them
    local added = world:query({
        added = { "net_mod" },
        optional = { "net_mod", "net_sync", "net_owner" },
    })

    -- If side isn't set yet, queue entity IDs for later
    if not net_info.side then
        for _, entity in ipairs(added) do
            nm_state.pending_entities[#nm_state.pending_entities + 1] = entity:id()
        end
        return
    end

    -- Helper: process a single entity (used for both fresh and deferred entities)
    local function process_added(entity)
        local eid = entity:id()
        local net_mod_value = entity:get("net_mod")
        if not net_mod_value then return end
        local entries = helpers.parse_net_mod_entries(net_mod_value)
        entries = filter_entries_for_client(entries, entity)
        local mod_entries, net_sync = helpers.build_patches(entries, eid, nm_state)

        -- Patch mod as a dictionary: { [name] = config, ... }
        -- Path resolution is handled by the registered path resolver (line 29),
        -- so no explicit script paths needed in the mod entries.
        if next(mod_entries) then
            entity:patch({ mod = mod_entries })
        end

        -- Patch net_sync (only if there are synced components)
        if next(net_sync) then
            entity:patch({ net_sync = net_sync })
        end

        -- Initialize net_sync_net_mod shadow component so the net client
        -- intercepts server updates via entity:set (full replace) instead
        -- of entity:patch (deep merge). This ensures removed entries
        -- don't survive on the client.
        entity:set({ net_sync_net_mod = net_mod_value })

        -- Track net_mod entries for diffing on change
        nm_state.prev_net_entries = nm_state.prev_net_entries or {}
        nm_state.prev_net_entries[eid] = mod_entries
    end

    -- Process deferred entities from before side was ready
    if #nm_state.pending_entities > 0 then
        local pending = nm_state.pending_entities
        nm_state.pending_entities = {}
        for _, eid in ipairs(pending) do
            local entity = world:get_entity(eid)
            if entity then
                process_added(entity)
            end
        end
    end

    -- Process newly added entities
    for _, entity in ipairs(added) do
        process_added(entity)
    end

    -- Process changed net_mod components
    local changed = world:query({
        changed = { "net_mod" },
        optional = { "net_mod", "net_sync", "net_owner" },
    })
    for _, entity in ipairs(changed) do
        local eid = entity:id()
        local net_mod_value = entity:get("net_mod")
        local entries = helpers.parse_net_mod_entries(net_mod_value)
        entries = filter_entries_for_client(entries, entity)

        -- Clear old exclusions for this entity
        nm_state.excluded_sync[eid] = nil

        -- Pass existing net_sync so build_patches produces a complete table
        -- (preserves non-mod entries like Transform, rebuilds mod entries)
        local existing_net_sync = entity:get("net_sync")
        local mod_entries, net_sync = helpers.build_patches(entries, eid, nm_state, existing_net_sync)

        -- Build a single mod patch: additions as name=config, removals as name=null.
        -- ModLoader detects changes via entity_mods (what's loaded) vs mod dict keys.
        nm_state.prev_net_entries = nm_state.prev_net_entries or {}
        local old_entries = nm_state.prev_net_entries[eid] or {}
        local mod_patch = {}
        local has_changes = false
        for name, config in pairs(mod_entries) do
            if not old_entries[name] then
                mod_patch[name] = config
                has_changes = true
            end
        end
        for name, _ in pairs(old_entries) do
            if not mod_entries[name] then
                mod_patch[name] = null
                has_changes = true
            end
        end
        if has_changes then
            entity:patch({ mod = mod_patch })
        end

        nm_state.prev_net_entries[eid] = mod_entries

        if next(net_sync) then
            entity:set({ net_sync = net_sync })
        end
    end
    -- Apply net_mod updates received via the net_sync_net_mod shadow.
    -- The net client writes to the shadow via entity:set (full replace),
    -- bypassing the deep merge that would preserve removed entries.
    -- We apply the shadow to the real net_mod via entity:set as well.
    -- Skip `added` — that's our own initialization in process_added above.
    local shadow_changed = world:query({
        ["or"] = {
            added = { "net_sync_net_mod" },
            changed = { "net_sync_net_mod" },
        },
    })
    for _, entity in ipairs(shadow_changed) do
        if not entity:is_added("net_sync_net_mod") then
            local shadow = entity:get("net_sync_net_mod")
            if shadow then
                entity:set({ net_mod = shadow })
            end
        end
    end
end, { label = "NetModLoader", before = { "ModLoader" } })

---------------------------------------------------------------------------
-- System: NetModBaseSync (First, after ModLoader)
-- Reacts to mod component changes on net_mod entities.
-- When ModLoader discovers a base and adds it to the mod component,
-- this system detects it and adds default net_sync for the base.
---------------------------------------------------------------------------

register_system("First", function(world)
    local changed = world:query({
        changed = { "mod" },
        with = { "net_mod" },
        optional = { "net_sync" },
    })
    for _, entity in ipairs(changed) do
        local eid = entity:id()
        local mod_val = entity:get("mod")
        if not mod_val then goto continue end

        local net_sync = entity:get("net_sync") or {}
        local excluded = nm_state.excluded_sync[eid] or {}

        -- Find mod entries that don't have net_sync yet and aren't excluded
        local entry_names = helpers.extract_mod_entry_names(mod_val)
        local sync_patch = {}
        local needs_patch = false
        for _, name in ipairs(entry_names) do
            if not net_sync[name] and not excluded[name] then
                -- Check if a child entry has a net_sync override for this base
                local parent_override = helpers.find_base_sync_override(nm_state, eid, name)
                if parent_override then
                    sync_patch[name] = parent_override
                else
                    sync_patch[name] = { authority = "server" }
                end
                needs_patch = true
            end
        end
        if needs_patch then
            entity:patch({ net_sync = sync_patch })
        end

        ::continue::
    end
end, { label = "NetModBaseSync", after = { "ModLoader" } })
