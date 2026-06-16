-- modules/vr/ui_panels/client/init.lua
-- VR UI Panels: converts root-level UI nodes into 3D world-space panels.
-- Each root Node gets an RTT (render-to-texture) Camera2d that captures the UI,
-- and a Plane3d mesh that displays the texture in the 3D scene.
-- Distance from HMD is based on GlobalZIndex (higher = closer).
-- Loaded by vr orchestrator mod when VR is detected.

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local PIXELS_TO_METERS = 0.0008
local BASE_DISTANCE    = 0.6
local Z_INDEX_SCALE    = 0.0003
local MIN_DISTANCE     = 0.25

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local panel_state = define_resource("VrUiPanelsState", {
    panels = {},  -- node_id → { camera_id, mesh_id }
})

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Get HMD horizontal forward from VrControllerState
local function get_hmd_horizontal_forward(world)
    local ctrl = world:get_resource("VrControllerState")
    if not ctrl or not ctrl.hmd_forward then return nil end
    local fwd = ctrl.hmd_forward
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 0.001 then return { x = 0, z = -1 } end
    return { x = fwd.x / len, z = fwd.z / len }
end

--- Get a spawn position in front of HMD at head height
local function get_position_in_front_of_hmd(world, distance)
    local ctrl = world:get_resource("VrControllerState")
    if not ctrl then return nil end
    local hmd_pos = ctrl.hmd_position
    if not hmd_pos then return nil end
    local fwd = get_hmd_horizontal_forward(world)
    if not fwd then return nil end
    return {
        x = hmd_pos.x + fwd.x * distance,
        y = hmd_pos.y,
        z = hmd_pos.z + fwd.z * distance,
    }
end

--- Make a panel face the camera (horizontal rotation only, stays upright)
local function look_at_camera(world, panel_id)
    local panel_entity = world:get_entity(panel_id)
    if not panel_entity then return end

    local ctrl = world:get_resource("VrControllerState")
    if not ctrl then return end
    local cam_pos = ctrl.hmd_position
    if not cam_pos then return end

    local panel_t = panel_entity:get("Transform")
    if not panel_t or not panel_t.translation then return end
    local pos = panel_t.translation

    local to_camera = { x = cam_pos.x - pos.x, y = 0, z = cam_pos.z - pos.z }
    local len = math.sqrt(to_camera.x * to_camera.x + to_camera.z * to_camera.z)
    if len > 0.001 then
        to_camera.x = to_camera.x / len
        to_camera.z = to_camera.z / len
    end

    world:call_component_method(
        panel_id, "Transform", "looking_at",
        { x = pos.x, y = pos.y + 1, z = pos.z },
        to_camera
    )
end

--- Destroy a panel (RTT camera + mesh) for a given node_id
local function destroy_panel(world, node_id)
    local panel = panel_state.panels[node_id]
    if not panel then return end
    -- Remove UiTargetCamera from the node so Bevy falls back to the default
    -- camera and resumes layout. Without this, the node points to a despawned
    -- RTT camera and Bevy skips its layout, preventing re-creation.
    local node_entity = world:get_entity(node_id)
    if node_entity then
        pcall(function() node_entity:remove("UiTargetCamera") end)
    end
    local cam = world:get_entity(panel.camera_id)
    if cam then despawn(cam) end
    local mesh = world:get_entity(panel.mesh_id)
    if mesh then despawn(mesh) end
    panel_state.panels[node_id] = nil
end

--- Convert a UI node to a 3D VR panel.
--- Respawns if the node is already a panel (size change etc).
local function convert_node_to_panel(world, node_id)
    local node_entity = world:get_entity(node_id)
    local is_child = node_entity and node_entity:get("ChildOf")

    -- Reparented or despawned nodes should have their panel destroyed
    if not node_entity or is_child then
        destroy_panel(world, node_id)
        return
    end

    local computed = node_entity:get("ComputedNode")
    local width  = computed and computed.size and math.floor(computed.size.x) or 0
    local height = computed and computed.size and math.floor(computed.size.y) or 0

    -- Check if node is hidden (display = "None") or has no computed size
    local node = node_entity:get("Node")
    local is_hidden = node and node.display == "None"

    if is_hidden or width == 0 or height == 0 then
        -- Destroy the panel if it exists (node was hidden or collapsed)
        destroy_panel(world, node_id)
        return
    end

    local panel_width  = width  * PIXELS_TO_METERS
    local panel_height = height * PIXELS_TO_METERS

    local z_index = node_entity:get("GlobalZIndex")
    local distance = math.max(MIN_DISTANCE, BASE_DISTANCE - (z_index * Z_INDEX_SCALE))

    -- Preserve transform if re-creating an existing panel
    local should_set_new_transform = true
    local transform = nil
    if panel_state.panels[node_id] then
        local old_mesh = world:get_entity(panel_state.panels[node_id].mesh_id)
        if old_mesh then
            local old_t = old_mesh:get("Transform")
            if old_t then
                should_set_new_transform = false
                transform = old_t
            end
        end
        destroy_panel(world, node_id)
    else
        local translation = get_position_in_front_of_hmd(world, distance)
        transform = {
            translation = translation or { x = 0, y = 1.5, z = -distance },
            rotation = { x = 0, y = 0, z = 0, w = 1 },
            scale = { x = 1, y = 1, z = 1 },
        }
    end

    -- RTT image
    local rtt_image = create_asset("bevy_image::image::Image", {
        width = width, height = height, format = "Bgra8UnormSrgb",
    })

    -- RTT Camera2d (renders the UI into the texture)
    local rtt_camera = spawn({
        Camera2d = {},
        Camera = { order = -200, target = { Image = rtt_image } },
    })

    -- Retarget the UI node to the RTT camera
    node_entity:set({ UiTargetCamera = { entity = rtt_camera:id() } })

    -- Panel mesh (Plane3d)
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
        VrPanelMarker = {
            node_id        = node_id,
            texture_width  = width,
            texture_height = height,
            rtt_image      = rtt_image,
            camera_id      = rtt_camera:id(),
        },
        vr_grabbable = { lock_rotation = true },
    })

    panel_state.panels[node_id] = {
        camera_id = rtt_camera:id(),
        mesh_id   = panel_mesh:id(),
    }

    -- Face the camera on next frame (one-shot system)
    if should_set_new_transform then
        local mesh_id = panel_mesh:id()
        register_system("Update", function(w)
            look_at_camera(w, mesh_id)
            return true  -- run once
        end)
    end
end

---------------------------------------------------------------------------
-- Init: convert all existing root nodes (once)
---------------------------------------------------------------------------
register_system("First", function(world)
    local nodes = world:query({
        with = { "Node", "ComputedNode" },
        optional = { "ChildOf" },
    })
    for _, entity in ipairs(nodes) do
        convert_node_to_panel(world, entity:id())
    end
    return true  -- run once
end)

---------------------------------------------------------------------------
-- Update: react to node add/change/remove + reparenting
---------------------------------------------------------------------------
register_system("Update", function(world)
    -- Pass 1: Root nodes added/changed/removed
    local root_changes = world:query({
        with = { "Node", "ComputedNode" },
        without = { "ChildOf" },
        ["or"] = {
            added   = { "Node" },
            changed = { "ComputedNode", "Node" },
            removed = { "Node" },
        },
    })
    for _, entity in ipairs(root_changes) do
        if entity:is_added("Node") or entity:is_changed("ComputedNode") or entity:is_changed("Node") then
            convert_node_to_panel(world, entity:id())
        elseif entity:is_removed("Node") then
            destroy_panel(world, entity:id())
        end
    end

    -- Pass 2: Reparenting (ChildOf added/changed/removed)
    local child_changes = world:query({
        with = { "Node", "ComputedNode" },
        ["or"] = {
            added   = { "ChildOf" },
            changed = { "ChildOf" },
            removed = { "ChildOf" },
        },
    })
    for _, entity in ipairs(child_changes) do
        local parent_id = entity:get("ChildOf")

        if entity:is_added("ChildOf") or entity:is_changed("ChildOf") then
            destroy_panel(world, entity:id())
            if parent_id then
                convert_node_to_panel(world, parent_id)
            end
        elseif entity:is_removed("ChildOf") then
            convert_node_to_panel(world, entity:id())
            if parent_id and panel_state.panels[parent_id] then
                convert_node_to_panel(world, parent_id)
            end
        end
    end
end, { label = "VrUiPanels", after = { "VrPointer" } })
