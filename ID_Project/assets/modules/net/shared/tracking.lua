-- modules/net/shared/tracking.lua
-- Shared net_sync tracking logic used by BOTH server and client.
-- Handles: sync change detection, reparenting detection, efficient changed-component queries,
--          and pending parent queues.

local Net = require("modules/net/shared/net.lua")

local Tracking = {}

---------------------------------------------------------------------------
-- Shared tracking state resource
-- Owned by tracking.lua, read/written by net/server, net/client, net/transfer.
---------------------------------------------------------------------------

local tracking_state = define_resource("NetTrackingState", {
    tracked = {},          -- net_id → { sync_config, prev_owner }
    all_synced = {},       -- cached flat list of synced component names
    synced_dirty = true,   -- rebuild flag
})

--- Get the shared tracking state resource.
--- Any mod that requires tracking.lua can call this.
function Tracking.state()
    return tracking_state
end

---------------------------------------------------------------------------
-- Synced component name cache
-- Rebuild only when net_sync is added/changed/removed (NOT every frame).
---------------------------------------------------------------------------

--- Rebuild the flat list of all synced component names across all tracked entities.
--- @param tracked table  net_id → { sync_config = { comp_name = cfg, ... } }
--- @return table  Array of unique component name strings
function Tracking.rebuild_synced_names(tracked)
    local names, seen = {}, {}
    for _, info in pairs(tracked) do
        for comp, _ in pairs(info.sync_config) do
            if not seen[comp] then
                seen[comp] = true
                names[#names + 1] = comp
            end
        end
    end
    return names
end

---------------------------------------------------------------------------
-- net_sync change detection
---------------------------------------------------------------------------

--- Detect entities with net_sync added, changed, or removed this frame.
--- Entities with `net_predict` are skipped — they are handled by NetPredictFinalize
--- on the server (which performs the allocation + broadcast itself once a mod approves).
--- @param world userdata       The world object
--- @return table  { added = {entity...}, changed = {entity...}, removed = {entity...} }
function Tracking.detect_sync_changes(world)
    local result = { added = {}, changed = {}, removed = {} }
    local entities = world:query({
        ["or"] = {
            added = { "net_sync" },
            changed = { "net_sync" },
            removed = { "net_sync" },
        },
        without = { "net_predict" },
        optional = { "ChildOf", "net_owner" },
    })
    for _, entity in ipairs(entities) do
        if entity:is_removed("net_sync") then
            result.removed[#result.removed + 1] = entity
        elseif entity:is_added("net_sync") then
            result.added[#result.added + 1] = entity
        elseif entity:is_changed("net_sync") then
            result.changed[#result.changed + 1] = entity
        end
    end
    return result
end

---------------------------------------------------------------------------
-- Reparenting detection (ChildOf changed on net_sync entities)
-- Used to detect entities moving between net server scopes.
---------------------------------------------------------------------------

--- Detect entities that were reparented while having net_sync.
--- Returns entities that entered/left the scope of net_entity_id.
--- @param world userdata
--- @param id_map table          Our id_map (entity_to_net used to check ownership)
--- @return table, table  entered, left (arrays of entity snapshots)
function Tracking.detect_reparented(world, id_map)
    local entered, left = {}, {}
    local reparented = world:query({
        with = { "net_sync" },
        ["or"] = { changed = { "ChildOf" } },
        optional = { "net_owner" },
    })
    for _, entity in ipairs(reparented) do
        local eid = entity:id()
        local was_ours = id_map.entity_to_net[eid] ~= nil

        -- Check if entity is currently a descendant of our net entity
        local is_ours = false
        local check = world:query({
            with = { "net_sync" },
        })
        for _, e in ipairs(check) do
            if e:id() == eid then is_ours = true; break end
        end

        if was_ours and not is_ours then
            left[#left + 1] = entity
        elseif not was_ours and is_ours then
            entered[#entered + 1] = entity
        end
    end
    return entered, left
end

---------------------------------------------------------------------------
-- Efficient changed-component queries
-- Uses ["or"] = { changed = all_synced } to skip entities with zero changes.
---------------------------------------------------------------------------

--- Deep-merge two query configs. Arrays (e.g. `with`, `optional`) are
--- concatenated; dict tables (e.g. `or`) recurse; scalars in `extra` win.
--- Array vs dict is detected by whether `t[1]` is set.
local function deep_merge_query(base, extra)
    if not extra then return base end
    if not base then return extra end
    local result = {}
    for k, v in pairs(base) do result[k] = v end
    for k, v in pairs(extra) do
        local bv = result[k]
        if type(bv) == "table" and type(v) == "table" then
            if bv[1] or v[1] then
                local merged = {}
                for _, x in ipairs(bv) do merged[#merged + 1] = x end
                for _, x in ipairs(v)  do merged[#merged + 1] = x end
                result[k] = merged
            else
                result[k] = deep_merge_query(bv, v)
            end
        else
            result[k] = v
        end
    end
    return result
end

--- Query entities with at least one changed synced component.
--- all_synced is the cached list from rebuild_synced_names().
--- @param world userdata
--- @param all_synced table       Array of component name strings
--- @param extra table|nil        Optional extra query config, deep-merged with
---                               the internal `{ with = {"net_sync"}, or = {...} }`.
---                               Use this to pull in extra components via
---                               `optional = {...}` so `entity:get(...)` works.
--- @return table  Array of entity snapshots
function Tracking.query_changed(world, all_synced, extra)
    if #all_synced == 0 then return {} end
    return world:query(deep_merge_query({
        with = { "net_sync" },
        ["or"] = { changed = all_synced },
    }, extra))
end

--- Convenience: rebuild all_synced if dirty, return entities with changes.
--- Wraps the query_changed + rebuild_synced_names pattern that
--- net/server, net/client, and net/transfer all need.
--- @param world userdata
--- @param extra table|nil  Optional extra query config (see query_changed).
--- @return table  Array of entity snapshots
function Tracking.get_changed_entities(world, extra)
    if tracking_state.synced_dirty then
        tracking_state.all_synced = Tracking.rebuild_synced_names(tracking_state.tracked)
        tracking_state.synced_dirty = false
    end
    return Tracking.query_changed(world, tracking_state.all_synced, extra)
end

--- For a single entity, collect only the components that actually changed.
--- @param entity userdata        Entity snapshot from query
--- @param sync_config table      { comp_name = { authority, target, ... }, ... }
--- @return table  { comp_name = data } for changed components only (empty if none)
function Tracking.collect_changed_components(entity, sync_config)
    local changed = {}
    for comp, _ in pairs(sync_config) do
        if entity:is_changed(comp) then
            changed[comp] = entity:get(comp)
        end
    end
    return changed
end

---------------------------------------------------------------------------
-- Hierarchy helpers
---------------------------------------------------------------------------

--- Translate an entity's ChildOf to a net_id using the id_map.
--- @param entity userdata   Entity snapshot (must have ChildOf in optional)
--- @param id_map table      { entity_to_net = { ... } }
--- @return number|nil       The parent's net_id, or nil if no parent or parent not tracked
function Tracking.translate_child_of(entity, id_map)
    local child_of = entity:get("ChildOf")
    if child_of then return id_map.entity_to_net[child_of] end
    return nil
end

---------------------------------------------------------------------------
-- Pending parent queue
-- Used by BOTH server and client to handle out-of-order spawns.
--
-- Server: queues spawn broadcasts until parent entity has a net_id.
--   (e.g., parent and child spawned same frame, child processed first)
--
-- Client: queues :with_parent() calls until parent entity exists locally.
--   (e.g., child spawn message arrives before parent spawn message)
---------------------------------------------------------------------------

--- Create a new pending queue (empty table).
--- @return table  parent_key → [{ payload }]
function Tracking.create_pending_queue()
    return {}
end

--- Queue an item waiting for a parent key.
--- @param pending table      The pending queue
--- @param parent_key any     The key to wait for (entity_id on server, net_id on client)
--- @param payload table      The data to store (e.g., { net_id, entity })
function Tracking.queue_pending(pending, parent_key, payload)
    pending[parent_key] = pending[parent_key] or {}
    pending[parent_key][#pending[parent_key] + 1] = payload
end

--- Flush all items waiting for a parent key. Returns the list (or nil).
--- @param pending table      The pending queue
--- @param parent_key any     The key to flush
--- @return table|nil         Array of payloads, or nil if nothing was waiting
function Tracking.flush_pending(pending, parent_key)
    local items = pending[parent_key]
    pending[parent_key] = nil
    return items
end

---------------------------------------------------------------------------
-- Ownership change detection
---------------------------------------------------------------------------

--- Query entities where net_owner changed or was removed this frame.
--- @param world userdata
--- @return table  Array of entity snapshots
function Tracking.detect_ownership_changes(world)
    local changed = world:query({
        ["or"] = { changed = { "net_owner" } },
        with = { "net_owner" },
        optional = { "net_owner", "net_sync" },
    })
    -- Also catch entities where net_owner was removed entirely
    local removed = world:query({
        removed = { "net_owner" },
        with = { "net_sync" },
        optional = { "net_sync" },
    })
    for _, e in ipairs(removed) do
        changed[#changed + 1] = e
    end
    return changed
end

---------------------------------------------------------------------------
-- Predicted-spawn component collection
---------------------------------------------------------------------------

--- Collect the components to ship in a SPAWN_REQUEST for a predicted entity.
--- Includes:
---   (a) Every component listed in the entity's `net_sync`.
---   (b) Marker components whose names appear as `net_mod` entries
---       (dict OR array form). This makes mods like `placement` reach the
---       server even when NetModLoader's net_sync patch hasn't been applied
---       yet in the same frame.
---   (c) Identity components: `net_sync`, `net_mod`, `net_owner`,
---       `net_predict`.
--- @param entity userdata  Entity snapshot (responds to :get(name))
--- @return table  components dict ready to JSON-encode into SPAWN_REQUEST.
function Tracking.collect_predict_components(entity)
    local sync_config = entity:get("net_sync") or {}
    local components = {}

    -- (a) Components listed in net_sync
    for comp_name, _ in pairs(sync_config) do
        local data = entity:get(comp_name)
        if data then components[comp_name] = data end
    end

    -- (b) Components named by net_mod entries (dict or array form)
    local net_mod = entity:get("net_mod")
    if net_mod then
        components.net_mod = net_mod
        local function include_by_name(name)
            if type(name) == "string" and not components[name] then
                local data = entity:get(name)
                if data then components[name] = data end
            end
        end
        for k, v in pairs(net_mod) do
            if type(k) == "string" then
                include_by_name(k)
            elseif type(k) == "number" and type(v) == "table" then
                for name, _ in pairs(v) do
                    if name ~= "net_sync" then include_by_name(name) end
                end
            end
        end
    end

    -- (c) Identity components
    local net_owner = entity:get("net_owner")
    if net_owner then components.net_owner = net_owner end
    components.net_predict = entity:get("net_predict")
    components.net_sync = sync_config

    return components
end

---------------------------------------------------------------------------
-- Serialize synced components for transfer snapshots
---------------------------------------------------------------------------

--- Serialize all components from an entity that are listed in sync_config.
--- Callers add infrastructure (net_sync, net_mod, etc.) separately as needed.
--- @param world userdata      The world object (for full entity access)
--- @param entity userdata     Entity snapshot
--- @param sync_config table   The net_sync config dict
--- @return table  { comp_name = comp_data, ... }
function Tracking.serialize_synced(world, entity, sync_config)
    entity = world:get_entity(entity:id()) -- get full entity
    local components = {}
    for comp_name, cfg in pairs(sync_config) do
        if type(cfg) == "table" then
            local data = entity:get(comp_name)
            if data then components[comp_name] = data end
        end
    end
    return components
end

return Tracking
