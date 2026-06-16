-- modules/git/shared/git.lua
-- Git plumbing library. Thin wrappers around io.popen("git ...").
-- No ECS, no components — pure utility functions.
--
-- Usage:
--   local Git = require("modules/git/shared/git.lua")
--   local files = Git.diff_files(".", "main", "feature-branch")

local Git = {}

---------------------------------------------------------------------------
-- Shell Helpers
---------------------------------------------------------------------------

--- Execute a shell command and capture stdout+stderr output.
--- @param cmd string Shell command to execute
--- @return boolean success, string output
function Git.exec(cmd)
    local handle = io.popen(cmd .. " 2>&1", "r")
    if not handle then
        return false, "Failed to execute command"
    end
    local output = handle:read("*a") or ""
    local ok, _, code = handle:close()
    local success = (ok == true) or (code == 0)
    return success, output
end

--- Check if a file exists on disk.
--- @param path string Filesystem path
--- @return boolean
function Git.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

--- Check if a directory exists on disk.
--- @param path string Filesystem path
--- @return boolean
function Git.dir_exists(path)
    local ok, _, code = os.execute('cd "' .. path .. '" 2>nul')
    return ok == true or code == 0
end

---------------------------------------------------------------------------
-- Scope Key
---------------------------------------------------------------------------

--- Build a scope key from repo name and branch.
--- @param repo string Repository name (e.g., "Hello-Rust2")
--- @param branch string Branch name (e.g., "feature-xyz")
--- @return string Scope key like "Hello-Rust2:feature-xyz"
function Git.scope_key(repo, branch)
    return repo .. ":" .. branch
end

--- Parse a scope key into repo and branch.
--- @param scope_key string Scope key like "Hello-Rust2:feature-xyz"
--- @return string, string repo, branch
function Git.parse_scope(scope_key)
    local repo, branch = scope_key:match("^(.+):(.+)$")
    return repo or scope_key, branch or "main"
end

---------------------------------------------------------------------------
-- Git Operations
---------------------------------------------------------------------------

--- Fetch latest from origin.
--- @param repo_root string Path to the git repo root
--- @return boolean success, string output
function Git.fetch(repo_root)
    return Git.exec(string.format('cd "%s" && git fetch origin', repo_root))
end

--- Clone a repository to target_path.
--- @param remote_url string Git remote URL
--- @param target_path string Target directory
--- @return boolean success, string output
function Git.clone(remote_url, target_path)
    return Git.exec(string.format('git clone "%s" "%s"', remote_url, target_path))
end

--- List files changed between two branches.
--- Returns a list of relative paths (from repo root) that differ.
--- @param repo_root string Path to the git repo root
--- @param base string Base branch name (e.g., "main")
--- @param target string Target branch name (e.g., "feature-xyz")
--- @return table List of changed file paths
function Git.diff_files(repo_root, base, target)
    local cmd = string.format(
        'cd "%s" && git diff --name-only "%s" "%s"',
        repo_root, base, target
    )
    local ok, output = Git.exec(cmd)
    if not ok then
        print(string.format("[GIT] WARNING: diff failed: %s", output))
        return {}
    end

    local files = {}
    for line in output:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            files[#files + 1] = trimmed
        end
    end
    return files
end

--- Ensure a worktree exists for the given branch.
--- Creates the worktree if it doesn't exist, fetches and prunes first.
--- @param repo_root string Path to the git repo root
--- @param branch string Branch name
--- @param worktree_path string Filesystem path for the worktree, relative to repo_root when repo_root is not "."
--- @param exists_path string|nil Filesystem path to check when worktree_path is repo-relative
--- @return boolean success, string output_or_error
function Git.ensure_worktree(repo_root, branch, worktree_path, exists_path)
    -- Check if already exists on disk
    if Git.dir_exists(exists_path or worktree_path) then
        return true, "already exists"
    end

    -- Fetch latest and prune stale worktree entries
    Git.fetch(repo_root)
    Git.exec(string.format('cd "%s" && git worktree prune', repo_root))

    -- Try to add worktree for existing branch
    local add_cmd = string.format(
        'cd "%s" && git worktree add "%s" "%s"',
        repo_root, worktree_path, branch
    )
    local ok, output = Git.exec(add_cmd)

    if not ok then
        -- The branch might be locked by a stale worktree entry, or might not exist.
        -- Try force-adding the existing branch first (--force unlocks stale entries).
        local force_cmd = string.format(
            'cd "%s" && git worktree add --force "%s" "%s"',
            repo_root, worktree_path, branch
        )
        ok, output = Git.exec(force_cmd)

        if not ok then
            -- Branch truly doesn't exist — create it tracking origin/main
            local create_cmd = string.format(
                'cd "%s" && git worktree add -b "%s" "%s" origin/main',
                repo_root, branch, worktree_path
            )
            ok, output = Git.exec(create_cmd)

            if not ok then
                print(string.format("[GIT] ERROR: Failed to create worktree '%s': %s",
                    worktree_path, output))
                return false, output
            end
        end
    end

    return true, output
end

--- Remove a worktree.
--- @param repo_root string Path to the git repo root
--- @param worktree_path string Filesystem path of the worktree to remove
--- @return boolean success, string output
function Git.remove_worktree(repo_root, worktree_path)
    local cmd = string.format(
        'cd "%s" && git worktree remove "%s" --force',
        repo_root, worktree_path
    )
    return Git.exec(cmd)
end

---------------------------------------------------------------------------
-- Git Workflow (commit, push, pull)
---------------------------------------------------------------------------

--- Stage all changes and commit.
--- @param worktree_path string Path to the worktree
--- @param message string Commit message
--- @return boolean success, string output
function Git.commit(worktree_path, message)
    local cmd = string.format(
        'cd "%s" && git add -A && git commit -m "%s"',
        worktree_path, message:gsub('"', '\\"')
    )
    return Git.exec(cmd)
end

--- Push to origin.
--- @param worktree_path string Path to the worktree
--- @param branch string Branch name to push
--- @return boolean success, string output
function Git.push(worktree_path, branch)
    return Git.exec(string.format('cd "%s" && git push origin "%s"', worktree_path, branch))
end

--- Pull from origin.
--- @param worktree_path string Path to the worktree
--- @param branch string Branch name to pull
--- @return boolean success, string output
function Git.pull(worktree_path, branch)
    return Git.exec(string.format('cd "%s" && git pull origin "%s"', worktree_path, branch))
end

--- Get git status (short format) for a worktree.
--- @param worktree_path string Path to the worktree
--- @return boolean success, string output
function Git.status(worktree_path)
    return Git.exec(string.format('cd "%s" && git status --short', worktree_path))
end

--- Get diff stat summary for a worktree.
--- @param worktree_path string Path to the worktree
--- @return boolean success, string output
function Git.diff_summary(worktree_path)
    return Git.exec(string.format('cd "%s" && git diff --stat', worktree_path))
end

--- Get commit log (oneline format).
--- @param worktree_path string Path to the worktree or repo root
--- @param count number Number of commits to show (default 10)
--- @return table List of { hash, message } tables
function Git.log(worktree_path, count)
    count = count or 10
    local cmd = string.format(
        'cd "%s" && git log --oneline -n %d',
        worktree_path, count
    )
    local ok, output = Git.exec(cmd)
    if not ok then return {} end

    local entries = {}
    for line in output:gmatch("[^\r\n]+") do
        local hash, msg = line:match("^(%S+)%s+(.+)$")
        if hash then
            entries[#entries + 1] = { hash = hash, message = msg }
        end
    end
    return entries
end

--- List all branches (local and remote).
--- @param repo_root string Path to the git repo root
--- @return table List of { name, is_remote, is_current } tables
function Git.list_branches(repo_root)
    local cmd = string.format('cd "%s" && git branch -a --no-color', repo_root)
    local ok, output = Git.exec(cmd)
    if not ok then return {} end

    local branches = {}
    for line in output:gmatch("[^\r\n]+") do
        local is_current = line:sub(1, 2) == "* "
        local name = line:gsub("^[%s%*]+", ""):gsub("%s+$", "")
        -- Skip HEAD pointers
        if not name:match("HEAD") then
            local is_remote = name:match("^remotes/") ~= nil
            -- Clean remote prefix for display
            local display_name = name:gsub("^remotes/origin/", "")
            branches[#branches + 1] = {
                name = display_name,
                full_name = name,
                is_remote = is_remote,
                is_current = is_current,
            }
        end
    end
    return branches
end

--- Create a new branch (without switching to it).
--- @param repo_root string Path to the git repo root
--- @param branch_name string New branch name
--- @param base_branch string Branch to create from (default "main")
--- @return boolean success, string output
function Git.create_branch(repo_root, branch_name, base_branch)
    base_branch = base_branch or "main"
    return Git.exec(string.format(
        'cd "%s" && git branch "%s" "%s"',
        repo_root, branch_name, base_branch
    ))
end

return Git
