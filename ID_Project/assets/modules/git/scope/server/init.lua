-- modules/git/scope/server/init.lua
-- Scope lifecycle: worktree teardown when scopes are removed.
--
-- Worktree CREATION is now handled by worktree.get_asset_root() called from
-- server/main.lua and main.lua (client). The asset_root option on require_async
-- handles scoped asset resolution — no add_asset_path_resolver needed.
--
-- This module only watches ScopeInstances for removal to clean up worktrees.

local Git = require("modules/git/shared/git.lua")
local config = require("modules/git/scope/shared/config.lua")

---------------------------------------------------------------------------
-- State (persists across hot-reload via define_resource)
---------------------------------------------------------------------------
local state = define_resource("GitScopeState", {
    -- scope_key → worktree_path (tracks which worktrees we know about)
    active_worktrees = {},
})

---------------------------------------------------------------------------
-- System: GitScopeRemoved — clean up worktrees for removed scopes
-- Watches the ScopeInstances resource; any scope_key in active_worktrees
-- that's no longer in ScopeInstances gets its worktree cleaned up.
---------------------------------------------------------------------------
register_system("First", function(world)
    local scope_instances = define_resource("ScopeInstances", {})

    -- Track newly appearing scopes (to know their worktree path for cleanup)
    for scope_key, info in pairs(scope_instances) do
        if not state.active_worktrees[scope_key] then
            local worktree_path = config.get_worktree_path(scope_key)
            if worktree_path then
                state.active_worktrees[scope_key] = worktree_path
            end
        end
    end

    -- Clean up worktrees for scopes no longer in ScopeInstances
    for scope_key, wt_path in pairs(state.active_worktrees) do
        if not scope_instances[scope_key] then
            local repo_name = Git.parse_scope(scope_key)
            local repo_root = config.get_repo_path(repo_name)
            if repo_root then
                print(string.format("[GIT/SCOPE] Scope '%s' removed, cleaning up worktree at '%s'",
                    scope_key, wt_path))
                Git.remove_worktree(repo_root, wt_path)
            end
            state.active_worktrees[scope_key] = nil
        end
    end
end, { label = "GitScopeRemoved" })
