-- modules/git/scope/workflow/init.lua
-- Git workflow sidebar panel: branch creation, commit, push, pull, PR creation.
--
-- Integrates with git/scope to operate on the player's active scope.
-- Provides in-game git operations without leaving the game.

local Colors = require("modules/sidebar/shared/colors.lua")
local Git = require("modules/git/shared/git.lua")
local auth = require("modules/git/shared/auth.lua")
local api = require("modules/git/shared/api.lua")
local config = require("modules/git/scope/shared/config.lua")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local PANEL_WIDTH = 320
local ROW_HEIGHT = 22

local WORKFLOW_COLORS = {
    added    = { r = 0.4, g = 0.9, b = 0.4, a = 1.0 },  -- green
    modified = { r = 0.9, g = 0.7, b = 0.3, a = 1.0 },  -- amber
    deleted  = { r = 0.9, g = 0.4, b = 0.4, a = 1.0 },  -- red
    commit   = { r = 0.5, g = 0.7, b = 1.0, a = 1.0 },  -- blue
    success  = { r = 0.3, g = 0.8, b = 0.5, a = 1.0 },
    error    = { r = 1.0, g = 0.4, b = 0.4, a = 1.0 },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local state = define_resource("GitWorkflowState", {
    -- Current scope info
    current_scope_key = nil,
    current_worktree = nil,
    current_repo = nil,
    current_branch = nil,
    -- Git data (refreshed periodically)
    status_lines = {},
    recent_log = {},
    last_refresh = 0,
    -- UI state
    scroll_offset = 0,
    update_counter = 0,
    -- Feedback messages
    feedback = nil,      -- { text, color, expire_time }
})

local ui = {
    panel_entity = nil,
    header_container = nil,
    scroll_container = nil,
    content_entities = {},
    needs_render = false,
}

local REFRESH_INTERVAL = 5  -- seconds between auto-refreshes

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Get the local player's current scope and resolve worktree info.
--- @param world userdata ECS world
local function refresh_scope_context(world)
    local players = world:query({ with = { "net_local", "git/scope" } })
    if #players > 0 then
        local gs = players[1]:get("git/scope")
        if gs and gs.scope_key then
            state.current_scope_key = gs.scope_key
            local repo, branch = Git.parse_scope(gs.scope_key)
            state.current_repo = repo
            state.current_branch = branch
            state.current_worktree = config.get_worktree_path(gs.scope_key)
            return
        end
    end
    state.current_scope_key = nil
    state.current_repo = nil
    state.current_branch = nil
    state.current_worktree = nil
end

--- Refresh git status and log for the current worktree.
local function refresh_git_data()
    if not state.current_worktree then
        state.status_lines = {}
        state.recent_log = {}
        return
    end

    -- Parse git status --short
    local ok, status_output = Git.status(state.current_worktree)
    local lines = {}
    if ok and status_output then
        for line in status_output:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and #trimmed > 0 then
                local status_code = trimmed:sub(1, 2):match("^%s*(.-)%s*$")
                local file_path = trimmed:sub(4)
                lines[#lines + 1] = {
                    code = status_code,
                    path = file_path,
                }
            end
        end
    end
    state.status_lines = lines

    -- Get recent commits
    state.recent_log = Git.log(state.current_worktree, 8)
    state.last_refresh = os.clock()
end

--- Show feedback message.
local function show_feedback(text, color, duration)
    state.feedback = {
        text = text,
        color = color or Colors.text,
        expire_time = os.clock() + (duration or 5),
    }
    ui.needs_render = true
end

--- Get status color for a git status code.
local function status_color(code)
    if code == "A" or code == "?" then return WORKFLOW_COLORS.added end
    if code == "M" then return WORKFLOW_COLORS.modified end
    if code == "D" then return WORKFLOW_COLORS.deleted end
    return Colors.text_dim
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function do_commit(world)
    if not state.current_worktree or not state.current_branch then
        show_feedback("No active scope", WORKFLOW_COLORS.error)
        return
    end
    if #state.status_lines == 0 then
        show_feedback("Nothing to commit", Colors.text_dim)
        return
    end
    local message = string.format("In-game commit (%s)", os.date("%H:%M:%S"))
    local ok, output = Git.commit(state.current_worktree, message)
    if ok then
        show_feedback("✓ Committed: " .. message, WORKFLOW_COLORS.success)
        refresh_git_data()
    else
        show_feedback("✗ Commit failed: " .. (output or ""):sub(1, 60), WORKFLOW_COLORS.error)
    end
end

local function do_push()
    if not state.current_worktree or not state.current_branch then
        show_feedback("No active scope", WORKFLOW_COLORS.error)
        return
    end
    local ok, output = Git.push(state.current_worktree, state.current_branch)
    if ok then
        show_feedback("✓ Pushed to origin/" .. state.current_branch, WORKFLOW_COLORS.success)
    else
        show_feedback("✗ Push failed: " .. (output or ""):sub(1, 60), WORKFLOW_COLORS.error)
    end
end

local function do_pull()
    if not state.current_worktree or not state.current_branch then
        show_feedback("No active scope", WORKFLOW_COLORS.error)
        return
    end
    local ok, output = Git.pull(state.current_worktree, state.current_branch)
    if ok then
        show_feedback("✓ Pulled from origin/" .. state.current_branch, WORKFLOW_COLORS.success)
        refresh_git_data()
    else
        show_feedback("✗ Pull failed: " .. (output or ""):sub(1, 60), WORKFLOW_COLORS.error)
    end
end

local function do_create_pr()
    if not auth.is_authenticated() then
        show_feedback("Sign in via Branches panel first", WORKFLOW_COLORS.error)
        return
    end
    if not state.current_repo or not state.current_branch then
        show_feedback("No active scope", WORKFLOW_COLORS.error)
        return
    end
    local base_branch = config.get_base_branch(state.current_repo)
    if state.current_branch == base_branch then
        show_feedback("Already on base branch", Colors.text_dim)
        return
    end
    local owner = config.get_owner(state.current_repo)
    if not owner then
        show_feedback("No owner configured", WORKFLOW_COLORS.error)
        return
    end
    local title = string.format("[In-Game] %s", state.current_branch)
    api.create_pull_request(auth, owner, state.current_repo, title, state.current_branch, base_branch, function(data, err)
        if err then
            show_feedback("✗ PR failed: " .. tostring(err):sub(1, 50), WORKFLOW_COLORS.error)
        else
            local pr_number = data and data.number or "?"
            show_feedback(string.format("✓ PR #%s created", pr_number), WORKFLOW_COLORS.success)
        end
    end)
    show_feedback("Creating PR...", Colors.text_dim, 10)
end

local function do_create_branch(world)
    -- Read branch name from LuaTextInputValue
    local name = nil
    local input_entities = world:query({ with = { "LuaTextInputValue" } })
    for _, e in ipairs(input_entities) do
        local value = e:get("LuaTextInputValue")
        if value and value.text and #value.text > 0 then
            name = value.text
            break
        end
    end

    if not name or #name == 0 then
        show_feedback("Enter a branch name", Colors.text_dim)
        return
    end
    if not state.current_repo then
        show_feedback("No active scope", WORKFLOW_COLORS.error)
        return
    end
    -- Sanitize branch name
    name = name:gsub("[^%w%-%_%.%/]", "-")
    local repo_root = config.get_repo_path(state.current_repo)
    if not repo_root then
        show_feedback("Unknown repo: " .. state.current_repo, WORKFLOW_COLORS.error)
        return
    end
    local base = config.get_base_branch(state.current_repo)
    local ok, output = Git.create_branch(repo_root, name, base)
    if ok then
        show_feedback("✓ Created branch: " .. name, WORKFLOW_COLORS.success)
        -- Switch to the new branch
        local new_scope_key = Git.scope_key(state.current_repo, name)
        world:write_event("scope:switch", { scope_key = new_scope_key })
        ui.needs_render = true  -- re-render to clear the input
    else
        show_feedback("✗ Branch creation failed: " .. (output or ""):sub(1, 60), WORKFLOW_COLORS.error)
    end
end

--------------------------------------------------------------------------------
-- UI Rendering
--------------------------------------------------------------------------------

local function render_action_button(parent_id, label, color, callback)
    local btn = spawn({
        Node = {
            height = { Px = 28 },
            padding = { left = { Px = 10 }, right = { Px = 10 }, top = { Px = 4 }, bottom = { Px = 4 } },
            align_items = "Center",
            justify_content = "Center",
            border = { left = { Px = 1 }, right = { Px = 1 }, top = { Px = 1 }, bottom = { Px = 1 } },
        },
        BackgroundColor = { color = Colors.row_bg },
        BorderColor = {
            left = color,
            right = color,
            top = color,
            bottom = color,
        },
    }):with_parent(parent_id)

    spawn({
        Text = { text = label },
        TextFont = { font_size = 11 },
        TextColor = { color = color },
    }):with_parent(btn:id())

    btn:observe("Pointer<Click>", function(world)
        callback(world)
    end)
    btn:observe("Pointer<Over>", function(_, e)
        e:patch({ BackgroundColor = { color = Colors.row_hover } })
    end)
    btn:observe("Pointer<Out>", function(_, e)
        e:patch({ BackgroundColor = { color = Colors.row_bg } })
    end)

    return btn
end

local function update_ui_content(world)
    if not ui.panel_entity then return end

    -- Clear old content
    for _, entity_id in ipairs(ui.content_entities or {}) do
        despawn(entity_id)
    end
    ui.content_entities = {}

    -- Header
    local header = spawn({
        Node = {
            width = { Percent = 100 },
            height = { Percent = 100 },
            flex_direction = "Row",
            align_items = "Center",
            justify_content = "SpaceBetween",
            padding = { left = { Px = 12 }, right = { Px = 8 } },
        },
        BackgroundColor = { color = Colors.header_bg },
    }):with_parent(ui.header_container)
    table.insert(ui.content_entities, header:id())

    spawn({
        Text = { text = "⚙ Git" },
        TextFont = { font_size = 14 },
        TextColor = { color = Colors.text },
    }):with_parent(header:id())

    -- Branch indicator
    local branch_label = state.current_branch or "none"
    spawn({
        Text = { text = "⎇ " .. branch_label },
        TextFont = { font_size = 11 },
        TextColor = { color = state.current_branch and WORKFLOW_COLORS.commit or Colors.text_dim },
    }):with_parent(header:id())

    -- No scope warning
    if not state.current_scope_key then
        local warning = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 40 },
                align_items = "Center",
                justify_content = "Center",
                padding = { left = { Px = 12 } },
            },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, warning:id())
        spawn({
            Text = { text = "No active scope — select a branch first" },
            TextFont = { font_size = 11 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(warning:id())
        return
    end

    -- Feedback message
    if state.feedback and os.clock() < state.feedback.expire_time then
        local fb = spawn({
            Node = {
                width = { Percent = 100 },
                padding = { left = { Px = 8 }, right = { Px = 8 }, top = { Px = 4 }, bottom = { Px = 4 } },
            },
            BackgroundColor = { color = { r = 0.15, g = 0.15, b = 0.18, a = 1.0 } },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, fb:id())
        spawn({
            Text = { text = state.feedback.text },
            TextFont = { font_size = 10 },
            TextColor = { color = state.feedback.color },
        }):with_parent(fb:id())
    end

    -- Action buttons row
    local actions = spawn({
        Node = {
            width = { Percent = 100 },
            flex_direction = "Row",
            column_gap = { Px = 4 },
            padding = { left = { Px = 8 }, right = { Px = 8 }, top = { Px = 6 }, bottom = { Px = 6 } },
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, actions:id())

    render_action_button(actions:id(), "Commit", WORKFLOW_COLORS.success, do_commit)
    render_action_button(actions:id(), "Push ↑", WORKFLOW_COLORS.commit, do_push)
    render_action_button(actions:id(), "Pull ↓", WORKFLOW_COLORS.modified, do_pull)
    if auth.is_authenticated() then
        render_action_button(actions:id(), "PR", Colors.accent, do_create_pr)
    end

    -- Section: Working Changes
    local changes_header = spawn({
        Node = {
            width = { Percent = 100 },
            flex_direction = "Row",
            justify_content = "SpaceBetween",
            align_items = "Center",
            padding = { left = { Px = 8 }, right = { Px = 8 } },
            margin = { top = { Px = 6 }, bottom = { Px = 2 } },
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, changes_header:id())

    spawn({
        Text = { text = "Changes" },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(changes_header:id())

    spawn({
        Text = { text = string.format("%d files", #state.status_lines) },
        TextFont = { font_size = 10 },
        TextColor = { color = #state.status_lines > 0 and WORKFLOW_COLORS.modified or Colors.text_dim },
    }):with_parent(changes_header:id())

    if #state.status_lines == 0 then
        local clean = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = ROW_HEIGHT },
                align_items = "Center",
                padding = { left = { Px = 12 } },
            },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, clean:id())
        spawn({
            Text = { text = "✓ Working tree clean" },
            TextFont = { font_size = 10 },
            TextColor = { color = WORKFLOW_COLORS.success },
        }):with_parent(clean:id())
    else
        for i, entry in ipairs(state.status_lines) do
            if i > 20 then
                local more = spawn({
                    Node = {
                        width = { Percent = 100 },
                        height = { Px = ROW_HEIGHT },
                        align_items = "Center",
                        padding = { left = { Px = 12 } },
                    },
                }):with_parent(ui.scroll_container)
                table.insert(ui.content_entities, more:id())
                spawn({
                    Text = { text = string.format("... and %d more", #state.status_lines - 20) },
                    TextFont = { font_size = 10 },
                    TextColor = { color = Colors.text_dim },
                }):with_parent(more:id())
                break
            end

            local display_path = entry.path
            if #display_path > 30 then
                display_path = "..." .. display_path:sub(-27)
            end

            local row = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = ROW_HEIGHT },
                    flex_direction = "Row",
                    align_items = "Center",
                    column_gap = { Px = 6 },
                    padding = { left = { Px = 8 }, right = { Px = 8 } },
                },
                BackgroundColor = { color = (i % 2 == 0) and Colors.row_alt or Colors.row_bg },
            }):with_parent(ui.scroll_container)
            table.insert(ui.content_entities, row:id())

            spawn({
                Text = { text = entry.code },
                TextFont = { font_size = 10 },
                TextColor = { color = status_color(entry.code) },
            }):with_parent(row:id())

            spawn({
                Text = { text = display_path },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text },
            }):with_parent(row:id())
        end
    end

    -- Section: Recent Commits
    if #state.recent_log > 0 then
        local log_header = spawn({
            Node = {
                width = { Percent = 100 },
                padding = { left = { Px = 8 } },
                margin = { top = { Px = 8 }, bottom = { Px = 2 } },
            },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, log_header:id())

        spawn({
            Text = { text = "Recent Commits" },
            TextFont = { font_size = 12 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(log_header:id())

        for i, entry in ipairs(state.recent_log) do
            local display_msg = entry.message
            if #display_msg > 35 then
                display_msg = display_msg:sub(1, 32) .. "..."
            end

            local row = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = ROW_HEIGHT },
                    flex_direction = "Row",
                    align_items = "Center",
                    column_gap = { Px = 6 },
                    padding = { left = { Px = 8 }, right = { Px = 8 } },
                },
                BackgroundColor = { color = (i % 2 == 0) and Colors.row_alt or Colors.row_bg },
            }):with_parent(ui.scroll_container)
            table.insert(ui.content_entities, row:id())

            spawn({
                Text = { text = entry.hash:sub(1, 7) },
                TextFont = { font_size = 9 },
                TextColor = { color = WORKFLOW_COLORS.commit },
            }):with_parent(row:id())

            spawn({
                Text = { text = display_msg },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text },
            }):with_parent(row:id())
        end
    end

    -- Section: Create Branch
    local create_header = spawn({
        Node = {
            width = { Percent = 100 },
            padding = { left = { Px = 8 } },
            margin = { top = { Px = 8 }, bottom = { Px = 4 } },
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, create_header:id())

    spawn({
        Text = { text = "New Branch" },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(create_header:id())

    local create_row = spawn({
        Node = {
            width = { Percent = 100 },
            flex_direction = "Row",
            column_gap = { Px = 4 },
            padding = { left = { Px = 8 }, right = { Px = 8 } },
            align_items = "Center",
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, create_row:id())

    -- Branch name text input
    local input_entity = spawn({
        LuaTextInput = {
            initial_value = "",
            auto_focus = false,
        },
        Node = {
            flex_grow = 1,
            height = { Px = 26 },
            padding = { left = { Px = 6 }, right = { Px = 6 } },
            align_items = "Center",
        },
        BackgroundColor = { color = Colors.row_bg },
        BorderRadius = {
            top_left = { Px = 3 }, top_right = { Px = 3 },
            bottom_left = { Px = 3 }, bottom_right = { Px = 3 },
        },
        TextColor = { color = Colors.text },
        TextFont = { font_size = 11 },
    }):with_parent(create_row:id())
    table.insert(ui.content_entities, input_entity:id())

    render_action_button(create_row:id(), "Create", WORKFLOW_COLORS.success, do_create_branch)
end

--------------------------------------------------------------------------------
-- Bootstrap: patch the mod entity into the panel UI root.
--------------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "git/scope/workflow" } })
    for _, entity in ipairs(entities) do
        entity:patch({
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
        })

        ui.panel_entity = entity:id()

        -- Fixed header container
        local header_container = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 36 },
                flex_direction = "Row",
                flex_shrink = 0,
            },
        }):with_parent(ui.panel_entity)
        ui.header_container = header_container:id()

        -- Scrollable content
        local scroll = spawn({
            Node = {
                display = "Flex",
                width = { Percent = 100 },
                flex_grow = 1,
                flex_direction = "Column",
                align_items = "FlexStart",
                overflow = { x = "Visible", y = "Scroll" },
                padding = { top = { Px = 4 }, bottom = { Px = 4 } },
            },
            ScrollPosition = { offset = { x = 0, y = state.scroll_offset } },
        }):with_parent(ui.panel_entity)

        scroll:observe("Pointer<Scroll>", function(scroll_entity, event)
            local scroll_event = event.event
            state.scroll_offset = state.scroll_offset - scroll_event.y * 20
            if state.scroll_offset < 0 then state.scroll_offset = 0 end
            scroll_entity:patch({ ScrollPosition = { offset = { x = 0, y = state.scroll_offset } } })
        end)

        ui.scroll_container = scroll:id()

        -- Initial data load
        refresh_scope_context(world)
        refresh_git_data()
        update_ui_content(world)
    end
end)

--------------------------------------------------------------------------------
-- Update system: periodic refresh
--------------------------------------------------------------------------------
register_system("Update", function(world)
    if not ui.panel_entity then return end

    state.update_counter = (state.update_counter or 0) + 1

    -- Process HTTP proxy responses (for PR creation callbacks)
    local responses = world:query({ added = { "HttpProxyClientResponse" } })
    for _, entity in ipairs(responses) do
        local response = entity:get("HttpProxyClientResponse")
        if response then
            api.handle_response(response)
        end
    end

    -- Refresh scope context
    refresh_scope_context(world)

    -- Auto-refresh git data
    local now = os.clock()
    if (now - state.last_refresh) >= REFRESH_INTERVAL then
        refresh_git_data()
        ui.needs_render = true
    end

    -- Clear expired feedback
    if state.feedback and os.clock() >= state.feedback.expire_time then
        state.feedback = nil
        ui.needs_render = true
    end

    -- Periodic UI refresh or on demand
    if state.update_counter % 60 == 0 or ui.needs_render then
        ui.needs_render = false
        update_ui_content(world)
    end
end)

--------------------------------------------------------------------------------
-- Event handler: create branch from event
--------------------------------------------------------------------------------
register_system("First", function(world)
    local events = world:read_events("git/scope:create_branch")
    for _, event in ipairs(events) do
        if event.name and #event.name > 0 then
            -- Direct branch creation from event (bypasses text input)
            local name = event.name:gsub("[^%w%-%_%.%/]", "-")
            if state.current_repo then
                local repo_root = config.get_repo_path(state.current_repo)
                local base = config.get_base_branch(state.current_repo)
                if repo_root then
                    local ok, output = Git.create_branch(repo_root, name, base)
                    if ok then
                        show_feedback("✓ Created branch: " .. name, WORKFLOW_COLORS.success)
                        local new_scope_key = Git.scope_key(state.current_repo, name)
                        world:write_event("scope:switch", { scope_key = new_scope_key })
                        ui.needs_render = true
                    else
                        show_feedback("✗ Failed: " .. (output or ""):sub(1, 50), WORKFLOW_COLORS.error)
                    end
                end
            end
        end
    end
end, { label = "GitWorkflowCreateBranch" })
