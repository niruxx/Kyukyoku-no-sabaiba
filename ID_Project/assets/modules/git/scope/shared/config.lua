-- modules/git/scope/shared/config.lua
-- Repository configuration for git/scope mod.
-- Edit this file to configure which repositories are available.

local M = {}

---------------------------------------------------------------------------
-- Repository Configuration
---------------------------------------------------------------------------

--- List of repositories managed by this server.
--- Each entry has:
---   name:         Repository identifier (used in scope keys like "Hello-Rust2:main")
---   owner:        GitHub username/org that owns the repo
---   remote:       GitHub remote URL (for cloning)
---   is_base:      If true, this repo's assets/ is the always-present fallback
---   base_branch:  The "main" branch name (default: "main")
M.repos = {
    {
        name = "Hello-Rust2",
        owner = "treytencarey",
        remote = "https://github.com/treytencarey/Hello-Rust2",
        is_base = true,
        base_branch = "main",
        assets_subdir = "Hello",  -- path from repo root to the directory containing assets/
    },
    {
        name = "Hello_Backrooms_Claude",
        owner = "ThumbHat",
        remote = "https://github.com/ThumbHat/Hello_Backrooms_Claude",
        is_base = false,
        base_branch = "main",
    }
}

--- Base directory for cloned repos (non-base repos are cloned here).
--- Convention: repos/{repo_name}/
M.repos_base = "assets/repos"

--- Base directory for git worktrees (branches other than the base branch).
--- Worktrees are created at: {worktree_base}/{repo_name}/{branch_name}
M.worktree_base = "assets/worktrees"

---------------------------------------------------------------------------
-- Helper Functions
---------------------------------------------------------------------------

--- Look up a repo config by name.
--- @param name string Repository name
--- @return table|nil Repo config table
function M.get_repo(name)
    for _, repo in ipairs(M.repos) do
        if repo.name == name then
            return repo
        end
    end
    return nil
end

--- Get the filesystem path for a repo's root.
--- Base repo returns "." (current directory).
--- Other repos return "repos/{name}".
--- @param name string Repository name
--- @return string|nil Path
function M.get_repo_path(name)
    local repo = M.get_repo(name)
    if not repo then return nil end
    if repo.is_base then
        return "."
    end
    return M.repos_base .. "/" .. name
end

--- Get the base branch for a repo (default "main").
--- @param name string Repository name
--- @return string Branch name
function M.get_base_branch(name)
    local repo = M.get_repo(name)
    return repo and repo.base_branch or "main"
end

--- Get the worktree path for a given scope_key.
--- @param scope_key string e.g., "Hello-Rust2:feature-xyz"
--- @return string|nil Filesystem path
function M.get_worktree_path(scope_key)
    local Git = require("modules/git/shared/git.lua")
    local repo_name, branch = Git.parse_scope(scope_key)
    local repo = M.get_repo(repo_name)
    if not repo then return nil end

    local base_branch = repo.base_branch or "main"

    if repo.is_base then
        -- Base repo: base branch is ".", others go to worktrees/
        if branch == base_branch then return "." end
        return M.worktree_base .. "/" .. repo_name .. "/" .. branch
    end

    -- Non-base repo: base branch is repos/{name}/, others are nested worktrees
    if branch == base_branch then
        return M.repos_base .. "/" .. repo_name
    end
    return M.repos_base .. "/" .. repo_name .. "/" .. M.worktree_base .. "/" .. repo_name .. "/" .. branch
end

--- Get the base (fallback) repo config.
--- @return table|nil Repo config with is_base=true
function M.get_base_repo()
    for _, repo in ipairs(M.repos) do
        if repo.is_base then
            return repo
        end
    end
    return nil
end

--- Get all repo names.
--- @return table List of repo name strings
function M.get_repo_names()
    local names = {}
    for _, repo in ipairs(M.repos) do
        names[#names + 1] = repo.name
    end
    return names
end

--- Get the owner for a repo.
--- @param name string Repository name
--- @return string|nil Owner
function M.get_owner(name)
    local repo = M.get_repo(name)
    return repo and repo.owner or nil
end

--- Get the GitHub remote URL for a repo.
--- @param name string Repository name
--- @return string|nil Remote URL
function M.get_remote(name)
    local repo = M.get_repo(name)
    return repo and repo.remote or nil
end

return M
