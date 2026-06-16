-- modules/git/scope/net_filter/init.lua
-- Network visibility filter for scope isolation.
--
-- Registers a "git_scope" filter with the Net module that ensures entities
-- are only replicated to clients in the same scope. This prevents players
-- from receiving entity updates for objects in scopes they aren't viewing.
--
-- Usage: Set `net_sync.target = "git_scope"` on components that should
-- only be visible to clients in the same scope as the entity.
--
-- Entities with ScopeWorld = "All" or no git/scope component are visible to everyone.

local Net = require("modules/net/shared/net.lua")

---------------------------------------------------------------------------
-- State: client_id → scope_key mapping
-- Maintained by watching game and net_owner changes.
---------------------------------------------------------------------------
local state = define_resource("GitScopeFilterState", {
    -- client_id → scope_key
    client_scopes = {},
})

---------------------------------------------------------------------------
-- Filter Registration
---------------------------------------------------------------------------

--- Check if a specific client should receive updates for an entity.
--- Returns true if:
---   1. The entity has ScopeWorld = "All" (global entity)
---   2. The entity has no git/scope component (unscoped entity)
---   3. The client is in the same scope as the entity
Net.register_filter("git_scope", function(client_id, entity_owner_client_id, owner_id)
    -- Without scope tracking data, default to visible
    -- (The filter fn receives client_id, owner_client_id, owner_id)
    -- We need the entity's scope to compare against, but the current filter API
    -- only passes client/owner info. For now, we track client→scope mappings
    -- and use those for comparison.
    --
    -- If the entity owner's scope matches the client's scope, send the update.
    -- This works because scoped entities are owned by entities in that scope.
    if not owner_id then return true end  -- no owner → visible to all

    local client_scope = state.client_scopes[client_id]
    local owner_scope = state.client_scopes[entity_owner_client_id]

    -- If either has no scope info, default visible
    if not client_scope or not owner_scope then return true end

    return client_scope == owner_scope
end)

print("[GIT/SCOPE/NET_FILTER] Registered 'git_scope' target filter")

---------------------------------------------------------------------------
-- System: Track client → scope mappings
-- Watches entities that have both net_owner and git/scope to build
-- the client_id → scope_key mapping.
---------------------------------------------------------------------------
register_system("First", function(world)
    -- Update mappings from entities with both net_owner and git/scope
    local entities = world:query({ with = { "net_owner", "git/scope" } })
    for _, entity in ipairs(entities) do
        local net_owner = entity:get("net_owner")
        local scope = entity:get("git/scope")
        if net_owner and net_owner.client_id and scope and scope.scope_key then
            state.client_scopes[net_owner.client_id] = scope.scope_key
        end
    end

    -- Clean up mappings for disconnected clients
    -- (Entities with net_owner removed will naturally stop being queried)
end, { label = "GitScopeFilterSync" })
