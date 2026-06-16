-- modules/sidebar/button/client/init.lua
-- Reusable sidebar button mod: icon in icon bar, hover effects, click → panel toggle.
-- Reads parent's sidebar component for icon_bar_id.
-- Sets ["sidebar/button"]on self for sidebar's escape tracking.
--
-- Config (via "sidebar/button" component):
--   icon_text     = "▶"                              -- icon label
--   title         = "Profiler"                        -- tooltip/label
--   panel_mod     = "sidebar/profiler/panel"          -- client-only panel mod
--   panel_net_mod = "sidebar/file_browser/panel"      -- OR: networked panel mod
--   panel_config  = {}                                -- extra config for panel mod

local Colors = require("modules/sidebar/shared/colors.lua")

local json = require("modules/dkjson.lua")


local ICON_SIZE = 36

-- Per-button bookkeeping for live config edits. Tracks the inner icon child
-- entity (so we can swap it on icon_asset/icon_text edits) and the last config
-- (so we can detect what actually changed and skip self-patch noise).
local button_instances = define_resource("SidebarButtonInstances", {
    by_id = {},  -- [eid] = { icon_btn_id, icon_child_id, last_config }
})

--- Spawn the inner icon child (image or text) inside `icon_btn_id`.
--- For `icon_asset`, load is async — by the time the callback fires, the
--- button's config may have changed. Drop stale results so A→B→A patches
--- don't leave A's icon hanging.
local function spawn_icon_child(button_eid, icon_btn_id, config, on_spawned)
    if config.icon_asset then
        local loading_asset = config.icon_asset
        load_asset_async(loading_asset, function(icon_asset)
            -- Stale check: did the config change while we were loading?
            local cur = button_instances.by_id[button_eid]
            if not cur or (cur.last_config or {}).icon_asset ~= loading_asset then
                return
            end
            local child = spawn({
                ImageNode = { image = icon_asset },
                Node = {
                    width = { Px = ICON_SIZE - 8 },
                    height = { Px = ICON_SIZE - 8 },
                },
            }):with_parent(icon_btn_id)
            on_spawned(child:id())
        end)
    else
        local child = spawn({
            Text = { text = config.icon_text and config.icon_text:sub(1, 1) or "?" },
            TextFont = { font_size = 18 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(icon_btn_id)
        on_spawned(child:id())
    end
end

register_system("First", function(world)
    -- Initial setup on `added`
    local added = world:query({
        added = { "sidebar/button" },
        optional = { "ChildOf" }
    })
    for _, entity in ipairs(added) do
        local config = entity:get("sidebar/button") or {}

        -- Walk up to parent (sidebar entity) to get icon_bar_id
        local parent_id = entity:get("ChildOf")
        if not parent_id then
            print("[SIDEBAR/BUTTON] WARNING: No parent found (expected sidebar entity)")
            goto continue
        end

        local parent = world:get_entity(parent_id)
        if not parent then goto continue end

        local sidebar_data = parent:get("sidebar")
        if not sidebar_data or not sidebar_data.icon_bar_id then
            print("[SIDEBAR/BUTTON] WARNING: Parent has no sidebar data")
            goto continue
        end

        local icon_bar_id = sidebar_data.icon_bar_id

        -- Spawn icon button in sidebar's icon bar
        local icon_btn = spawn({
            Button = {},
            Node = {
                width = { Px = ICON_SIZE },
                height = { Px = ICON_SIZE },
                justify_content = "Center",
                align_items = "Center",
            },
            BackgroundColor = { color = Colors.icon_bg },
            BorderRadius = {
                top_left = { Px = 6 }, top_right = { Px = 6 },
                bottom_left = { Px = 6 }, bottom_right = { Px = 6 },
            },
        }):with_parent(icon_bar_id)

        local eid = entity:id()
        local icon_btn_id = icon_btn:id()

        -- Track instance BEFORE spawning icon child so async stale-check works
        button_instances.by_id[eid] = {
            icon_btn_id = icon_btn_id,
            icon_child_id = nil,
            last_config = config,
        }

        spawn_icon_child(eid, icon_btn_id, config, function(child_id)
            local cur = button_instances.by_id[eid]
            if cur then cur.icon_child_id = child_id end
        end)

        -- Check for a surviving panel from a prior hot-reload.
        -- Panels are children of the sidebar entity with a component matching
        -- the button's panel_mod (e.g. "sidebar/profiler/panel").
        local existing_panel_id = nil
        local panel_mod = config.panel_mod
        if panel_mod then
            local siblings = world:query({
                with = { panel_mod },
                entities = { parent_id },
            })
            if #siblings > 0 then
                existing_panel_id = siblings[1]:id()
            end
        end

        -- Set ["sidebar/button"]component for sidebar's panel tracking
        entity:patch({ ["sidebar/button"]= {
            icon_entity_id = icon_btn_id,
            panel_entity_id = existing_panel_id,
            opened_at = existing_panel_id and os.clock() or nil,
        }})

        -- Store IDs and entity references for observer closures
        local sidebar_entity_id = parent_id
        local button_entity = entity  -- captured for reading/patching ["sidebar/button"]component

        -- Hover effects (use only the entity_snapshot argument; world is unavailable)
        icon_btn:observe("Pointer<Over>", function(world, icon)
            local btn_state = world:get_entity(button_entity:id()):get("sidebar/button")
            if not btn_state.panel_entity_id and not btn_state.panel_net_mod_open then
                icon:set({ BackgroundColor = { color = Colors.icon_hover } })
            end
        end)
        icon_btn:observe("Pointer<Out>", function(world, icon)
            local btn_state = world:get_entity(button_entity:id()):get("sidebar/button")
            if not btn_state.panel_entity_id and not btn_state.panel_net_mod_open then
                icon:set({ BackgroundColor = { color = Colors.icon_bg } })
            end
        end)

        -- Click: toggle panel.
        -- Read panel_mod / panel_config from the component each click so that
        -- live edits to the button config take effect on the next click.
        icon_btn:observe("Pointer<Click>", function(world, icon)
            local btn_state = world:get_entity(button_entity:id()):get("sidebar/button")
            local current_panel = btn_state.panel_entity_id
            local net_mod_open = btn_state.panel_net_mod_open

            if current_panel then
                -- Close panel UI (works for both local and networked panels now)
                despawn(current_panel)
            end

            if net_mod_open then
                -- Close net_mod panel: tell server to unload
                local cfg = button_entity:get("sidebar/button") or {}
                local sidebar = world:get_entity(sidebar_entity_id)
                if sidebar and cfg.panel_net_mod then
                    sidebar:patch({ sidebar = {
                        close_panels = { [cfg.panel_net_mod] = true },
                    } })
                end
            end

            if current_panel or net_mod_open then
                -- Clear button state
                button_entity:patch({ ["sidebar/button"]= {
                    panel_entity_id = null,
                    panel_net_mod_open = null,
                    opened_at = null,
                }})
                icon:set({ BackgroundColor = { color = Colors.icon_bg } })
            else
                local cfg = button_entity:get("sidebar/button") or {}
                if cfg.panel_net_mod then
                    -- Client-side UI container for the net_mod panel
                    -- We initialize it with the sidebar/loading mod to show a template
                    local container = spawn({
                        Node = { display = "Flex", height = { Percent = 100 }, width = { Percent = 100 } },
                        mod = { ["sidebar/loading"] = { title = cfg.title } },
                    }):with_parent(sidebar_entity_id)

                    local panel_config = cfg.panel_config or {}
                    panel_config.container_id = container:id()

                    -- Request server to load panel as net_mod on the player entity
                    local sidebar = world:get_entity(sidebar_entity_id)
                    if sidebar then
                        sidebar:patch({ sidebar = {
                            open_panels = { [cfg.panel_net_mod] = panel_config },
                        } })
                    end

                    -- Wait for panel to load and clear loading mod
                    local timeout = 10.0
                    register_system("Update", function(world)
                        timeout = timeout - world:delta_time()
                        if timeout <= 0 then
                            print("[SIDEBAR/BUTTON] Timeout loading net panel " .. cfg.panel_net_mod)
                            return true
                        end
                        local added_net_mods = world:query({ added = { cfg.panel_net_mod } })
                        for _, added_net_mod in ipairs(added_net_mods) do
                            local panel_cfg = added_net_mod:get(cfg.panel_net_mod)
                            -- If added to this sidebar, remove loading mod and despawn loading panel
                            if added_net_mod:id() == sidebar:id() then
                                container:patch({ mod = { ["sidebar/loading"] = null } })
                                if panel_cfg.loading_panel_id then
                                    despawn(panel_cfg.loading_panel_id)
                                end
                                return true
                            end
                        end
                    end)

                    button_entity:patch({ ["sidebar/button"]= {
                        panel_entity_id = container:id(),
                        panel_net_mod_open = true,
                        opened_at = os.clock(),
                    }})
                    icon:set({ BackgroundColor = { color = Colors.icon_active } })
                elseif cfg.panel_mod then
                    -- Client-only panel: spawn locally
                    local panel = spawn({
                        mod = { [cfg.panel_mod] = cfg.panel_config or {} },
                    }):with_parent(sidebar_entity_id)
                    button_entity:patch({ ["sidebar/button"]= {
                        panel_entity_id = panel:id(),
                        opened_at = os.clock(),
                    }})
                    icon:set({ BackgroundColor = { color = Colors.icon_active } })
                end
            end
        end)

        print(string.format("[SIDEBAR/BUTTON] Registered '%s'", config.title or config.icon_text or "?"))

        ::continue::
    end

    -- Live re-config on `changed`: swap icon child if the visual changed
    local changed = world:query({ changed = { "sidebar/button" } })
    for _, entity in ipairs(changed) do
        local eid = entity:id()
        local inst = button_instances.by_id[eid]
        if inst then
            local new_cfg = entity:get("sidebar/button") or {}
            local old_cfg = inst.last_config or {}
            if new_cfg.icon_asset ~= old_cfg.icon_asset
               or new_cfg.icon_text ~= old_cfg.icon_text then
                if inst.icon_child_id then
                    despawn(inst.icon_child_id)
                    inst.icon_child_id = nil
                end
                -- Update last_config BEFORE spawning so the async stale-check
                -- in spawn_icon_child sees the current asset path.
                inst.last_config = new_cfg
                spawn_icon_child(eid, inst.icon_btn_id, new_cfg, function(child_id)
                    local cur = button_instances.by_id[eid]
                    if cur then cur.icon_child_id = child_id end
                end)
            else
                inst.last_config = new_cfg
            end

            local btn_state = entity:get("sidebar/button")
            if inst.icon_btn_id then
                local icon = world:get_entity(inst.icon_btn_id)
                if icon then
                    if btn_state.panel_entity_id or btn_state.panel_net_mod_open then
                        icon:set({ BackgroundColor = { color = Colors.icon_active } })
                    else
                        icon:set({ BackgroundColor = { color = Colors.icon_bg } })
                    end
                end
            end
        end
    end
end)
