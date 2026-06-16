-- modules/sidebar/client/init.lua
-- Sidebar container mod: outer container, icon bar, panel area.
-- Button mods are children of the sidebar entity — sidebar discovers them via hierarchy.
-- Handles Escape key (open_menu action) for toggling sidebar + input_mode.

local Colors = require("modules/sidebar/shared/colors.lua")
local BINDINGS = require("modules/sidebar/shared/bindings.lua")

local json = require("modules/dkjson.lua")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local ICON_BAR_WIDTH = 48
local ICON_SIZE = 36
local ICON_GAP = 4
local PANEL_MIN_WIDTH = 280
local DEBOUNCE_TIME = 0.2

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = define_resource("SidebarState", {
    visible = false,
    container_id = nil,
    icon_bar_id = nil,
    sidebar_entity_id = nil,
    last_escape_time = 0,
    sidebars_by_id = {},  -- [eid] = { button_entity_ids = { [key] = eid }, last_buttons = { [key] = cfg } }
})

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function set_input_mode(world, mode)
    local entities = world:query({ with = { "input" } })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { input_mode = mode } })
    end
end

local function show_sidebar(world)
    if state.container_id then
        local container = world:get_entity(state.container_id)
        if container then
            container:patch({ Node = { display = "Flex" } })
        end
    end
    state.visible = true
    set_input_mode(world, "ui")
end

local function hide_sidebar(world)
    if state.container_id then
        local container = world:get_entity(state.container_id)
        if container then
            container:patch({ Node = { display = "None" } })
        end
    end
    state.visible = false
    set_input_mode(world, "game")
end

--- Find all button children and check which ones have open panels.
--- Returns a list of { button_entity_id, panel_entity_id, opened_at } sorted by opened_at.
local function get_open_panels(world)
    if not state.sidebar_entity_id then return {} end

    local panels = {}
    -- Query descendants of sidebar entity that have sidebar_button
    local buttons = world:query({
        with = { "sidebar/button" },
        entities = { state.sidebar_entity_id },
    })
    for _, btn in ipairs(buttons) do
        local btn_data = btn:get("sidebar/button")
        if btn_data and (btn_data.panel_entity_id or btn_data.panel_net_mod_open) then
            panels[#panels + 1] = {
                button_entity_id = btn:id(),
                panel_entity_id = btn_data.panel_entity_id,
                panel_net_mod_open = btn_data.panel_net_mod_open,
                opened_at = btn_data.opened_at or 0,
            }
        end
    end

    -- Sort by opened_at (most recent last)
    table.sort(panels, function(a, b) return a.opened_at < b.opened_at end)
    return panels
end

--- Close the most recently opened panel.
local function close_most_recent_panel(world)
    local panels = get_open_panels(world)
    if #panels == 0 then return false end

    local most_recent = panels[#panels]

    if most_recent.panel_entity_id then
        -- Client-only panel: despawn
        despawn(most_recent.panel_entity_id)
    end

    if most_recent.panel_net_mod_open then
        -- Net mod panel: tell server to unload
        local btn = world:get_entity(most_recent.button_entity_id)
        if btn then
            local cfg = btn:get("sidebar/button") or {}
            if cfg.panel_net_mod and state.sidebar_entity_id then
                local sidebar = world:get_entity(state.sidebar_entity_id)
                if sidebar then
                    sidebar:patch({ sidebar = {
                        close_panels = { [cfg.panel_net_mod] = true },
                    } })
                end
            end
        end
    end

    -- Clear button state
    local btn = world:get_entity(most_recent.button_entity_id)
    if btn then
        btn:patch({ ["sidebar/button"]= {
            panel_entity_id = null,
            panel_net_mod_open = null,
            opened_at = null,
        }})
    end

    return true
end

--------------------------------------------------------------------------------
-- Button reconciliation
--------------------------------------------------------------------------------

--- Sort button keys by `order` field ascending; ties fall back to alphabetical.
--- Missing `order` sorts last.
local function sorted_keys(buttons)
    local keys = {}
    for k in pairs(buttons) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local oa = (buttons[a] or {}).order or math.huge
        local ob = (buttons[b] or {}).order or math.huge
        if oa == ob then return tostring(a) < tostring(b) end
        return oa < ob
    end)
    return keys
end

--- Structural compare: returns true iff the two button dicts differ.
--- Used to skip `changed` events triggered by our own self-patches.
local function buttons_differ(a, b)
    return json.encode(a or {}) ~= json.encode(b or {})
end

--- Diff `last_buttons` vs current `buttons`; spawn/despawn/patch children as needed.
local function reconcile_buttons(world, entity)
    local eid = entity:id()
    local config = entity:get("sidebar") or {}
    local new_btns = config.buttons or {}
    local inst = state.sidebars_by_id[eid]
    if not inst then
        inst = { button_entity_ids = {}, last_buttons = {} }
        state.sidebars_by_id[eid] = inst
    end
    local ids = inst.button_entity_ids

    -- Despawn removed
    for key, btn_id in pairs(ids) do
        if new_btns[key] == nil then
            despawn(btn_id)
            ids[key] = nil
        end
    end

    -- Spawn new / update existing (sorted so initial spawn order matches `order`)
    for _, key in ipairs(sorted_keys(new_btns)) do
        local cfg = new_btns[key]
        local existing = ids[key]
        if existing then
            local btn = world:get_entity(existing)
            if btn then
                btn:patch({ ["sidebar/button"] = cfg })
            end
        else
            local btn = spawn({ mod = { ["sidebar/button"] = cfg } }):with_parent(eid)
            ids[key] = btn:id()
        end
    end

    inst.last_buttons = new_btns
end

--------------------------------------------------------------------------------
-- Init: spawn sidebar UI hierarchy + react to live config changes
--------------------------------------------------------------------------------
register_system("First", function(world)
    -- Initial setup on `added`
    local added = world:query({ added = { "sidebar" } })
    for _, entity in ipairs(added) do
        
        local last_container_id = state.container_id

        local eid = entity:id()
        state.sidebar_entity_id = eid

        -- Add sidebar keybinding to the existing input config.
        -- Input mod is already loaded on this entity via net_mod.
        entity:patch({ input = {
            sidebar = BINDINGS,
        }})

        -- Container: Node on the player entity itself.
        -- Use Display (not Visibility) to hide/show — Display only affects
        -- UI layout, so the 3D model stays visible when sidebar is hidden.
        entity:patch({
            Node = {
                position_type = "Absolute",
                left = { Px = 0 },
                top = { Px = 0 },
                bottom = { Px = 0 },
                flex_direction = "Row",
                align_items = "Stretch",
                padding = { left = { Px = ICON_BAR_WIDTH } },
                display = state.visible and "Flex" or "None",
            },
            BackgroundColor = { color = Colors.transparent },
            GlobalZIndex = { value = 100 },
        })

        -- Icon bar: pinned to the left edge via Absolute positioning so it
        -- can't be displaced by sibling order in the Children list.
        local icon_bar = spawn({
            Node = {
                position_type = "Absolute",
                left = { Px = 0 },
                top = { Px = 0 },
                bottom = { Px = 0 },
                width = { Px = ICON_BAR_WIDTH },
                flex_direction = "Column",
                align_items = "Center",
                padding = {
                    top = { Px = ICON_GAP },
                    bottom = { Px = ICON_GAP },
                    left = { Px = ICON_GAP },
                    right = { Px = ICON_GAP },
                },
                row_gap = { Px = ICON_GAP },
            },
            BackgroundColor = { color = Colors.icon_bar_bg },
        }):with_parent(eid)
        state.icon_bar_id = icon_bar:id()

        -- Button definitions — 100% client-side.
        -- Adding/removing buttons only requires editing this table.
        local buttons = {
            profiler = { icon_asset = "icons/profiler.png", title = "Profiler",
                         panel_mod = "sidebar/profiler/panel", order = 1 },
            files    = { icon_asset = "icons/files.png", title = "Files",
                         panel_mod = "sidebar/file_browser/panel", order = 2 },
            github   = { icon_asset = "icons/github.png", title = "GitHub",
                         panel_net_mod = "git/scope/selector", order = 3 },
        }

        -- Register panel_net_mods with the sidebar server for validation.
        local panel_mods = {}
        for _, btn in pairs(buttons) do
            if btn.panel_net_mod then
                panel_mods[btn.panel_net_mod] = true
            end
        end

        -- Store IDs in the sidebar component so child mods can read them.
        -- Also set the button config and register panel_net_mods with the server.
        entity:patch({ sidebar = {
            icon_bar_id = icon_bar:id(),
            container_id = eid,
            buttons = buttons,
            register_panels = panel_mods,
        }})

        state.sidebars_by_id[eid] = { button_entity_ids = {}, last_buttons = {} }
        reconcile_buttons(world, entity)

        state.container_id = eid
        print(string.format("[SIDEBAR] Initialized for entity %d", eid))
    end

    -- Live re-config on `changed`: only act if buttons actually changed
    local changed = world:query({ changed = { "sidebar" } })
    for _, entity in ipairs(changed) do
        local inst = state.sidebars_by_id[entity:id()]
        if inst then
            local new_btns = entity:get("sidebar").buttons or {}
            if buttons_differ(inst.last_buttons, new_btns) then
                reconcile_buttons(world, entity)
            end
        end

        -- Clear one-shot request fields from the CLIENT side.
        -- The sidebar component has client authority, so server patches don't
        -- replicate back. We clear these one frame after they're set, which
        -- gives net_sync time to send them to the server first.
        -- NOTE: register_panels is NOT cleared here — it's idempotent and
        -- needs time to reach the server during initial setup.
        local cfg = entity:get("sidebar") or {}
        if cfg.open_panels or cfg.close_panels then
            entity:patch({ sidebar = {
                open_panels = false,
                close_panels = false,
            } })
        end
    end
end)

--------------------------------------------------------------------------------
-- Escape handling: toggle sidebar / close panels
--------------------------------------------------------------------------------
register_system("Update", function(world)
    local input_entities = world:query({ changed = { "input_sidebar" } })
    for _, entity in ipairs(input_entities) do
        local sb_input = entity:get("input_sidebar")
        local menu_val = sb_input and sb_input.open_menu
        if menu_val then
            -- Debounce
            local now = os.clock()
            if (now - state.last_escape_time) < DEBOUNCE_TIME then return end
            state.last_escape_time = now

            local panels = get_open_panels(world)
            if #panels > 0 then
                close_most_recent_panel(world)
            elseif state.visible then
                hide_sidebar(world)
            else
                show_sidebar(world)
            end
            break
        end
    end
end, { label = "SidebarEscape", after = { "Input" } })
