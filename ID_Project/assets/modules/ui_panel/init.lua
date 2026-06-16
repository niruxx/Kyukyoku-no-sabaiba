-- modules/ui_panel/init.lua
-- Reusable RTT mod: converts a UI Node hierarchy into a 3D mesh.
-- Redesigned from OLD_MODULES/vr/ui_panels.lua.
--
-- Watches for entities with `ui_panel` component (placed by the mod system).
-- Finds the target Node (own Node, or sidebar's container), creates:
--   RTT Image → Camera2d → Mesh3d + StandardMaterial (unlit, double-sided)
-- Sets UiTargetCamera on the Node to redirect rendering to the RTT camera.
-- Rebuilds on ComputedNode size changes.

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local PIXELS_TO_METERS = 0.0008
local BASE_DISTANCE = 0.6
local Z_INDEX_SCALE = 0.0003
local MIN_DISTANCE = 0.25
local DEFAULT_CAMERA_ORDER = -200

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = define_resource("UiPanelState", {
    -- node_id → { camera_id, mesh_id, rtt_image, texture_width, texture_height }
    panels = {},
})

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Find the target Node entity for an entity with ui_panel.
--- Checks: 1) explicit config.node_id, 2) sidebar component's container_id,
--- 3) the entity itself if it has a Node.
local function find_target_node(world, entity)
    local config = entity:get("ui_panel") or {}

    -- 1. Explicit node_id in config
    if config.node_id then
        return config.node_id
    end

    -- 2. Sidebar container
    local sidebar = entity:get("sidebar")
    if sidebar and sidebar.container_id then
        return sidebar.container_id
    end

    -- 3. Entity itself has a Node
    if entity:has("Node") then
        return entity:id()
    end

    return nil
end

--- Destroy an existing panel for a node.
local function destroy_panel(node_id)
    local panel = state.panels[node_id]
    if not panel then return end

    if panel.camera_id then
        pcall(despawn, panel.camera_id)
    end
    if panel.mesh_id then
        pcall(despawn, panel.mesh_id)
    end
    state.panels[node_id] = nil
end

--- Create (or re-create) an RTT panel for a Node entity.
local function create_panel(world, node_id, config)
    local node_entity = world:get_entity(node_id)
    if not node_entity then return end

    local computed_node = node_entity:get("ComputedNode")
    if not computed_node then return end

    local width = computed_node.size and math.floor(computed_node.size.x) or 0
    local height = computed_node.size and math.floor(computed_node.size.y) or 0

    -- Node may not have computed size yet
    if width == 0 or height == 0 then return end

    config = config or {}
    local pixels_to_meters = config.pixels_to_meters or PIXELS_TO_METERS
    local panel_width = width * pixels_to_meters
    local panel_height = height * pixels_to_meters

    -- Distance based on z-index
    local z_index = node_entity:get("GlobalZIndex")
    z_index = z_index and z_index.value or 0
    local distance = math.max(
        MIN_DISTANCE,
        (config.distance or BASE_DISTANCE) - (z_index * Z_INDEX_SCALE)
    )

    -- Preserve transform from existing panel if rebuilding
    local existing = state.panels[node_id]
    local transform = nil
    if existing and existing.mesh_id then
        local old_mesh = world:get_entity(existing.mesh_id)
        if old_mesh then
            transform = old_mesh:get("Transform")
        end
    end

    -- Clean up existing
    destroy_panel(node_id)

    -- Default transform: spawn in front
    if not transform then
        transform = {
            translation = { x = 0, y = 1.5, z = -distance },
            rotation = { x = 0, y = 0, z = 0, w = 1 },
            scale = { x = 1, y = 1, z = 1 },
        }
    end

    -- RTT Image
    local rtt_image = create_asset("bevy_image::image::Image", {
        width = width,
        height = height,
        format = "Bgra8UnormSrgb",
    })

    -- RTT Camera
    local camera = spawn({
        Camera2d = {},
        Camera = {
            order = config.camera_order or DEFAULT_CAMERA_ORDER,
            target = { Image = rtt_image },
        },
    })

    -- Retarget the Node to the RTT camera
    node_entity:set({ UiTargetCamera = { entity = camera:id() } })

    -- 3D Mesh
    local mesh = create_asset("bevy_mesh::mesh::Mesh", {
        primitive = { Plane3d = { half_size = { x = panel_width / 2, y = panel_height / 2 } } },
    })

    local material = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
        base_color_texture = rtt_image,
        unlit = true,
        cull_mode = "None",
    })

    local panel_mesh = spawn({
        Mesh3d = { _0 = mesh },
        ["MeshMaterial3d<StandardMaterial>"] = { _0 = material },
        Transform = transform,
        UiPanelMarker = {
            node_id = node_id,
            texture_width = width,
            texture_height = height,
            rtt_image = rtt_image,
            camera_id = camera:id(),
        },
    })

    -- Store panel data
    state.panels[node_id] = {
        camera_id = camera:id(),
        mesh_id = panel_mesh:id(),
        rtt_image = rtt_image,
        texture_width = width,
        texture_height = height,
    }

    return panel_mesh
end

--------------------------------------------------------------------------------
-- Init: watch for ui_panel mod added
--------------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "ui_panel" } })
    for _, entity in ipairs(entities) do
        local config = entity:get("ui_panel") or {}
        local node_id = find_target_node(world, entity)
        if node_id then
            -- Store the node_id in the component for later reference
            entity:patch({ ui_panel = {
                node_id = node_id,
                pixels_to_meters = config.pixels_to_meters,
                distance = config.distance,
                camera_order = config.camera_order,
            }})
            create_panel(world, node_id, config)
        end
    end
end)

--------------------------------------------------------------------------------
-- Update: rebuild on ComputedNode changes, handle re-parenting
--------------------------------------------------------------------------------
register_system("Update", function(world)
    -- Rebuild panels when ComputedNode changes (resize)
    local changed = world:query({
        with = { "Node", "ComputedNode" },
        ["or"] = { changed = { "ComputedNode" } },
    })
    for _, entity in ipairs(changed) do
        local node_id = entity:id()
        local panel = state.panels[node_id]
        if panel then
            -- Check if size actually changed
            local computed = entity:get("ComputedNode")
            local new_w = computed.size and math.floor(computed.size.x) or 0
            local new_h = computed.size and math.floor(computed.size.y) or 0

            if new_w > 0 and new_h > 0 and
               (new_w ~= panel.texture_width or new_h ~= panel.texture_height) then
                -- Find the ui_panel entity that owns this node_id
                local ui_panels = world:query({ with = { "ui_panel" } })
                for _, upe in ipairs(ui_panels) do
                    local config = upe:get("ui_panel")
                    if config and config.node_id == node_id then
                        create_panel(world, node_id, config)
                        break
                    end
                end
            end
        end
    end

    -- Handle re-parenting (ChildOf changes on tracked nodes)
    local reparented = world:query({
        with = { "Node", "ComputedNode" },
        ["or"] = {
            added = { "ChildOf" },
            changed = { "ChildOf" },
            removed = { "ChildOf" },
        },
    })
    for _, entity in ipairs(reparented) do
        local node_id = entity:id()
        if state.panels[node_id] then
            if entity:is_added("ChildOf") or entity:is_changed("ChildOf") then
                -- Node got a parent → it's no longer root, destroy its panel
                destroy_panel(node_id)
            elseif entity:is_removed("ChildOf") then
                -- Node became root → create panel
                local ui_panels = world:query({ with = { "ui_panel" } })
                for _, upe in ipairs(ui_panels) do
                    local config = upe:get("ui_panel")
                    if config and config.node_id == node_id then
                        create_panel(world, node_id, config)
                        break
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Cleanup: remove panels when ui_panel is removed
--------------------------------------------------------------------------------
register_system("Update", function(world)
    local removed = world:query({ removed = { "ui_panel" } })
    for _, entity in ipairs(removed) do
        -- Find and destroy any panels owned by this entity
        for node_id, _ in pairs(state.panels) do
            destroy_panel(node_id)
        end
    end
end)
