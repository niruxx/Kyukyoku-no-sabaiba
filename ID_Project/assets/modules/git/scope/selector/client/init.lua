-- modules/git/scope/selector/init.lua
-- Sidebar panel for branch/repo selection with GitHub OAuth authentication.
--
-- Shows GitHub sign-in flow (device code), then after authentication:
-- - Lists branches from GitHub API (remote branches)
-- - Click to switch scopes
-- - Commit history for selected branch

local Colors = require("modules/sidebar/shared/colors.lua")
local Git = require("modules/git/shared/git.lua")
local auth = require("modules/git/shared/auth.lua")
local api = require("modules/git/shared/api.lua")
local config = require("modules/git/scope/shared/config.lua")

local json = require("modules/dkjson.lua")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local PANEL_WIDTH = 280
local POLL_INTERVAL = 5 -- seconds between token polls

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local state = define_resource("GitScopeSelectorState", {
    current_scope_key = nil,
    -- Selection
    selected_repo = nil,       -- repo name string (NOT auto-selected; user must choose)
    selected_branch = nil,     -- branch name string
    -- Remote branches (from GitHub API)
    remote_branches = {},
    remote_branches_loaded = false,
    -- Remote commits (from GitHub API)
    remote_commits = {},
    -- Timers
    poll_timer = 0,
    refresh_timer = 0,
    scroll_offset = 0,
    update_counter = 0,
    -- Dropdown open flags
    repo_dropdown_open = false,
    branch_dropdown_open = false,
    -- Auto-switch tracking
    switch_triggered = false,  -- true once we've auto-switched after repo selection
})

local ui = {
    owner_entity = nil,   -- player entity that owns the git/scope/selector component
    panel_entity = nil,
    header_container = nil,
    scroll_container = nil,
    content_entities = {},
    needs_render = false,
    -- Reactivity snapshots
    last_auth_status = nil,
    last_scope_key = nil,
    last_branch_count = 0,
    last_commit_count = 0,
    last_user_code = nil,
    last_selected_repo = nil,
    last_selected_branch = nil,
    last_repo_dropdown = false,
    last_branch_dropdown = false,
}

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

local function refresh_branches()
    if not auth.is_authenticated() then return end
    local repo_name = state.selected_repo
    if not repo_name then return end

    local owner = config.get_owner(repo_name)
    if not owner then return end

    api.list_branches(auth, owner, repo_name, function(branches, err)
        if err then
            print("[GIT/SCOPE/SELECTOR] Branch fetch error: " .. tostring(err))
            return
        end
        state.remote_branches = branches or {}
        state.remote_branches_loaded = true
        -- Auto-select first branch if none selected
        if not state.selected_branch and #state.remote_branches > 0 then
            state.selected_branch = state.remote_branches[1]
        end
        ui.needs_render = true
    end)
end

local function refresh_commits(branch)
    if not auth.is_authenticated() then return end
    local repo_name = state.selected_repo
    if not repo_name then return end

    local owner = config.get_owner(repo_name)
    if not owner then return end

    api.get_commits(auth, owner, repo_name, branch or "main", 8, function(commits, err)
        if err then
            print("[GIT/SCOPE/SELECTOR] Commit fetch error: " .. tostring(err))
            return
        end
        state.remote_commits = commits or {}
        ui.needs_render = true
    end)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Determine the local player's current scope.
local function get_current_scope(world)
    local players = world:query({ with = { "net_local", "git/scope" } })
    if #players > 0 then
        local gs = players[1]:get("git/scope")
        return gs and gs.scope_key
    end
    return nil
end

--------------------------------------------------------------------------------
-- UI Widgets
--------------------------------------------------------------------------------

--- Generic dropdown builder. Shows a selected value with ▼ toggle.
local function build_dropdown(parent, label, options, selected, is_open, on_toggle, on_select)
    -- Label
    local label_row = spawn({
        Node = { width = { Percent = 100 }, margin = { top = { Px = 8 }, bottom = { Px = 4 } } },
    }):with_parent(parent)
    table.insert(ui.content_entities, label_row:id())

    spawn({
        Text = { text = label },
        TextFont = { font_size = 10 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(label_row:id())

    -- Dropdown trigger button
    local trigger = spawn({
        Node = {
            width = { Percent = 100 }, height = { Px = 30 },
            flex_direction = "Row", align_items = "Center",
            justify_content = "SpaceBetween",
            padding = { left = { Px = 8 }, right = { Px = 8 } },
            border = { left = { Px = 1 }, right = { Px = 1 }, top = { Px = 1 }, bottom = { Px = 1 } },
        },
        BackgroundColor = { color = Colors.row_bg },
        BorderColor = {
            left = Colors.border, right = Colors.border,
            top = Colors.border, bottom = Colors.border,
        },
        BorderRadius = {
            top_left = { Px = 4 }, top_right = { Px = 4 },
            bottom_left = is_open and { Px = 0 } or { Px = 4 },
            bottom_right = is_open and { Px = 0 } or { Px = 4 },
        },
    }):with_parent(parent)
    table.insert(ui.content_entities, trigger:id())

    spawn({
        Text = { text = selected or "(none)" },
        TextFont = { font_size = 12 },
        TextColor = { color = selected and Colors.text or Colors.text_dim },
    }):with_parent(trigger:id())

    spawn({
        Text = { text = is_open and "▲" or "▼" },
        TextFont = { font_size = 10 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(trigger:id())

    trigger:observe("Pointer<Click>", function() on_toggle() end)
    trigger:observe("Pointer<Over>", function(_, e)
        e:patch({ BackgroundColor = { color = Colors.row_hover } })
    end)
    trigger:observe("Pointer<Out>", function(_, e)
        e:patch({ BackgroundColor = { color = Colors.row_bg } })
    end)

    -- Options list (only if open)
    if is_open and #options > 0 then
        local list = spawn({
            Node = {
                width = { Percent = 100 }, flex_direction = "Column",
                max_height = { Px = 180 },
                overflow = { x = "Visible", y = "Scroll" },
                border = { left = { Px = 1 }, right = { Px = 1 }, bottom = { Px = 1 } },
            },
            BackgroundColor = { color = Colors.bg },
            BorderColor = {
                left = Colors.border, right = Colors.border,
                top = Colors.border, bottom = Colors.border,
            },
            BorderRadius = {
                top_left = { Px = 0 }, top_right = { Px = 0 },
                bottom_left = { Px = 4 }, bottom_right = { Px = 4 },
            },
        }):with_parent(parent)
        table.insert(ui.content_entities, list:id())

        for i, opt in ipairs(options) do
            local is_sel = (opt == selected)
            local opt_row = spawn({
                Node = {
                    width = { Percent = 100 }, height = { Px = 26 },
                    align_items = "Center",
                    padding = { left = { Px = 8 }, right = { Px = 8 } },
                },
                BackgroundColor = { color = is_sel and Colors.row_selected or Colors.row_bg },
            }):with_parent(list:id())

            spawn({
                Text = { text = opt },
                TextFont = { font_size = 11 },
                TextColor = { color = is_sel and Colors.text or Colors.text_dim },
            }):with_parent(opt_row:id())

            if not is_sel then
                local val = opt
                opt_row:observe("Pointer<Click>", function() on_select(val) end)
                opt_row:observe("Pointer<Over>", function(_, e)
                    e:patch({ BackgroundColor = { color = Colors.row_hover } })
                end)
                opt_row:observe("Pointer<Out>", function(_, e)
                    e:patch({ BackgroundColor = { color = Colors.row_bg } })
                end)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- UI Sections
--------------------------------------------------------------------------------

local function build_auth_section(parent)
    -- Section header
    local header = spawn({
        Node = {
            width = { Percent = 100 },
            margin = { bottom = { Px = 4 } },
        },
    }):with_parent(parent)
    table.insert(ui.content_entities, header:id())

    spawn({
        Text = { text = "GITHUB ACCOUNT" },
        TextFont = { font_size = 10 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(header:id())

    if auth.is_authenticated() then
        -- Authenticated: show username + sign out
        local user_row = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 28 },
                flex_direction = "Row",
                align_items = "Center",
                justify_content = "SpaceBetween",
                padding = { left = { Px = 8 }, right = { Px = 8 } },
            },
            BackgroundColor = { color = Colors.row_bg },
        }):with_parent(parent)
        table.insert(ui.content_entities, user_row:id())

        spawn({
            Text = { text = "✓ " .. (auth.get_username() or "Authenticated") },
            TextFont = { font_size = 12 },
            TextColor = { color = Colors.text_good },
        }):with_parent(user_row:id())

        -- Sign out button
        local signout = spawn({
            Node = {
                padding = { left = { Px = 6 }, right = { Px = 6 }, top = { Px = 2 }, bottom = { Px = 2 } },
                align_items = "Center",
            },
            BackgroundColor = { color = Colors.row_alt },
        }):with_parent(user_row:id())
        spawn({
            Text = { text = "Sign Out" },
            TextFont = { font_size = 10 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(signout:id())
        signout:observe("Pointer<Click>", function()
            auth.logout()
            state.remote_branches = {}
            state.remote_branches_loaded = false
            state.remote_commits = {}
            ui.needs_render = true
        end)
        signout:observe("Pointer<Over>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.row_hover } })
        end)
        signout:observe("Pointer<Out>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.row_alt } })
        end)

    elseif auth.is_pending() then
        -- Device flow pending: show user code
        local code = auth.get_user_code()
        if code then
            spawn({
                Text = { text = "Enter code at github.com/login/device:" },
                TextFont = { font_size = 11 },
                TextColor = { color = Colors.text_dim },
                Node = { margin = { bottom = { Px = 4 } } },
            }):with_parent(parent)

            local code_bg = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = 44 },
                    justify_content = "Center",
                    align_items = "Center",
                    margin = { bottom = { Px = 4 } },
                },
                BackgroundColor = { color = Colors.row_bg },
            }):with_parent(parent)
            table.insert(ui.content_entities, code_bg:id())

            spawn({
                Text = { text = code },
                TextFont = { font_size = 22 },
                TextColor = { color = Colors.accent },
            }):with_parent(code_bg:id())

            spawn({
                Text = { text = "Waiting for authorization..." },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text_dim },
            }):with_parent(parent)
        else
            spawn({
                Text = { text = "Requesting code..." },
                TextFont = { font_size = 12 },
                TextColor = { color = Colors.text_dim },
            }):with_parent(parent)
        end

    else
        -- Not authenticated: show sign-in button
        local btn = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 32 },
                justify_content = "Center",
                align_items = "Center",
            },
            BackgroundColor = { color = Colors.icon_bg },
        }):with_parent(parent)
        table.insert(ui.content_entities, btn:id())

        spawn({
            Text = { text = "Sign in with GitHub" },
            TextFont = { font_size = 12 },
            TextColor = { color = Colors.text },
        }):with_parent(btn:id())

        btn:observe("Pointer<Click>", function()
            auth.start_device_flow()
            ui.needs_render = true
        end)
        btn:observe("Pointer<Over>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.icon_hover } })
        end)
        btn:observe("Pointer<Out>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.icon_bg } })
        end)
    end
end

--- Queue a scope switch to the default branch of the selected repo.
--- Sets pending_switch_scope which the Update system picks up and sends to server.
local function trigger_default_switch()
    if not state.selected_repo then return end
    if state.switch_triggered then return end

    local base_branch = config.get_base_branch(state.selected_repo)
    local scope_key = Git.scope_key(state.selected_repo, base_branch)

    -- Don't switch if we're already on this scope
    if scope_key == state.current_scope_key then
        state.switch_triggered = true
        return
    end

    state.switch_triggered = true
    state.selected_branch = base_branch
    state.current_scope_key = scope_key

    print(string.format("[GIT/SCOPE/SELECTOR] Auto-switching to default scope: %s", scope_key))

    -- Queue the switch — Update system will send to server
    state.pending_switch_scope = scope_key

    refresh_commits(base_branch)
    ui.needs_render = true
end

local function build_repo_section(parent)
    local repo_names = config.get_repo_names()
    -- No auto-select: user must choose a repo explicitly

    build_dropdown(parent, "REPOSITORY", repo_names, state.selected_repo,
        state.repo_dropdown_open,
        function()
            state.repo_dropdown_open = not state.repo_dropdown_open
            state.branch_dropdown_open = false -- close other dropdown
            ui.needs_render = true
        end,
        function(val)
            state.selected_repo = val
            state.repo_dropdown_open = false
            state.switch_triggered = false  -- allow auto-switch for new repo
            -- Reset branch selection for new repo
            state.selected_branch = nil
            state.remote_branches = {}
            state.remote_branches_loaded = false
            state.remote_commits = {}
            refresh_branches()
            ui.needs_render = true
        end
    )
end

local function build_branch_section(parent)
    build_dropdown(parent, "BRANCH", state.remote_branches, state.selected_branch,
        state.branch_dropdown_open,
        function()
            state.branch_dropdown_open = not state.branch_dropdown_open
            state.repo_dropdown_open = false -- close other dropdown
            ui.needs_render = true
        end,
        function(val)
            state.selected_branch = val
            state.branch_dropdown_open = false
            refresh_commits(val)
            ui.needs_render = true
        end
    )
end

local function build_action_buttons(parent, world)
    if not state.selected_repo or not state.selected_branch then return end

    local scope_key = Git.scope_key(state.selected_repo, state.selected_branch)
    local is_current = (scope_key == state.current_scope_key)

    local row = spawn({
        Node = {
            width = { Percent = 100 },
            flex_direction = "Row",
            column_gap = { Px = 6 },
            margin = { top = { Px = 8 } },
        },
    }):with_parent(parent)
    table.insert(ui.content_entities, row:id())

    -- Switch button (↗)
    local switch_bg = is_current and Colors.row_alt or Colors.icon_bg
    local switch_btn = spawn({
        Node = {
            flex_grow = 1,
            height = { Px = 32 },
            justify_content = "Center",
            align_items = "Center",
            flex_direction = "Row",
            column_gap = { Px = 4 },
            border = { left = { Px = 1 }, right = { Px = 1 }, top = { Px = 1 }, bottom = { Px = 1 } },
        },
        BackgroundColor = { color = switch_bg },
        BorderColor = {
            left = Colors.border, right = Colors.border,
            top = Colors.border, bottom = Colors.border,
        },
        BorderRadius = {
            top_left = { Px = 4 }, top_right = { Px = 4 },
            bottom_left = { Px = 4 }, bottom_right = { Px = 4 },
        },
    }):with_parent(row:id())

    spawn({
        Text = { text = is_current and "● Current" or "↗ Switch" },
        TextFont = { font_size = 12 },
        TextColor = { color = is_current and Colors.text_dim or Colors.text },
    }):with_parent(switch_btn:id())

    if not is_current then
        local sk = scope_key
        local br = state.selected_branch
        switch_btn:observe("Pointer<Click>", function(clicked_world)
            print(string.format("[GIT/SCOPE/SELECTOR] Requesting switch to scope: %s", sk))
            local entity = clicked_world:get_entity(ui.owner_entity)
            if entity then
                entity:patch({
                    ["git/scope/selector"] = { switch_scope = sk }
                })
            end
            state.current_scope_key = sk
            refresh_commits(br)
            ui.needs_render = true
        end)
        switch_btn:observe("Pointer<Over>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.icon_hover } })
        end)
        switch_btn:observe("Pointer<Out>", function(_, e)
            e:patch({ BackgroundColor = { color = switch_bg } })
        end)
    end

    -- Portal button (🌀)
    local portal_bg = is_current and Colors.row_alt or Colors.icon_bg
    local portal_btn = spawn({
        Node = {
            flex_grow = 1,
            height = { Px = 32 },
            justify_content = "Center",
            align_items = "Center",
            flex_direction = "Row",
            column_gap = { Px = 4 },
            border = { left = { Px = 1 }, right = { Px = 1 }, top = { Px = 1 }, bottom = { Px = 1 } },
        },
        BackgroundColor = { color = portal_bg },
        BorderColor = {
            left = Colors.border, right = Colors.border,
            top = Colors.border, bottom = Colors.border,
        },
        BorderRadius = {
            top_left = { Px = 4 }, top_right = { Px = 4 },
            bottom_left = { Px = 4 }, bottom_right = { Px = 4 },
        },
    }):with_parent(row:id())

    spawn({
        Text = { text = "🌀 Portal" },
        TextFont = { font_size = 12 },
        TextColor = { color = is_current and Colors.text_dim or Colors.text },
    }):with_parent(portal_btn:id())

    if not is_current then
        local net_info = define_resource("NetInfo", {})
        local current_sk = state.current_scope_key or net_info.scope_key
        local target_sk = scope_key
        portal_btn:observe("Pointer<Click>", function(clicked_world)
            local entity = clicked_world:get_entity(ui.owner_entity)
            if entity then
                entity:patch({
                    ["git/scope/selector"] = { open_portal = { current_sk = current_sk, target_sk = target_sk } }
                })
            end
        end)
        portal_btn:observe("Pointer<Over>", function(_, e)
            e:patch({ BackgroundColor = { color = Colors.icon_hover } })
        end)
        portal_btn:observe("Pointer<Out>", function(_, e)
            e:patch({ BackgroundColor = { color = portal_bg } })
        end)
    end
end

local function build_commits_section(parent)
    if #state.remote_commits == 0 then return end

    local header = spawn({
        Node = {
            width = { Percent = 100 },
            margin = { top = { Px = 8 }, bottom = { Px = 4 } },
        },
    }):with_parent(parent)
    table.insert(ui.content_entities, header:id())

    spawn({
        Text = { text = "RECENT COMMITS" },
        TextFont = { font_size = 10 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(header:id())

    for i, commit in ipairs(state.remote_commits) do
        local row = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 22 },
                flex_direction = "Row",
                align_items = "Center",
                column_gap = { Px = 6 },
                padding = { left = { Px = 8 }, right = { Px = 8 } },
            },
            BackgroundColor = { color = (i % 2 == 0) and Colors.row_alt or Colors.row_bg },
        }):with_parent(parent)
        table.insert(ui.content_entities, row:id())

        spawn({
            Text = { text = commit.sha },
            TextFont = { font_size = 9 },
            TextColor = { color = Colors.accent },
        }):with_parent(row:id())

        local msg = commit.message or ""
        local first_line = msg:match("^([^\n]+)") or msg
        if #first_line > 30 then first_line = first_line:sub(1, 27) .. "..." end

        spawn({
            Text = { text = first_line },
            TextFont = { font_size = 10 },
            TextColor = { color = Colors.text },
        }):with_parent(row:id())
    end
end

--------------------------------------------------------------------------------
-- Main UI Build
--------------------------------------------------------------------------------

local function update_ui_content(world)
    if not ui.panel_entity then return end

    -- Clear old content
    for _, entity_id in ipairs(ui.content_entities or {}) do
        despawn(entity_id)
    end
    ui.content_entities = {}

    -- Auth section (always visible)
    build_auth_section(ui.scroll_container)

    -- Dropdowns + actions (only when authenticated)
    if auth.is_authenticated() then
        build_repo_section(ui.scroll_container)
        build_branch_section(ui.scroll_container)
        build_action_buttons(ui.scroll_container, world)
        build_commits_section(ui.scroll_container)
    end
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "git/scope/selector" } })
    for _, entity in ipairs(entities) do
        local cfg = entity:get("git/scope/selector") or {}
        local parent_id = cfg.container_id or entity:id()

        local panel = spawn({
            Node = {
                width = { Px = PANEL_WIDTH },
                height = { Percent = 100 },
                flex_direction = "Column",
                border = { left = { Px = 1 }, right = { Px = 1 } },
            },
            BackgroundColor = { color = Colors.bg },
            BorderColor = {
                left = Colors.border,
                right = Colors.border,
            },
        }):with_parent(parent_id)

        print("[GIT/SCOPE/SELECTOR] Loaded panel: " .. panel:id())
        print(world:get_entity(parent_id))

        ui.owner_entity = entity:id()
        ui.panel_entity = panel:id()

        -- Header
        local header = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 36 },
                flex_direction = "Row",
                flex_shrink = 0,
                align_items = "Center",
                justify_content = "SpaceBetween",
                padding = { left = { Px = 12 }, right = { Px = 8 } },
            },
            BackgroundColor = { color = Colors.header_bg },
        }):with_parent(ui.panel_entity)
        ui.header_container = header:id()

        spawn({
            Text = { text = "[GitHub]" },
            TextFont = { font_size = 14 },
            TextColor = { color = Colors.text },
        }):with_parent(header:id())

        -- Current scope indicator
        local scope_label = state.current_scope_key or ""
        if #scope_label > 18 then scope_label = "..." .. scope_label:sub(-15) end
        spawn({
            Text = { text = scope_label },
            TextFont = { font_size = 10 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(header:id())

        -- Scroll container
        local scroll = spawn({
            Node = {
                display = "Flex",
                width = { Percent = 100 },
                flex_grow = 1,
                flex_direction = "Column",
                align_items = "FlexStart",
                overflow = { x = "Visible", y = "Scroll" },
                padding = { top = { Px = 4 }, bottom = { Px = 4 }, left = { Px = 8 }, right = { Px = 8 } },
            },
            ScrollPosition = { offset = { x = 0, y = state.scroll_offset } },
        }):with_parent(ui.panel_entity)

        scroll:observe("Pointer<Scroll>", function(world, scroll_entity, event)
            local scroll_event = event.event
            state.scroll_offset = state.scroll_offset - scroll_event.y * 20
            if state.scroll_offset < 0 then state.scroll_offset = 0 end
            scroll_entity:patch({ ScrollPosition = { offset = { x = 0, y = state.scroll_offset } } })
        end)

        ui.scroll_container = scroll:id()

        -- Register HTTP allowlist
        if _G.register_http_allowed_urls then
            register_http_allowed_urls({
                "https://api.github.com",
                "https://github.com/login",
            })
        end

        -- Initial data
        state.current_scope_key = get_current_scope(world)
        -- No auto-select: user must choose a repo from the dropdown
        if auth.is_authenticated() and state.selected_repo and not state.remote_branches_loaded then
            refresh_branches()
        end
        update_ui_content(world)
    end
end)

--------------------------------------------------------------------------------
-- Update: HTTP responses, auth polling, reactivity
--------------------------------------------------------------------------------
register_system("Update", function(world)
    if not ui.panel_entity then return end

    local dt = world:delta_time()

    -- Process HTTP proxy responses
    local responses = world:read_events("hello::asset_events::AssetHttpProxyResponseEvent")
    for _, response in ipairs(responses) do
        auth.handle_response(response)
        api.handle_response(response)
    end

    -- Poll for token during device flow
    if auth.is_pending() then
        state.poll_timer = state.poll_timer + dt
        if state.poll_timer >= auth.get_poll_interval() then
            state.poll_timer = 0
            auth.poll_for_token()
        end
    end

    -- Track current scope
    local current = get_current_scope(world)
    if current ~= state.current_scope_key then
        state.current_scope_key = current
        ui.needs_render = true
    end

    -- On first auth, fetch branches
    if auth.is_authenticated() and not state.remote_branches_loaded then
        refresh_branches()
        if state.current_scope_key then
            local _, branch = Git.parse_scope(state.current_scope_key)
            refresh_commits(branch)
        end
    end

    -- Reactivity: detect state changes and re-render
    local auth_status = auth.is_authenticated() and "auth" or (auth.is_pending() and "pending" or "out")
    local needs_render = false

    if auth_status ~= ui.last_auth_status then needs_render = true end
    if state.current_scope_key ~= ui.last_scope_key then needs_render = true end
    if #state.remote_branches ~= ui.last_branch_count then needs_render = true end
    if #state.remote_commits ~= ui.last_commit_count then needs_render = true end
    if auth.get_user_code() ~= ui.last_user_code then needs_render = true end
    if state.selected_repo ~= ui.last_selected_repo then needs_render = true end
    if state.selected_branch ~= ui.last_selected_branch then needs_render = true end
    if state.repo_dropdown_open ~= ui.last_repo_dropdown then needs_render = true end
    if state.branch_dropdown_open ~= ui.last_branch_dropdown then needs_render = true end

    if needs_render or ui.needs_render then
        ui.needs_render = false
        ui.last_auth_status = auth_status
        ui.last_scope_key = state.current_scope_key
        ui.last_branch_count = #state.remote_branches
        ui.last_commit_count = #state.remote_commits
        ui.last_user_code = auth.get_user_code()
        ui.last_selected_repo = state.selected_repo
        ui.last_selected_branch = state.selected_branch
        ui.last_repo_dropdown = state.repo_dropdown_open
        ui.last_branch_dropdown = state.branch_dropdown_open
        update_ui_content(world)
    end

    -- Process pending switch request (from trigger_default_switch)
    if state.pending_switch_scope and ui.owner_entity then
        local entity = world:get_entity(ui.owner_entity)
        if entity then
            local scope_key = state.pending_switch_scope
            state.pending_switch_scope = nil
            print(string.format("[GIT/SCOPE/SELECTOR] Sending pending switch_scope: %s", scope_key))
            entity:patch({
                ["git/scope/selector"] = { switch_scope = scope_key }
            })
        end
    end

    -- Handle switch_port response from server (via server-auth response component)
    if ui.owner_entity then
        local entity = world:get_entity(ui.owner_entity)
        if entity then
            local resp = entity:get("git/scope/selector/response")
            if resp and resp.switch_port and resp.switch_port ~= state.last_handled_port then
                local port = resp.switch_port
                local scope_key = resp.switch_scope_key
                state.last_handled_port = port  -- dedup: don't spawn again for same port
                print(string.format("[GIT/SCOPE/SELECTOR] Server assigned port %d for scope '%s', launching client game",
                    port, tostring(scope_key)))

                -- Spawn game entity to trigger client launcher (main.lua watches for added "game")
                -- ScopeWorld="All" so root main.lua can see it from the root scope
                spawn({ game = { mode = "client", port = port, scope_key = scope_key }, ScopeWorld = "All" })
            end
        end
    end
end)
