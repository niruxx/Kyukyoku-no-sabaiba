-- modules/sidebar/profiler/panel/client/init.lua
-- Profiler panel mod: system timing, FPS, memory, table scanning.
-- The button parents this entity directly under the sidebar; this mod
-- patches the panel's visual components onto the entity itself.
-- Redesigned from OLD_MODULES/profiler/init.lua.

local Colors = require("modules/sidebar/shared/colors.lua")

--------------------------------------------------------------------------------
-- Persistent State (shared across instances via ref-counting)
--------------------------------------------------------------------------------

local state = define_resource("ProfilerState", {
    enabled = true,
    systems = {},
    queries = {},
    frame_times = {},
    frame_time_max = 120,
    current_fps = 0,
    lua_memory_kb = 0,
    scan_enabled = true,
    scan_interval_frames = 60,
    scan_frame_counter = 0,
    scan_max_depth = 5,
    scan_size_threshold = 50,
    scan_snapshots = {},
    scan_growth_alerts = {},
    scan_results = {},
    pending_scan_results = nil,
    scan_coroutine = nil,
    parallel_enabled = false,
    state_count = 0,
    scroll_offset = 0,
    systems_scroll_offset = 0,
    update_counter = 0,
    expanded_system = nil,
})

--------------------------------------------------------------------------------
-- Transient UI State (reset on hot-reload)
--------------------------------------------------------------------------------

local ui = {
    panel_entity = nil,
    header_container = nil,
    scroll_container = nil,
    content_entities = {},
    needs_render = false,
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local PANEL_WIDTH = 320
local ROW_HEIGHT = 20

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function format_ms(ms)
    if ms < 0.1 then return string.format("%.2fms", ms)
    elseif ms < 1 then return string.format("%.1fms", ms)
    else return string.format("%.0fms", ms) end
end

local function get_time_color(ms)
    if ms < 1 then return Colors.text_good
    elseif ms < 4 then return Colors.text
    elseif ms < 8 then return Colors.text_warn
    else return Colors.text_bad end
end

local function make_display_name(name)
    local without_schedule = name:match("^[^:]+:(.+)$") or name
    local display = without_schedule:match("[^/]+/[^/]+$") or without_schedule
    if #display > 22 then display = "..." .. display:sub(-19) end
    return display
end

local function count_table_entries(t, depth, max_depth, visited)
    if type(t) ~= "table" then return 0 end
    if depth > max_depth then return 0 end
    visited = visited or {}
    if visited[t] then return 0 end
    visited[t] = true
    local count = 0
    for _, v in pairs(t) do
        count = count + 1
        if type(v) == "table" then
            count = count + count_table_entries(v, depth + 1, max_depth, visited)
        end
    end
    return count
end

--------------------------------------------------------------------------------
-- Table Scanning
--------------------------------------------------------------------------------

local function start_global_scan()
    state.pending_scan_results = {}
    state.scan_coroutine = coroutine.create(function()
        local function scan_table(t, path, depth)
            if depth > state.scan_max_depth then return end
            if type(t) ~= "table" then return end
            local skip_keys = {
                _G = true, package = true, arg = true,
                ["_VERSION"] = true, collectgarbage = true,
            }
            for k, v in pairs(t) do
                if type(k) == "string" and not skip_keys[k] then
                    local entry_path = path == "" and k or (path .. "." .. k)
                    if type(v) == "table" then
                        local size = count_table_entries(v, 0, 3, {})
                        if size >= state.scan_size_threshold then
                            table.insert(state.pending_scan_results, {
                                path = entry_path,
                                size = size,
                            })
                        end
                        if depth < 2 then
                            scan_table(v, entry_path, depth + 1)
                            coroutine.yield()
                        end
                    end
                end
            end
        end
        scan_table(_G, "", 0)
        return true
    end)
end

local function resume_scan()
    if not state.scan_coroutine then return end
    local status = coroutine.status(state.scan_coroutine)
    if status == "dead" then
        state.scan_results = state.pending_scan_results or {}
        state.pending_scan_results = nil
        state.scan_growth_alerts = {}
        for _, result in ipairs(state.scan_results) do
            local prev = state.scan_snapshots[result.path]
            if prev then
                local growth = result.size - prev.size
                local growth_pct = prev.size > 0 and (growth / prev.size * 100) or 0
                if growth_pct > 20 or growth > 100 then
                    table.insert(state.scan_growth_alerts, {
                        path = result.path,
                        old_size = prev.size,
                        new_size = result.size,
                        growth = growth,
                        growth_percent = growth_pct,
                    })
                end
            end
            state.scan_snapshots[result.path] = {
                size = result.size,
                frame = state.scan_frame_counter,
            }
        end
        table.sort(state.scan_growth_alerts, function(a, b) return a.growth > b.growth end)
        state.scan_coroutine = nil
        return
    end
    for _ = 1, 10 do
        if coroutine.status(state.scan_coroutine) ~= "dead" then
            local ok, err = coroutine.resume(state.scan_coroutine)
            if not ok then
                print("[Profiler] Scan error: " .. tostring(err))
                state.scan_coroutine = nil
                break
            end
        else
            break
        end
    end
end

local function get_largest_tables(n)
    n = n or 10
    local sorted = {}
    for _, v in ipairs(state.scan_results or {}) do
        table.insert(sorted, v)
    end
    table.sort(sorted, function(a, b) return a.size > b.size end)
    local results = {}
    for i = 1, math.min(n, #sorted) do
        results[i] = sorted[i]
    end
    return results
end

--------------------------------------------------------------------------------
-- UI Rendering
--------------------------------------------------------------------------------

local function update_ui_content()
    if not ui.panel_entity then return end

    -- Clear old content
    for _, entity_id in ipairs(ui.content_entities or {}) do
        despawn(entity_id)
    end
    ui.content_entities = {}

    -- Header Content
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
        Text = { text = "[Profiler]" },
        TextFont = { font_size = 14 },
        TextColor = { color = Colors.text },
    }):with_parent(header:id())

    -- Right side: FPS and memory
    local right_side = spawn({
        Node = {
            flex_direction = "Row",
            column_gap = { Px = 8 },
            align_items = "Center",
        },
    }):with_parent(header:id())

    spawn({
        Text = { text = string.format("FPS: %d", state.current_fps) },
        TextFont = { font_size = 11 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(right_side:id())

    spawn({
        Text = { text = string.format("%.0f KB", state.lua_memory_kb) },
        TextFont = { font_size = 11 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(right_side:id())

    -- Section: Systems
    local systems_header = spawn({
        Node = {
            width = { Percent = 100 },
            flex_direction = "Row",
            justify_content = "SpaceBetween",
            align_items = "Center",
            margin = { top = { Px = 4 }, bottom = { Px = 4 } },
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, systems_header:id())

    spawn({
        Text = { text = "Systems" },
        TextFont = { font_size = 12 },
        TextColor = { color = Colors.text_dim },
    }):with_parent(systems_header:id())

    local mode_text = state.parallel_enabled and "PAR" or "SEQ"
    local mode_color = state.parallel_enabled and Colors.text_good or Colors.text_dim
    spawn({
        Text = { text = string.format("%d states [%s]", state.state_count, mode_text) },
        TextFont = { font_size = 10 },
        TextColor = { color = mode_color },
    }):with_parent(systems_header:id())

    -- Sort systems by avg time
    local sorted_systems = {}
    for name, data in pairs(state.systems) do
        table.insert(sorted_systems, { name = name, data = data })
    end
    table.sort(sorted_systems, function(a, b) return a.data.avg_ms > b.data.avg_ms end)

    -- Frame total row
    local total_lua_ms = 0
    for _, sys in ipairs(sorted_systems) do total_lua_ms = total_lua_ms + sys.data.avg_ms end
    local frame_time_ms = state.frame_times[#state.frame_times] or 0
    local total_pct = (frame_time_ms > 0) and (total_lua_ms / frame_time_ms * 100) or 0

    local total_line = spawn({
        Node = {
            width = { Percent = 100 },
            height = { Px = 16 },
            flex_direction = "Row",
            justify_content = "SpaceBetween",
            align_items = "Center",
            margin = { bottom = { Px = 4 } },
        },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, total_line:id())
    spawn({
        Text = { text = string.format("Total Lua: %s (%.0f%%)", format_ms(total_lua_ms), total_pct) },
        TextFont = { font_size = 10 },
        TextColor = { color = get_time_color(total_lua_ms) },
    }):with_parent(total_line:id())

    -- Scrollable systems list
    local systems_scroll = spawn({
        Node = {
            width = { Percent = 100 },
            height = { Px = 200 },
            flex_direction = "Column",
            flex_shrink = 0,
            overflow = { x = "Visible", y = "Scroll" },
        },
        ScrollPosition = { offset = { x = 0, y = state.systems_scroll_offset } },
    }):with_parent(ui.scroll_container)
    table.insert(ui.content_entities, systems_scroll:id())

    systems_scroll:observe("Pointer<Scroll>", function(world, entity, event)
        local scroll_event = event.event
        state.systems_scroll_offset = state.systems_scroll_offset - scroll_event.y * 20
        if state.systems_scroll_offset < 0 then state.systems_scroll_offset = 0 end
        entity:patch({ ScrollPosition = { offset = { x = 0, y = state.systems_scroll_offset } } })
    end)

    -- Display all systems
    for i = 1, #sorted_systems do
        local sys = sorted_systems[i]
        local name = sys.name
        local is_expanded = (state.expanded_system == name)
        local display_name = make_display_name(name)

        local row_node = { width = { Percent = 100 }, flex_direction = "Column" }
        if not is_expanded then row_node.height = { Px = ROW_HEIGHT } end

        local row = spawn({
            Node = row_node,
            BackgroundColor = { color = is_expanded and Colors.row_selected
                                    or ((i % 2 == 0) and Colors.row_alt or Colors.row_bg) },
        }):with_parent(systems_scroll:id())
        table.insert(ui.content_entities, row:id())

        -- Summary line
        local summary = spawn({
            Node = {
                width = { Percent = 100 },
                height = { Px = ROW_HEIGHT },
                flex_direction = "Row",
                justify_content = "SpaceBetween",
                align_items = "Center",
            },
        }):with_parent(row:id())

        local left = spawn({
            Node = { flex_direction = "Row", align_items = "Center", column_gap = { Px = 4 } },
        }):with_parent(summary:id())

        local state_id = sys.data.state_id or 0
        spawn({
            Text = { text = string.format("S%d", state_id) },
            TextFont = { font_size = 9 },
            TextColor = { color = state_id == 0 and Colors.text_dim or Colors.accent },
        }):with_parent(left:id())

        spawn({
            Text = { text = display_name },
            TextFont = { font_size = 11 },
            TextColor = { color = Colors.text },
        }):with_parent(left:id())

        spawn({
            Text = { text = format_ms(sys.data.avg_ms) },
            TextFont = { font_size = 11 },
            TextColor = { color = get_time_color(sys.data.avg_ms) },
        }):with_parent(summary:id())

        -- Expanded detail rows
        if is_expanded then
            local path = name:match("^[^:]+:(.+)$") or name
            local path_scroll = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = 16 },
                    align_items = "Center",
                    overflow = { x = "Scroll", y = "Visible" },
                    padding = { left = { Px = 20 } },
                },
                ScrollPosition = { offset = { x = 9999, y = 0 } },
            }):with_parent(row:id())
            spawn({
                Text = { text = path },
                TextFont = { font_size = 9 },
                TextColor = { color = Colors.text_dim },
                TextLayout = { linebreak = "NoWrap" },
            }):with_parent(path_scroll:id())

            local stats_line = spawn({
                Node = { width = { Percent = 100 }, height = { Px = 16 },
                    flex_direction = "Row", align_items = "Center", column_gap = { Px = 8 },
                    padding = { left = { Px = 20 } } },
            }):with_parent(row:id())
            spawn({
                Text = { text = string.format("max:%s", format_ms(sys.data.max_ms)) },
                TextFont = { font_size = 9 },
                TextColor = { color = get_time_color(sys.data.max_ms) },
            }):with_parent(stats_line:id())
            spawn({
                Text = { text = string.format("last:%s", format_ms(sys.data.last_ms)) },
                TextFont = { font_size = 9 },
                TextColor = { color = get_time_color(sys.data.last_ms) },
            }):with_parent(stats_line:id())
            spawn({
                Text = { text = string.format("x%d", sys.data.count) },
                TextFont = { font_size = 9 },
                TextColor = { color = Colors.text_dim },
            }):with_parent(stats_line:id())

            -- Per-system queries
            local sys_queries = sys.data.queries or {}
            local sorted_q = {}
            for sig, qdata in pairs(sys_queries) do
                table.insert(sorted_q, { sig = sig, data = qdata })
            end
            table.sort(sorted_q, function(a, b) return a.data.avg_ms > b.data.avg_ms end)

            if #sorted_q > 0 then
                local q_header_row = spawn({
                    Node = { width = { Percent = 100 }, height = { Px = 14 },
                        align_items = "Center",
                        padding = { left = { Px = 20 }, top = { Px = 2 } } },
                }):with_parent(row:id())
                spawn({
                    Text = { text = "Queries" },
                    TextFont = { font_size = 9 },
                    TextColor = { color = Colors.text_dim },
                }):with_parent(q_header_row:id())

                for qi = 1, math.min(5, #sorted_q) do
                    local q = sorted_q[qi]
                    local sig = q.sig
                    if #sig > 24 then sig = sig:sub(1, 21) .. "..." end
                    local q_row = spawn({
                        Node = { width = { Percent = 100 }, height = { Px = 14 },
                            flex_direction = "Row", justify_content = "SpaceBetween",
                            align_items = "Center",
                            padding = { left = { Px = 28 }, right = { Px = 4 } } },
                    }):with_parent(row:id())
                    spawn({
                        Text = { text = sig },
                        TextFont = { font_size = 9 },
                        TextColor = { color = Colors.text },
                    }):with_parent(q_row:id())
                    spawn({
                        Text = { text = string.format("%s n=%d", format_ms(q.data.avg_ms), q.data.last_result_count or 0) },
                        TextFont = { font_size = 9 },
                        TextColor = { color = get_time_color(q.data.avg_ms) },
                    }):with_parent(q_row:id())
                end
            end
        end

        -- Click to toggle expand
        summary:observe("Pointer<Click>", function()
            state.expanded_system = (state.expanded_system == name) and nil or name
            ui.needs_render = true
        end)
        summary:observe("Pointer<Over>", function(world, e)
            e:patch({ BackgroundColor = { color = Colors.row_hover } })
        end)
        summary:observe("Pointer<Out>", function(world, e)
            e:patch({ BackgroundColor = { color = Colors.transparent } })
        end)
    end

    -- Section: Growth Alerts
    if #state.scan_growth_alerts > 0 then
        local alerts_header = spawn({
            Node = {
                width = { Percent = 100 },
                margin = { top = { Px = 8 }, bottom = { Px = 4 } },
            },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, alerts_header:id())

        spawn({
            Text = { text = "! Table Growth" },
            TextFont = { font_size = 12 },
            TextColor = { color = Colors.text_warn },
        }):with_parent(alerts_header:id())

        for i = 1, math.min(5, #state.scan_growth_alerts) do
            local alert = state.scan_growth_alerts[i]
            local row = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = ROW_HEIGHT },
                    flex_direction = "Row",
                    justify_content = "SpaceBetween",
                    align_items = "Center",
                },
                BackgroundColor = { color = Colors.row_bg },
            }):with_parent(ui.scroll_container)
            table.insert(ui.content_entities, row:id())

            local display_path = alert.path
            if #display_path > 18 then
                display_path = "..." .. display_path:sub(-15)
            end

            spawn({
                Text = { text = display_path },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text },
            }):with_parent(row:id())

            spawn({
                Text = { text = string.format("+%d", alert.growth) },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text_bad },
            }):with_parent(row:id())
        end
    end

    -- Section: Largest Tables
    local largest = get_largest_tables(5)
    if #largest > 0 then
        local tables_header = spawn({
            Node = {
                width = { Percent = 100 },
                margin = { top = { Px = 8 }, bottom = { Px = 4 } },
            },
        }):with_parent(ui.scroll_container)
        table.insert(ui.content_entities, tables_header:id())

        spawn({
            Text = { text = "Largest Tables" },
            TextFont = { font_size = 12 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(tables_header:id())

        for i, tbl in ipairs(largest) do
            local row = spawn({
                Node = {
                    width = { Percent = 100 },
                    height = { Px = ROW_HEIGHT },
                    flex_direction = "Row",
                    justify_content = "SpaceBetween",
                    align_items = "Center",
                },
                BackgroundColor = { color = (i % 2 == 0) and Colors.row_alt or Colors.row_bg },
            }):with_parent(ui.scroll_container)
            table.insert(ui.content_entities, row:id())

            local display_path = tbl.path
            if #display_path > 20 then
                display_path = "..." .. display_path:sub(-17)
            end

            spawn({
                Text = { text = display_path },
                TextFont = { font_size = 10 },
                TextColor = { color = Colors.text },
            }):with_parent(row:id())

            spawn({
                Text = { text = tostring(tbl.size) },
                TextFont = { font_size = 10 },
                TextColor = { color = tbl.size > 500 and Colors.text_warn or Colors.text_dim },
            }):with_parent(row:id())
        end
    end
end

--------------------------------------------------------------------------------
-- Bootstrap: patch the mod entity into the panel UI root.
--------------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "sidebar/profiler/panel" } })
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

        update_ui_content()
    end
end)

--------------------------------------------------------------------------------
-- Update system: gather profiling data and refresh UI
--------------------------------------------------------------------------------
register_system("Update", function(world)
    if not ui.panel_entity then return end
    if not state.enabled then return end

    -- Update memory usage
    state.lua_memory_kb = collectgarbage("count")

    -- Track frame time
    local dt = world:delta_time() * 1000
    table.insert(state.frame_times, dt)
    while #state.frame_times > state.frame_time_max do
        table.remove(state.frame_times, 1)
    end

    -- Calculate FPS
    if #state.frame_times > 0 then
        local total_time = 0
        for _, frame_time in ipairs(state.frame_times) do
            total_time = total_time + frame_time
        end
        local avg_frame_time = total_time / #state.frame_times
        state.current_fps = avg_frame_time > 0 and math.floor(1000 / avg_frame_time + 0.5) or 0
    end

    -- Fetch Rust-side profiler stats
    local rust_stats = world:profiler_stats()
    if rust_stats then
        state.parallel_enabled = rust_stats.parallel_enabled or false

        local unique_states = {}
        if rust_stats.systems then
            local new_systems = {}
            for system_name, timing in pairs(rust_stats.systems) do
                local sid = timing.state_id or 0
                unique_states[sid] = true
                new_systems[system_name] = {
                    count = timing.count or 0,
                    total_ms = timing.total_ms or 0,
                    max_ms = timing.max_ms or 0,
                    avg_ms = timing.avg_ms or 0,
                    last_ms = timing.last_ms or 0,
                    state_id = sid,
                    queries = timing.queries or {},
                }
            end
            state.systems = new_systems
        end

        local count = 0
        for _ in pairs(unique_states) do count = count + 1 end
        state.state_count = count

        if rust_stats.queries then
            for signature, timing in pairs(rust_stats.queries) do
                state.queries[signature] = {
                    count = timing.count or 0,
                    total_ms = timing.total_ms or 0,
                    max_ms = timing.max_ms or 0,
                    avg_ms = timing.avg_ms or 0,
                    last_ms = timing.last_ms or 0,
                    last_result_count = timing.last_result_count or 0,
                }
            end
        end
    end

    -- Periodic table scanning
    if state.scan_enabled then
        state.scan_frame_counter = state.scan_frame_counter + 1
        if state.scan_coroutine then
            resume_scan()
        elseif state.scan_frame_counter % state.scan_interval_frames == 0 then
            start_global_scan()
        end
    end

    -- Update UI periodically (every 30 frames) or immediately on click
    state.update_counter = (state.update_counter or 0) + 1
    if state.update_counter % 30 == 0 or ui.needs_render then
        ui.needs_render = false
        update_ui_content()
    end
end)
