-- modules/git/shared/api.lua
-- GitHub REST API wrapper via HTTP proxy.
-- Moved from sidebar/github/panel/shared/api.lua.
--
-- Usage:
--   local auth = require("modules/git/shared/auth.lua")
--   local api  = require("modules/git/shared/api.lua")
--   api.list_branches(auth, "owner", "repo", function(branches, err) ... end)

local json = require("modules/dkjson.lua")

local M = {}

-- ============================================================================
-- State
-- ============================================================================
local state = define_resource("GitHubApiState", {
    next_request_id = 1000,
    pending_callbacks = {},
})

-- ============================================================================
-- Internal Helpers
-- ============================================================================

local function next_id()
    local id = state.next_request_id
    state.next_request_id = id + 1
    return id
end

function M.request(auth, method, endpoint, body, callback)
    if not auth.is_authenticated() then
        if callback then callback(nil, "Not authenticated") end
        return
    end

    local url = "https://api.github.com" .. endpoint
    local headers = {
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. auth.get_access_token(),
        ["User-Agent"] = "Hello-Game",
    }
    if body then
        headers["Content-Type"] = "application/json"
    end

    local request_id = next_id()
    local request = {
        request_id = request_id,
        url = url,
        method = method,
        headers = headers,
        body = body and json.encode(body) or nil,
    }
    if callback then
        state.pending_callbacks[request_id] = callback
    end

    if _G.queue_http_proxy_request then
        _G.queue_http_proxy_request(request)
    else
        print("[GitHub API] WARNING: queue_http_proxy_request not available")
        if callback then callback(nil, "HTTP proxy not available") end
    end

    return request_id
end

-- ============================================================================
-- Response Processing
-- ============================================================================

function M.handle_response(response)
    local callback = state.pending_callbacks[response.request_id]
    if not callback then return end
    state.pending_callbacks[response.request_id] = nil

    if response.error and response.error ~= "None" then
        callback(nil, response.error)
        return
    end

    if tonumber(response.status) >= 400 then
        local data = json.decode(response.body)
        local msg = data and data.message or ("HTTP " .. response.status)
        callback(nil, msg)
        return
    end

    local data = json.decode(response.body)
    callback(data, nil)
end

-- ============================================================================
-- Convenience Methods
-- ============================================================================

function M.list_branches(auth, owner, repo, callback)
    M.request(auth, "GET",
        string.format("/repos/%s/%s/branches?per_page=100", owner, repo),
        nil, function(data, err)
            if err then callback(nil, err); return end
            local branches = {}
            if data then
                for _, branch in ipairs(data) do
                    branches[#branches + 1] = branch.name
                end
            end
            callback(branches, nil)
        end
    )
end

function M.create_branch(auth, owner, repo, branch_name, from_sha, callback)
    M.request(auth, "POST",
        string.format("/repos/%s/%s/git/refs", owner, repo),
        { ref = "refs/heads/" .. branch_name, sha = from_sha },
        callback
    )
end

function M.get_branch_sha(auth, owner, repo, branch, callback)
    M.request(auth, "GET",
        string.format("/repos/%s/%s/git/ref/heads/%s", owner, repo, branch),
        nil, function(data, err)
            if err then callback(nil, err); return end
            callback(data and data.object and data.object.sha, nil)
        end
    )
end

function M.create_pull_request(auth, owner, repo, title, head, base, callback)
    M.request(auth, "POST",
        string.format("/repos/%s/%s/pulls", owner, repo),
        { title = title, head = head, base = base },
        callback
    )
end

function M.get_commits(auth, owner, repo, branch, count, callback)
    count = count or 10
    M.request(auth, "GET",
        string.format("/repos/%s/%s/commits?sha=%s&per_page=%d", owner, repo, branch, count),
        nil, function(data, err)
            if err then callback(nil, err); return end
            local commits = {}
            if data then
                for _, commit in ipairs(data) do
                    commits[#commits + 1] = {
                        sha = commit.sha and commit.sha:sub(1, 7) or "???",
                        message = commit.commit and commit.commit.message or "",
                        author = commit.commit and commit.commit.author and commit.commit.author.name or "unknown",
                        date = commit.commit and commit.commit.author and commit.commit.author.date or "",
                    }
                end
            end
            callback(commits, nil)
        end
    )
end

return M
