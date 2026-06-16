-- modules/git/shared/auth.lua
-- GitHub OAuth Device Flow authentication via HTTP proxy.
-- Moved from sidebar/github/panel/shared/auth.lua.
--
-- Usage:
--   local auth = require("modules/git/shared/auth.lua")
--   auth.start_device_flow()          -- begin sign-in
--   auth.poll_for_token()             -- poll during device flow
--   auth.handle_response(response)    -- process HttpProxyClientResponse
--   auth.is_authenticated()           -- check status

local json = require("modules/dkjson.lua")

local M = {}

-- ============================================================================
-- State (persists across hot-reload)
-- ============================================================================
local state = define_resource("GitHubAuthState", {
    status = "logged_out", -- "logged_out", "pending", "authenticated"
    access_token = nil,
    username = nil,
    device_code = nil,
    user_code = nil,
    verification_uri = nil,
    poll_interval = 5,
    next_request_id = 1,
    pending_responses = {},
})

local GITHUB_CLIENT_ID = "Ov23liWa7km5cDNAZadI"

-- ============================================================================
-- HTTP Proxy
-- ============================================================================

local function next_id()
    local id = state.next_request_id
    state.next_request_id = id + 1
    return id
end

function M.http_request(method, url, headers, body)
    local request_id = next_id()
    local request = {
        request_id = request_id,
        url = url,
        method = method,
        headers = headers or {},
        body = body,
    }
    if _G.queue_http_proxy_request then
        _G.queue_http_proxy_request(request)
    else
        print("[GitHub Auth] WARNING: queue_http_proxy_request not available")
    end
    return request_id
end

-- ============================================================================
-- Device Flow
-- ============================================================================

function M.start_device_flow()
    if state.status == "authenticated" then
        print("[GitHub Auth] Already authenticated as " .. (state.username or "unknown"))
        return
    end
    state.status = "pending"
    local request_id = M.http_request("POST",
        "https://github.com/login/device/code",
        {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        "client_id=" .. GITHUB_CLIENT_ID .. "&scope=repo"
    )
    state.pending_responses[request_id] = "device_code"
end

function M.poll_for_token()
    if state.status ~= "pending" or not state.device_code then return false end
    local request_id = M.http_request("POST",
        "https://github.com/login/oauth/access_token",
        {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        "client_id=" .. GITHUB_CLIENT_ID ..
        "&device_code=" .. state.device_code ..
        "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
    )
    state.pending_responses[request_id] = "poll_token"
    return true
end

function M.fetch_user_info()
    if not state.access_token then return end
    local request_id = M.http_request("GET",
        "https://api.github.com/user",
        {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. state.access_token,
            ["User-Agent"] = "Hello-Game",
        }
    )
    state.pending_responses[request_id] = "user_info"
end

function M.logout()
    state.status = "logged_out"
    state.access_token = nil
    state.username = nil
    state.device_code = nil
    state.user_code = nil
    state.verification_uri = nil
    print("[GitHub Auth] Logged out")
end

-- ============================================================================
-- Response Processing
-- ============================================================================

function M.handle_response(response)
    local response_type = state.pending_responses[response.request_id]
    if not response_type then return end
    state.pending_responses[response.request_id] = nil

    if response.error and response.error ~= "None" then
        print("[GitHub Auth] HTTP error: " .. tostring(response.error))
        return
    end

    local data = json.decode(response.body)
    if not data then
        print("[GitHub Auth] Failed to parse response")
        return
    end

    if response_type == "device_code" then
        if data.device_code then
            state.device_code = data.device_code
            state.user_code = data.user_code
            state.verification_uri = data.verification_uri
            state.poll_interval = data.interval or 5
            
            local url = "https://github.com/login/device"
            print("[GitHub Selector] Automatically opening login URL: " .. url)
            if _G.open_url then
                open_url(url)
            else
                print("[GitHub Selector] WARNING: open_url not available")
            end

            print("[GitHub Auth] Go to: " .. (state.verification_uri or "https://github.com/login/device"))
            print("[GitHub Auth] Enter code: " .. (state.user_code or "???"))
        else
            print("[GitHub Auth] Device code request failed")
            state.status = "logged_out"
        end
    elseif response_type == "poll_token" then
        if data.access_token then
            state.access_token = data.access_token
            state.status = "authenticated"
            state.device_code = nil
            print("[GitHub Auth] Authentication successful!")
            M.fetch_user_info()
        elseif data.error == "slow_down" then
            state.poll_interval = (state.poll_interval or 5) + 5
        elseif data.error == "expired_token" then
            state.status = "logged_out"
            state.device_code = nil
        end
    elseif response_type == "user_info" then
        if data.login then
            state.username = data.login
            print("[GitHub Auth] Authenticated as: " .. state.username)
        end
    end
end

-- ============================================================================
-- Getters
-- ============================================================================

function M.is_authenticated() return state.status == "authenticated" end
function M.is_pending() return state.status == "pending" end
function M.get_username() return state.username end
function M.get_user_code() return state.user_code end
function M.get_verification_uri() return state.verification_uri end
function M.get_access_token() return state.access_token end
function M.get_poll_interval() return state.poll_interval or 5 end

return M
