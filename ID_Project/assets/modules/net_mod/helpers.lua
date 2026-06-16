-- modules/net_mod/helpers.lua
-- Shared helpers for net_mod.  Used by both init.lua and instance.lua.

local M = {}

local reserved_mod_keys = { script = true, instanced = true }

--- Parse net_mod into normalized entries: { name, config, net_sync_override }.
--- Handles pure arrays, pure dicts, mixed tables, and JSON-deserialized arrays
--- where numeric keys become strings ("1", "2", etc.).
function M.parse_net_mod_entries(net_mod_value)
    local entries = {}
    if not net_mod_value then return entries end
    local seen = {}

    for k, entry in pairs(net_mod_value) do
        if type(entry) ~= "table" then goto continue end

        -- Array entry: key is numeric or string-numeric (e.g. 1 or "1" from JSON)
        local is_array_entry = (type(k) == "number") or (type(k) == "string" and tonumber(k) ~= nil)

        if is_array_entry then
            local net_sync_override = entry.net_sync
            for name, config in pairs(entry) do
                if name ~= "net_sync" and type(config) == "table" and not seen[name] then
                    entries[#entries + 1] = {
                        name = name,
                        config = config,
                        net_sync_override = net_sync_override,
                    }
                    seen[name] = true
                end
            end
        elseif type(k) == "string" and not seen[k] then
            -- String key entry (from patches like entity:patch({ net_mod = { [mod] = cfg } }))
            entries[#entries + 1] = {
                name = k,
                config = entry,
                net_sync_override = nil,
            }
            seen[k] = true
        end

        ::continue::
    end

    return entries
end

--- Build `mod` and `net_sync` patches from net_mod entries.
--- Also records sync exclusions for the entity.
---
--- @param existing_net_sync  (optional) current net_sync from the entity.
---   When provided, the returned net_sync is a **complete** table: existing
---   non-mod entries are preserved, old mod-owned keys are stripped, and new
---   mod entries are added.  This makes it safe for `entity:set`.
---   When nil (added path), only the mod-derived entries are returned
---   (suitable for `entity:patch`).
function M.build_patches(entries, eid, nm_state, existing_net_sync)
    local mod_entries = {}
    local new_mod_keys = {}   -- track which keys this build owns
    local net_sync

    if existing_net_sync then
        -- Start from existing net_sync, strip old mod-owned keys
        net_sync = {}
        local old_mod_keys = nm_state.mod_sync_keys and nm_state.mod_sync_keys[eid] or {}
        for k, v in pairs(existing_net_sync) do
            if not old_mod_keys[k] then
                net_sync[k] = v   -- preserve non-mod entry
            end
        end
    else
        net_sync = {}
    end

    -- Track per-entry sync overrides so NetModBaseSync can inherit them for bases
    nm_state.entry_sync_overrides = nm_state.entry_sync_overrides or {}
    nm_state.entry_sync_overrides[eid] = nm_state.entry_sync_overrides[eid] or {}

    for _, entry in ipairs(entries) do
        -- Build mod entry
        mod_entries[entry.name] = entry.config

        -- Build net_sync entry (unless explicitly disabled)
        if entry.net_sync_override == false then
            -- Skip — this mod is not synced
            nm_state.excluded_sync[eid] = nm_state.excluded_sync[eid] or {}
            nm_state.excluded_sync[eid][entry.name] = true
        elseif entry.net_sync_override and type(entry.net_sync_override) == "table" then
            -- Custom sync config for this mod's component
            net_sync[entry.name] = entry.net_sync_override
            new_mod_keys[entry.name] = true
            -- Store override so bases discovered later can inherit it
            nm_state.entry_sync_overrides[eid][entry.name] = entry.net_sync_override
        elseif existing_net_sync and existing_net_sync[entry.name] then
            -- Preserve existing net_sync (e.g. set by sidebar server alongside net_mod patch)
            net_sync[entry.name] = existing_net_sync[entry.name]
            new_mod_keys[entry.name] = true
            nm_state.entry_sync_overrides[eid][entry.name] = existing_net_sync[entry.name]
        else
            -- Default: server authority, send to all
            net_sync[entry.name] = { authority = "server" }
            new_mod_keys[entry.name] = true
        end
    end

    -- Update tracking for next rebuild
    nm_state.mod_sync_keys = nm_state.mod_sync_keys or {}
    nm_state.mod_sync_keys[eid] = new_mod_keys

    return mod_entries, net_sync
end

--- Extract mod entry names from a `mod` component value.
--- Handles both array and dictionary forms.
function M.extract_mod_entry_names(mod_val)
    local names = {}
    local seen = {}
    -- Array entries
    for _, entry in ipairs(mod_val) do
        for name, config in pairs(entry) do
            if type(config) == "table" and not reserved_mod_keys[name] and not seen[name] then
                names[#names + 1] = name
                seen[name] = true
            end
        end
    end
    -- Dictionary entries
    for name, config in pairs(mod_val) do
        if type(name) == "string" and type(config) == "table"
           and not reserved_mod_keys[name] and not seen[name] then
            names[#names + 1] = name
            seen[name] = true
        end
    end
    return names
end

--- Find the net_sync override from a child entry for a discovered base name.
--- Uses the base_origins mapping (populated by the on_loaded hook in instance.lua)
--- to look up which child entry triggered this base, then returns that child's
--- net_sync override from entry_sync_overrides.
--- @param nm_state table  The NetModState resource
--- @param eid number      Entity ID
--- @param base_name string  The base mod name (e.g. "camera")
--- @return table|nil  The net_sync override from the child, or nil
function M.find_base_sync_override(nm_state, eid, base_name)
    -- Look up which child entry triggered this base
    local origins = nm_state.base_origins and nm_state.base_origins[eid]
    if not origins then return nil end

    local child_name = origins[base_name]
    if not child_name then return nil end

    -- Look up the child's net_sync override
    local overrides = nm_state.entry_sync_overrides and nm_state.entry_sync_overrides[eid]
    if not overrides then return nil end

    return overrides[child_name]
end

return M
