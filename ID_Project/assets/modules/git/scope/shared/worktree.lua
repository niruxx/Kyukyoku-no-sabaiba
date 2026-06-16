-- modules/git/scope/shared/worktree.lua
-- Worktree helper: ensures a git worktree exists for a scope_key
-- and returns the asset_root path. Used by server/main.lua and main.lua
-- to pass asset_root to require_async.

local Git = require("modules/git/shared/git.lua")
local config = require("modules/git/scope/shared/config.lua")

local M = {}

local function asset_root_for_checkout(checkout_path, repo)
    if checkout_path == "." then
        return nil
    end

    local relative = checkout_path:gsub("^assets/", "")
    -- For monorepos where assets/ is inside a subdirectory (e.g., Hello/assets/),
    -- include the subdirectory in the path so the worktree files are found.
    if repo and repo.assets_subdir then
        return relative .. "/" .. repo.assets_subdir .. "/assets/"
    end
    return relative .. "/assets/"
end

local function ensure_repo_cloned(repo)
    if repo.is_base then
        return true
    end

    local repo_root = config.get_repo_path(repo.name)
    if not repo_root then
        print("[GIT/SCOPE] ERROR: Unknown repo path for " .. tostring(repo.name))
        return false
    end

    if Git.dir_exists(repo_root) then
        return true
    end

    if not repo.remote then
        print("[GIT/SCOPE] ERROR: Missing remote URL for " .. tostring(repo.name))
        return false
    end

    print(string.format("[GIT/SCOPE] Cloning repo '%s' into '%s'", repo.name, repo_root))
    local ok, output = Git.clone(repo.remote, repo_root)
    if not ok then
        print(string.format("[GIT/SCOPE] ERROR: Failed to clone repo '%s': %s", repo.name, output))
        return false
    end

    return true
end

--- Returns the asset_root path for a scope_key, creating the worktree if needed.
--- Returns nil for the base repo's base branch (no asset override needed) or nil scope_key.
--- @param scope_key string|nil The scope identifier (e.g., "Hello-Rust2:feature-branch")
--- @return string|nil asset_root Path to worktree assets directory, or nil
function M.get_asset_root(scope_key)
    if not scope_key then return nil end

    local repo_name, branch = Git.parse_scope(scope_key)
    if not repo_name then return nil end

    local repo = config.get_repo(repo_name)
    if not repo then
        print("[GIT/SCOPE] ERROR: Unknown repo in scope: " .. tostring(scope_key))
        return nil
    end

    local base_branch = repo.base_branch or "main"
    if repo.is_base and branch == base_branch then
        return nil
    end

    if not ensure_repo_cloned(repo) then
        return nil
    end

    local checkout_path = config.get_worktree_path(scope_key)
    if not checkout_path then return nil end

    if branch ~= base_branch then
        local repo_root = config.get_repo_path(repo_name)
        if not repo_root then return nil end

        local worktree_arg = checkout_path
        if not repo.is_base then
            worktree_arg = config.worktree_base .. "/" .. repo_name .. "/" .. branch
        end

        local ok, output = Git.ensure_worktree(repo_root, branch, worktree_arg, checkout_path)
        if not ok then
            print(string.format("[GIT/SCOPE] ERROR: Failed to prepare scope '%s': %s",
                scope_key, output))
            return nil
        end
    end

    local result = asset_root_for_checkout(checkout_path, repo)
    print(string.format("[ASSET_ROOT_DEBUG] get_asset_root('%s') repo=%s branch=%s checkout=%s → asset_root=%s",
        tostring(scope_key), tostring(repo_name), tostring(branch),
        tostring(checkout_path), tostring(result)))
    return result
end

return M
