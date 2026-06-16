-- modules/mod/init.lua
-- Ref-counted mod loader with base chain support.
-- Watches for `mod` component on entities, loads/unloads scripts, manages ref counts.
--
-- `mod` component shape:
--   { my_mod = { config } }                  -- single mod, default path
--   { my_mod = { config }, script = "path" } -- explicit script path
--   { { controller = {} }, { animation = {} } } -- multiple mods (array)
--   { net = {}, instanced = true, script = "modules/net/server/init.lua" }
--
-- The mod loader:
-- 1. Parses the `mod` component entries
-- 2. Resolves script paths (modules/{name}/init.lua unless overridden by path resolver)
-- 3. Loads scripts via require_async with callback for base chain discovery
-- 4. Ref-counts scripts — stops them only when count reaches 0
-- 5. Patches mod-name components onto the entity
-- 6. When a script returns { base = "name" }, loads the base script too
--
-- Path resolver hooks:
--   Other modules can register a path resolver via the returned API:
--     local mod_api = require("modules/mod/init.lua")
--     mod_api.register_path_resolver("net_mod", function(mod_name)
--         return "modules/" .. mod_name .. "/" .. side .. "/init.lua"
--     end)
--   When resolving a script path, if the entity has a component matching a
--   registered resolver, that resolver is used instead of the default.

local state = define_resource("ModLoaderState", {
    ref_counts = {},      -- script_path → { count = N }
    entity_mods = {},     -- entity_id → { [mod_name] = { path } }
    path_resolvers = {},  -- component_name → resolver_fn(mod_name, entity_id) → script_path
    on_loaded_hooks = {}, -- component_name → hook_fn(entity_id, result)
})

---------------------------------------------------------------------------
-- Path resolver hooks
---------------------------------------------------------------------------

local function register_path_resolver(component_name, resolver_fn)
    state.path_resolvers[component_name] = resolver_fn
end

---------------------------------------------------------------------------
-- On-loaded hooks
-- Other modules can register a callback that fires when an instanced (or
-- non-instanced) script finishes loading.  The callback runs inside the
-- require_async callback, so __LUA_STATE_ID__ is set to the loaded
-- script's instanced state_id.  This lets the hook read instanced
-- resources and bridge data back to a global resource via upvalues.
---------------------------------------------------------------------------

local function register_on_loaded(component_name, hook_fn)
    state.on_loaded_hooks[component_name] = hook_fn
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Parse the mod component into a normalized list of { name, config, script, instanced }.
--- Handles both single-mod shorthand and array-of-mods forms.
local function parse_mod_entries(mod_value)
    local entries = {}
    if not mod_value then return entries end

    local entry_map = {}
    local ordered_names = {}

    -- 1. Process array elements
    for _, entry in ipairs(mod_value) do
        for name, config in pairs(entry) do
            if type(config) == "table" then
                if not entry_map[name] then
                    ordered_names[#ordered_names + 1] = name
                end
                entry_map[name] = {
                    name = name,
                    config = config,
                    script = entry.script,
                    instanced = entry.instanced,
                }
            elseif config == null then
                entry_map[name] = nil
            end
        end
    end

    -- 2. Process dictionary elements
    local script = mod_value.script
    local instanced = mod_value.instanced
    for name, config in pairs(mod_value) do
        if type(name) == "string" and name ~= "script" and name ~= "instanced" then
            if type(config) == "table" then
                if not entry_map[name] then
                    ordered_names[#ordered_names + 1] = name
                end
                entry_map[name] = {
                    name = name,
                    config = config,
                    script = script,
                    instanced = instanced,
                }
            elseif config == null then
                entry_map[name] = nil
            end
        end
    end

    -- 3. Construct final entries list
    for _, name in ipairs(ordered_names) do
        if entry_map[name] then
            entries[#entries + 1] = entry_map[name]
        end
    end

    return entries
end

--- Resolve the script path for a mod entry.
--- If the entity has a component matching a registered path resolver,
--- that resolver is used. Otherwise falls back to entry.script or default.
local function resolve_script_path(world, entry, entity)
    -- Check if entity has a component with a registered path resolver.
    -- We use world:get_entity() to get a full entity snapshot because
    -- the query-returned entity only has components from the query filter.
    if entity and world then
        local full_entity = world:get_entity(entity:id())
        if full_entity then
            for comp_name, resolver_fn in pairs(state.path_resolvers) do
                if full_entity:has(comp_name) then
                    local resolved = resolver_fn(entry.name, entity:id())
                    if resolved then return resolved end
                end
            end
        end
    end
    -- Fallback: explicit script or default
    if entry.script then
        return entry.script
    end
    return "modules/" .. entry.name .. "/init.lua"
end

--- Increment ref count for a script path. Loads it if new.
--- on_loaded is called with the script's return value when it finishes loading.
--- If the script is already loaded, on_loaded is called immediately with the cached result.
--- If the script is still loading, on_loaded is queued and called when it finishes.
local function ref_script(path, instanced, on_loaded)
    local ref = state.ref_counts[path]
    if ref then
        ref.count = ref.count + 1
        if ref.result ~= nil then
            -- Script already loaded — replay cached result
            if on_loaded then on_loaded(ref.result) end
        else
            -- Script still loading — queue callback
            if on_loaded then
                ref.pending = ref.pending or {}
                ref.pending[#ref.pending + 1] = on_loaded
            end
        end
    else
        local pending = {}
        if on_loaded then pending[1] = on_loaded end
        state.ref_counts[path] = { count = 1, result = nil, pending = pending, instance_id = nil }
        -- Shared callback: caches result and fires all pending on_loaded callbacks.
        -- For instanced scripts, this runs inside require_async's callback with
        -- __LUA_STATE_ID__ set to the instanced state — so on_loaded hooks can
        -- read instanced resources and bridge data to global resources via upvalues.
        local function on_script_loaded(result)
            local r = state.ref_counts[path]
            if r then
                r.result = result
                -- __INSTANCE_ID__ inside require_async's callback is the loaded
                -- module's instance_id. Capture it so unref_script can call
                -- world:stop_script_instance(id) when the count hits 0.
                r.instance_id = __INSTANCE_ID__
                for _, cb in ipairs(r.pending or {}) do
                    cb(result)
                end
                r.pending = nil
            end
        end
        if instanced then
            require_async(path, on_script_loaded, { instanced = true, entity_despawn_mode = "all" })
        else
            require_async(path, on_script_loaded, { entity_despawn_mode = "all" })
        end
    end
end

--- Decrement ref count for a script path. Stops it when count reaches 0.
local function unref_script(world, path)
    local ref = state.ref_counts[path]
    if not ref then return end
    ref.count = ref.count - 1
    if ref.count <= 0 then
        local instance_id = ref.instance_id
        state.ref_counts[path] = nil
        if instance_id and world then
            -- Stop the script instance immediately (Lua ECS will despawn its
            -- entities and unregister its systems). Wrapped in pcall because
            -- the instance may already be gone if it stopped itself.
            pcall(function()
                world:stop_script_instance(instance_id)
            end)
        end
    end
end

--- Load a mod entry: resolve path, ref-count, patch mod-name component.
--- Discovers base chains via require_async callback.
local function load_mod(world, entity, entry)
    local path = resolve_script_path(world, entry, entity)
    local eid = entity:id()

    -- Callback: discover base chain + fire on_loaded hooks.
    -- Runs inside require_async callback, so for instanced scripts
    -- __LUA_STATE_ID__ is the instanced state_id.
    local function on_loaded(result)
        -- Wrap in pcall: during hot-reload, world may be stale
        -- (stop_script_instance invalidates the userdata)
        local ok, err = pcall(function()
            -- Base chain discovery
            if type(result) == "table" and result.base then
                local base_name = result.base

                -- Skip if base already tracked for this entity
                local mods = state.entity_mods[eid]
                if not (mods and mods[base_name]) then
                    local e = world:get_entity(eid)
                    if e then
                        -- Patch base component onto entity
                        e:patch({ [base_name] = {} })
                        -- Add base to mod component → triggers changed detection next frame
                        e:patch({ mod = { [base_name] = {} } })
                    end
                end
            end

            -- Fire on_loaded hooks for matching components on this entity
            local full_entity = world and world:get_entity(eid)
            if full_entity then
                for comp_name, hook_fn in pairs(state.on_loaded_hooks) do
                    if full_entity:has(comp_name) then
                        hook_fn(eid, result, entry.name)
                    end
                end
            end
        end)
        if not ok then
            -- Expected during hot-reload — world was invalidated
        end
    end

    -- Patch the mod-name component onto the entity BEFORE loading the script.
    -- This ensures the component exists when on_loaded hooks fire (which check
    -- entity:has(comp_name)).  For synchronously loaded scripts, the callback
    -- fires within ref_script, so the component must already be present.
    entity:patch({ [entry.name] = entry.config })

    -- Track
    state.entity_mods[eid] = state.entity_mods[eid] or {}
    state.entity_mods[eid][entry.name] = { path = path }

    ref_script(path, entry.instanced, on_loaded)
end

--- Unload a mod entry: unref the script and remove the mod-name component.
--- The mod dict entry should already be gone (via null patching or full removal).
local function unload_mod(world, entity, mod_name)
    local eid = entity:id()
    local mods = state.entity_mods[eid]
    if not mods or not mods[mod_name] then return end

    local info = mods[mod_name]
    unref_script(world, info.path)

    -- Remove the mod-name component from the entity
    entity:remove(mod_name)

    mods[mod_name] = nil
    if not next(mods) then
        state.entity_mods[eid] = nil
    end
end

---------------------------------------------------------------------------
-- System: ModLoader (First)
---------------------------------------------------------------------------

register_system("First", function(world)
    -- Process removed `mod` components FIRST so that despawned entities
    -- unload their mods (decrementing ref_counts) before new entities
    -- trigger fresh load_mod calls. This prevents stale module instances
    -- from surviving hot-reload.
    local removed = world:query({
        removed = { "mod" },
    })
    for _, entity in ipairs(removed) do
        local eid = entity:id()
        local mods = state.entity_mods[eid]
        if mods then
            -- Unload all mods (copy keys first since we modify during iteration)
            local names = {}
            for name, _ in pairs(mods) do names[#names + 1] = name end
            for _, name in ipairs(names) do
                unload_mod(world, entity, name)
            end
        end
    end

    -- Process added `mod` components
    local added = world:query({
        added = { "mod" },
        optional = { "mod" },
    })
    for _, entity in ipairs(added) do
        local mod_value = entity:get("mod")
        local entries = parse_mod_entries(mod_value)
        for _, entry in ipairs(entries) do
            load_mod(world, entity, entry)
        end
    end

    -- Process changed `mod` components.
    -- Compare current mod dict keys against entity_mods (what's actually loaded).
    -- No prev_mod snapshot needed — entity_mods is the source of truth.
    local changed = world:query({
        changed = { "mod" },
        optional = { "mod" },
    })
    for _, entity in ipairs(changed) do
        local eid = entity:id()
        local mod_value = entity:get("mod") or {}
        local loaded = state.entity_mods[eid] or {}

        -- Parse current mod entries (handles both array and dict formats)
        local entries = parse_mod_entries(mod_value)
        local current_by_name = {}
        for _, e in ipairs(entries) do current_by_name[e.name] = e end

        -- Unload mods that are loaded but no longer in the component
        local to_unload = {}
        for name, _ in pairs(loaded) do
            if not current_by_name[name] then
                to_unload[#to_unload + 1] = name
            end
        end
        for _, name in ipairs(to_unload) do
            unload_mod(world, entity, name)
        end

        -- Load mods that are in the component but not yet loaded
        for name, entry in pairs(current_by_name) do
            if not loaded[name] then
                load_mod(world, entity, entry)
            end
        end
    end
end, { label = "ModLoader" })

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

return {
    register_path_resolver = register_path_resolver,
    register_on_loaded = register_on_loaded,
    unload_mod = unload_mod,
}
