-- modules/sidebar/file_browser/panel/init.lua
-- File browser panel mod: asset tree view with expand/collapse,
-- paginated loading, context menus, and file operations.
-- Redesigned from OLD_MODULES/file_browser/init.lua (~2474 lines → streamlined).
-- Uses Rust-side list_server_directory() for directory listing.

local Colors = require("modules/sidebar/shared/colors.lua")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local PANEL_WIDTH = 280
local ROW_HEIGHT = 26
local INDENT_SIZE = 16
local PAGE_SIZE = 50

--------------------------------------------------------------------------------
-- Persistent State
--------------------------------------------------------------------------------

local state = define_resource("FileBrowserState", {
    current_path = "",
    folders = {},           -- path → {expanded, loading, items, has_more, offset}
    selected_paths = {},    -- path → true
    scroll_offset = 0,
    context_menu_handled = false,
})

-- Initialize root folder
if not state.folders[""] then
    state.folders[""] = {
        expanded = true,
        loading = false,
        items = {},
        has_more = true,
        offset = 0,
    }
end

--------------------------------------------------------------------------------
-- Transient UI State
--------------------------------------------------------------------------------

local ui = {
    panel_entity = nil,
    scroll_container = nil,
    row_entities = {},
    needs_render = false,
    context_menu_entity = nil,
    context_menu_backdrop = nil,
}

--------------------------------------------------------------------------------
-- Forward Declarations
--------------------------------------------------------------------------------

local render_tree, render_folder, render_row, render_load_more
local load_folder, toggle_folder, on_row_click, on_directory_listing
local show_context_menu, close_context_menu, add_context_menu_item
local refresh, format_size

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

format_size = function(bytes)
    if bytes < 1024 then return bytes .. " B"
    elseif bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024)
    else return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

refresh = function()
    for path, folder in pairs(state.folders) do
        if folder.expanded or path == "" then
            folder.items = {}
            folder.has_more = true
            load_folder(path, 0)
        end
    end
end

--------------------------------------------------------------------------------
-- Folder Loading
--------------------------------------------------------------------------------

load_folder = function(path, offset)
    offset = offset or 0

    if not state.folders[path] then
        state.folders[path] = {
            expanded = (path == ""),
            loading = false,
            items = {},
            has_more = true,
            offset = 0,
        }
    end

    local folder = state.folders[path]
    if folder.loading then return end

    folder.loading = true
    folder.offset = offset

    local request_id = list_server_directory(path, offset, PAGE_SIZE)
    folder.request_id = request_id
end

on_directory_listing = function(event)
    local folder = state.folders[event.path]
    if not folder then return end

    folder.loading = false

    if event.error and event.error.Some then
        print("[FileBrowser] Directory listing error: " .. tostring(event.error.Some))
        return
    end

    if event.offset == 0 then
        folder.items = {}
    end

    for _, file in ipairs(event.files) do
        table.insert(folder.items, file)
    end

    folder.has_more = event.has_more
    folder.total_count = event.total_count

    ui.needs_render = true
end

--------------------------------------------------------------------------------
-- Tree Navigation
--------------------------------------------------------------------------------

toggle_folder = function(path)
    local folder = state.folders[path]
    if not folder then
        load_folder(path)
        state.folders[path].expanded = true
    else
        folder.expanded = not folder.expanded
        if folder.expanded and #folder.items == 0 then
            load_folder(path)
        end
    end
    ui.needs_render = true
end

on_row_click = function(item, ctrl_held)
    if ctrl_held then
        if state.selected_paths[item.path] then
            state.selected_paths[item.path] = nil
        else
            state.selected_paths[item.path] = true
        end
        ui.needs_render = true
    else
        state.selected_paths = {}
        state.selected_paths[item.path] = true
        if item.is_directory then
            toggle_folder(item.path)
        else
            ui.needs_render = true
        end
    end
end

--------------------------------------------------------------------------------
-- Context Menu
--------------------------------------------------------------------------------

close_context_menu = function()
    if ui.context_menu_entity then
        pcall(despawn, ui.context_menu_entity)
        ui.context_menu_entity = nil
    end
    if ui.context_menu_backdrop then
        pcall(despawn, ui.context_menu_backdrop)
        ui.context_menu_backdrop = nil
    end
end

add_context_menu_item = function(parent_id, label, callback)
    local item = spawn({
        Button = {},
        Node = {
            width = { Percent = 100 },
            height = { Px = 28 },
            align_items = "Center",
            padding = { left = { Px = 12 }, right = { Px = 12 } },
        },
        BackgroundColor = { color = Colors.transparent },
    }):with_parent(parent_id)

    spawn({
        Text = { text = label },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.text },
    }):with_parent(item:id())

    item:observe("Pointer<Over>", function(world, e)
        e:set({ BackgroundColor = { color = Colors.context_hover } })
    end)
    item:observe("Pointer<Out>", function(world, e)
        e:set({ BackgroundColor = { color = Colors.transparent } })
    end)
    item:observe("Pointer<Click>", function()
        close_context_menu()
        if callback then callback() end
    end)
end

show_context_menu = function(item, x, y)
    close_context_menu()

    -- Backdrop
    local backdrop = spawn({
        Button = {},
        Node = {
            position_type = "Absolute",
            left = { Px = 0 }, right = { Px = 0 },
            top = { Px = 0 }, bottom = { Px = 0 },
        },
        BackgroundColor = { color = { r = 0, g = 0, b = 0, a = 0.01 } },
        GlobalZIndex = { value = 499 },
    })
    backdrop:observe("Pointer<Click>", function()
        close_context_menu()
    end)
    ui.context_menu_backdrop = backdrop:id()

    -- Menu container
    local menu = spawn({
        Button = {},
        Node = {
            position_type = "Absolute",
            left = { Px = x },
            top = { Px = y },
            width = { Px = 160 },
            flex_direction = "Column",
            padding = { top = { Px = 4 }, bottom = { Px = 4 } },
        },
        BackgroundColor = { color = Colors.context_bg },
        BorderRadius = {
            top_left = { Px = 6 }, top_right = { Px = 6 },
            bottom_left = { Px = 6 }, bottom_right = { Px = 6 },
        },
        GlobalZIndex = { value = 500 },
    })
    ui.context_menu_entity = menu:id()

    -- Context-specific items
    if item.is_directory then
        add_context_menu_item(menu:id(), "New File", function()
            -- TODO: new file dialog
            print("[FileBrowser] New file in: " .. item.path)
        end)
        add_context_menu_item(menu:id(), "New Folder", function()
            -- TODO: new folder dialog
            print("[FileBrowser] New folder in: " .. item.path)
        end)
    end

    if item.path ~= "" then
        add_context_menu_item(menu:id(), "Rename", function()
            -- TODO: rename dialog
            print("[FileBrowser] Rename: " .. item.path)
        end)
        add_context_menu_item(menu:id(), "Delete", function()
            -- TODO: delete confirmation
            print("[FileBrowser] Delete: " .. item.path)
        end)
    end

    add_context_menu_item(menu:id(), "Refresh", function()
        refresh()
    end)
end

--------------------------------------------------------------------------------
-- Tree Rendering
--------------------------------------------------------------------------------

render_row = function(item, depth)
    local indent = depth * INDENT_SIZE + 8
    local is_selected = state.selected_paths[item.path] ~= nil

    local row = spawn({
        Button = {},
        Node = {
            display = "Flex",
            width = { Percent = 100 },
            height = { Px = ROW_HEIGHT },
            flex_direction = "Row",
            align_items = "Center",
            padding = { left = { Px = indent }, right = { Px = 8 } },
        },
        BackgroundColor = { color = is_selected and Colors.row_selected or Colors.transparent },
    }):with_parent(ui.scroll_container)

    row:observe("Pointer<Click>", function(world, entity, event)
        local click = event.event
        local is_right_click = click and click.button and click.button.variant == "Secondary"

        if is_right_click then
            if not state.selected_paths[item.path] then
                state.selected_paths = {}
                state.selected_paths[item.path] = true
            end
            local x = (event.pointer_location and event.pointer_location.position and event.pointer_location.position.x) or 100
            local y = (event.pointer_location and event.pointer_location.position and event.pointer_location.position.y) or 100
            state.context_menu_handled = true
            show_context_menu(item, x, y)
        else
            on_row_click(item, false)
        end
    end)

    row:observe("Pointer<Over>", function(world, entity)
        if not state.selected_paths[item.path] then
            entity:patch({ BackgroundColor = { color = Colors.row_hover } })
        end
    end)
    row:observe("Pointer<Out>", function(world, entity)
        if not state.selected_paths[item.path] then
            entity:patch({ BackgroundColor = { color = Colors.transparent } })
        end
    end)

    local row_id = row:id()
    table.insert(ui.row_entities, row_id)

    -- Expand arrow for directories
    if item.is_directory then
        local folder = state.folders[item.path]
        local is_expanded = folder and folder.expanded

        local arrow = spawn({
            Button = {},
            Node = {
                width = { Px = 16 },
                height = { Px = 16 },
                justify_content = "Center",
                align_items = "Center",
                margin = { right = { Px = 4 } },
            },
        }):with_parent(row_id)

        arrow:observe("Pointer<Click>", function()
            toggle_folder(item.path)
        end)

        spawn({
            Text = { text = is_expanded and "v" or ">" },
            TextFont = { font_size = 10 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(arrow:id())
    else
        spawn({
            Node = { width = { Px = 20 }, height = { Px = 1 } },
        }):with_parent(row_id)
    end

    -- Icon
    spawn({
        Text = { text = item.is_directory and "+" or "-" },
        TextFont = { font_size = 14 },
        TextColor = { color = item.is_directory and Colors.folder or Colors.file },
        Node = { margin = { right = { Px = 6 } } },
    }):with_parent(row_id)

    -- Name (with overflow clipping)
    local name_container = spawn({
        Node = {
            flex_grow = 1,
            flex_shrink = 1,
            min_width = { Px = 0 },
            overflow = { x = "Clip", y = "Visible" },
            margin = { right = { Px = 8 } },
        },
    }):with_parent(row_id)

    spawn({
        Text = { text = item.name },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.text },
    }):with_parent(name_container:id())

    -- File size
    if not item.is_directory and item.size and item.size > 0 then
        spawn({
            Text = { text = format_size(item.size) },
            TextFont = { font_size = 11 },
            TextColor = { color = Colors.text_dim },
            Node = { flex_shrink = 0 },
        }):with_parent(row_id)
    end
end

render_load_more = function(path, depth)
    local indent = depth * INDENT_SIZE + 28

    local btn = spawn({
        Button = {},
        Node = {
            display = "Flex",
            width = { Percent = 100 },
            height = { Px = ROW_HEIGHT },
            flex_direction = "Row",
            align_items = "Center",
            justify_content = "Center",
            padding = { left = { Px = indent } },
        },
    }):with_parent(ui.scroll_container)

    btn:observe("Pointer<Click>", function()
        local folder = state.folders[path]
        if folder then
            load_folder(path, folder.offset + PAGE_SIZE)
        end
    end)

    spawn({
        Text = { text = "Load more..." },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.accent },
    }):with_parent(btn:id())

    table.insert(ui.row_entities, btn:id())
end

render_folder = function(path, depth)
    local folder = state.folders[path]
    if not folder then return end

    for _, item in ipairs(folder.items or {}) do
        render_row(item, depth)

        if item.is_directory then
            local child_folder = state.folders[item.path]
            if child_folder and child_folder.expanded then
                render_folder(item.path, depth + 1)
            end
        end
    end

    if folder.has_more and not folder.loading then
        render_load_more(path, depth)
    end
end

render_tree = function()
    if not ui.scroll_container then return end

    for _, entity_id in ipairs(ui.row_entities or {}) do
        despawn(entity_id)
    end
    ui.row_entities = {}

    render_folder("", 0)
end

--------------------------------------------------------------------------------
-- Bootstrap: patch the mod entity into the panel UI root.
--------------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "sidebar/file_browser/panel" } })
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

        -- Header
        local header = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = 36 },
                flex_direction = "Row",
                align_items = "Center",
                justify_content = "SpaceBetween",
                padding = { left = { Px = 12 }, right = { Px = 8 } },
            },
            BackgroundColor = { color = Colors.header_bg },
        }):with_parent(ui.panel_entity)

        spawn({
            Text = { text = "[Assets]" },
            TextFont = { font_size = 14 },
            TextColor = { color = Colors.text },
        }):with_parent(header:id())

        -- Refresh button
        local refresh_btn = spawn({
            Button = {},
            Node = {
                width = { Px = 26 },
                height = { Px = 26 },
                justify_content = "Center",
                align_items = "Center",
            },
            BackgroundColor = { color = { r = 0.2, g = 0.2, b = 0.22, a = 1.0 } },
            BorderRadius = {
                top_left = { Px = 4 }, top_right = { Px = 4 },
                bottom_left = { Px = 4 }, bottom_right = { Px = 4 },
            },
        }):with_parent(header:id())

        refresh_btn:observe("Pointer<Click>", function()
            refresh()
        end)

        spawn({
            Text = { text = "R" },
            TextFont = { font_size = 14 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(refresh_btn:id())

        -- Scroll container
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

        scroll:observe("Pointer<Scroll>", function(world, scroll_entity, event)
            local scroll_event = event.event
            state.scroll_offset = state.scroll_offset - scroll_event.y * 20
            if state.scroll_offset < 0 then state.scroll_offset = 0 end
            scroll_entity:patch({ ScrollPosition = { offset = { x = 0, y = state.scroll_offset } } })
        end)

        scroll:observe("Pointer<Click>", function(world, scroll_entity, event)
            if state.context_menu_handled then
                state.context_menu_handled = false
                return
            end
            local click = event.event
            local is_right_click = click and click.button and click.button.variant == "Secondary"
            if is_right_click then
                local x = (event.pointer_location and event.pointer_location.position and event.pointer_location.position.x) or 100
                local y = (event.pointer_location and event.pointer_location.position and event.pointer_location.position.y) or 100
                show_context_menu({ name = "", path = "", is_directory = true }, x, y)
            end
        end)

        ui.scroll_container = scroll:id()

        load_folder("", 0)
        render_tree()
    end
end)

--------------------------------------------------------------------------------
-- Update: handle directory listing events and re-render
--------------------------------------------------------------------------------
register_system("Update", function(world)
    if not ui.panel_entity then return end

    -- Check for directory listing events
    local events = world:query({ added = { "DirectoryListingEvent" } })
    for _, entity in ipairs(events) do
        local event = entity:get("DirectoryListingEvent")
        if event then
            on_directory_listing(event)
        end
    end

    -- Re-render tree when needed
    if ui.needs_render then
        ui.needs_render = false
        render_tree()
    end
end)
