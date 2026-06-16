-- modules/vr/pointer/client/init.lua
-- VR Pointer: laser visual + MeshRayCast + PointerInput writer.
-- Loaded by vr orchestrator on the player entity. Reads pointer hand from VrSettings.
-- Raycasts from the active controller, detects VrPanelMarker panels,
-- and writes PointerInput messages so Bevy UI receives VR click/move events.

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local VR_POINTER_UUID = 90870999   -- Custom PointerId for VR controller
local LASER_LENGTH    = 2.0        -- metres
local LASER_RADIUS    = 0.002      -- 2mm
local LONG_PRESS_TIME = 0.5        -- seconds for right-click simulation
local LONG_PRESS_TOL  = 15         -- pixels of movement allowed during hold

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local pointer_state = define_resource("VrPointerState", {
    pointer_entity = nil,  -- PointerId entity
    laser_entity   = nil,  -- Laser mesh entity
    hovered_entity = nil,  -- Currently hovered VrPanelMarker entity

    -- Trigger edge detection (Lua-side, frame-safe)
    trigger_pressed      = false,
    trigger_last_pressed = false,
    trigger_just_pressed = false,
    trigger_just_released = false,

    -- Long press (right-click simulation)
    hold_start_time  = nil,
    hold_start_pos   = nil,
    is_long_press    = false,
    long_press_sent  = false,
})

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Get pointer hand from VrSettings (default: right)
local function get_pointer_hand()
    local settings = define_resource("VrSettings", {})
    return settings.pointer_hand or "right"
end

--- Get active controller position/forward from VrControllerState
local function get_active_controller(world)
    local ctrl = world:get_resource("VrControllerState")
    if not ctrl then return nil, nil end
    local hand = get_pointer_hand()
    if hand == "left" then
        return ctrl.left_position, ctrl.left_forward
    else
        return ctrl.right_position, ctrl.right_forward
    end
end

--- Get trigger pressed state from VrButtonState
local function get_trigger_pressed(world)
    local vr = world:get_resource("VrButtonState")
    if not vr then return false end
    local hand = get_pointer_hand()
    if hand == "left" then
        return vr.left_trigger_pressed or false
    else
        return vr.right_trigger_pressed or false
    end
end

--- Quaternion from Y-axis to a target direction (for laser orientation)
local function quat_from_y_to_dir(target)
    local dot = target.y  -- from = {0,1,0}, so dot = target.y
    if dot > 0.9999 then return { x = 0, y = 0, z = 0, w = 1 } end
    if dot < -0.9999 then return { x = 1, y = 0, z = 0, w = 0 } end
    -- cross({0,1,0}, target) = {tz, 0, -tx}
    local cx, cy, cz = target.z, 0, -target.x
    local w = 1 + dot
    local len = math.sqrt(cx*cx + cz*cz + w*w)
    return { x = cx/len, y = cy/len, z = cz/len, w = w/len }
end

---------------------------------------------------------------------------
-- Init: spawn PointerId + laser visual (once)
---------------------------------------------------------------------------
register_system("First", function(world)
    -- Only init once
    if pointer_state.pointer_entity then return true end

    -- Spawn custom PointerId for VR controller
    local ptr = spawn({ PointerId = { Custom = VR_POINTER_UUID } })
    pointer_state.pointer_entity = ptr:id()

    -- Create laser mesh (cylinder) + material (red, unlit, semi-transparent)
    local laser_mesh = create_asset("bevy_mesh::mesh::Mesh", {
        primitive = { Cylinder = { radius = LASER_RADIUS, half_height = 0.5 } }
    })
    local laser_mat = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
        base_color = { r = 1.0, g = 0.2, b = 0.2, a = 0.8 },
        unlit = true,
        alpha_mode = "Blend",
    })
    local laser = spawn({
        Mesh3d = { _0 = laser_mesh },
        ["MeshMaterial3d<StandardMaterial>"] = { _0 = laser_mat },
        Transform = {
            translation = { x = 0, y = 0, z = 0 },
            scale = { x = 0, y = 0, z = 0 }, -- start hidden
        },
        LaserPointer = {},
        -- Pickable::IGNORE: keep the laser out of pointer/placement raycasts.
        Pickable = { should_block_lower = false, is_hoverable = false },
    })
    pointer_state.laser_entity = laser:id()

    print(string.format("[VR/POINTER] Spawned pointer=%d, laser=%d",
        pointer_state.pointer_entity, pointer_state.laser_entity))
    return true
end)

---------------------------------------------------------------------------
-- Update: raycast, laser visual, PointerInput messages
---------------------------------------------------------------------------
register_system("Update", function(world)
    if not pointer_state.pointer_entity then return end

    local pos, fwd = get_active_controller(world)
    if not pos or not fwd then return end

    -- === Laser visual ===
    local laser = world:get_entity(pointer_state.laser_entity)
    if laser then
        local center = {
            x = pos.x + fwd.x * (LASER_LENGTH / 2),
            y = pos.y + fwd.y * (LASER_LENGTH / 2),
            z = pos.z + fwd.z * (LASER_LENGTH / 2),
        }
        local rot = quat_from_y_to_dir(fwd)
        laser:set({ Transform = {
            translation = center,
            rotation = rot,
            scale = { x = 1, y = LASER_LENGTH, z = 1 },
        }})
    end

    -- === Trigger edge detection ===
    local current_pressed = get_trigger_pressed(world)
    pointer_state.trigger_just_pressed  = current_pressed and not pointer_state.trigger_last_pressed
    pointer_state.trigger_just_released = not current_pressed and pointer_state.trigger_last_pressed
    pointer_state.trigger_pressed       = current_pressed
    pointer_state.trigger_last_pressed  = current_pressed

    -- === MeshRayCast ===
    local ray = { origin = pos, direction = fwd, early_exit = false }
    local ok, result = pcall(world.call_systemparam_method, world, "MeshRayCast", "cast_ray", ray)
    if not ok then result = nil end

    local prev_hovered = pointer_state.hovered_entity
    local new_hovered = nil

    if result and type(result) == "table" then
        for _, hit in ipairs(result) do
            local entity_bits = hit.entity
            local data = hit.data
            if entity_bits and data and data.uv then
                local hit_entity = world:get_entity(entity_bits)
                if hit_entity then
                    local marker = hit_entity:get("VrPanelMarker")
                    if marker and marker.texture_width and marker.rtt_image then
                        local tex_x = data.uv.x * marker.texture_width
                        local tex_y = data.uv.y * marker.texture_height
                        write_pointer_input(world, marker.rtt_image, tex_x, tex_y)
                        new_hovered = entity_bits
                        break
                    end
                end
            end
        end
    end

    -- Update hover tracking
    if new_hovered ~= prev_hovered then
        if prev_hovered then
            local old = world:get_entity(prev_hovered)
            if old then old:set({ VrHovered = nil }) end
        end
        if new_hovered then
            local ne = world:get_entity(new_hovered)
            if ne then ne:set({ VrHovered = {} }) end
        end
    end
    pointer_state.hovered_entity = new_hovered
end, { label = "VrPointer" })

---------------------------------------------------------------------------
-- Internal: write PointerInput messages
---------------------------------------------------------------------------
function write_pointer_input(world, rtt_image, tex_x, tex_y)
    local pointer_id = { Custom = VR_POINTER_UUID }
    local location = {
        target = { Image = rtt_image },
        position = { x = tex_x, y = tex_y },
    }

    -- Always send Move
    world:write_message("PointerInput", {
        pointer_id = pointer_id,
        location = location,
        action = { Move = { delta = { x = 0, y = 0 } } },
    })

    -- === Long press detection ===
    local now = os.clock()

    if pointer_state.trigger_just_pressed then
        pointer_state.hold_start_time = now
        pointer_state.hold_start_pos  = { x = tex_x, y = tex_y }
        pointer_state.is_long_press   = false
        pointer_state.long_press_sent = false
    end

    if pointer_state.trigger_pressed and pointer_state.hold_start_time
       and not pointer_state.long_press_sent then
        local dt = now - pointer_state.hold_start_time
        local dx = tex_x - pointer_state.hold_start_pos.x
        local dy = tex_y - pointer_state.hold_start_pos.y
        local movement = math.sqrt(dx*dx + dy*dy)
        if dt >= LONG_PRESS_TIME and movement <= LONG_PRESS_TOL then
            pointer_state.is_long_press   = true
            pointer_state.long_press_sent = true
            world:write_message("PointerInput", {
                pointer_id = pointer_id, location = location,
                action = { Press = "Secondary" },
            })
            world:write_message("PointerInput", {
                pointer_id = pointer_id, location = location,
                action = { Release = "Secondary" },
            })
        elseif movement > LONG_PRESS_TOL then
            pointer_state.hold_start_time = nil
        end
    end

    -- Press / Release
    if pointer_state.trigger_just_pressed then
        world:write_message("PointerInput", {
            pointer_id = pointer_id, location = location,
            action = { Press = "Primary" },
        })
    end

    if pointer_state.trigger_just_released then
        if not pointer_state.is_long_press then
            world:write_message("PointerInput", {
                pointer_id = pointer_id, location = location,
                action = { Release = "Primary" },
            })
        end
        pointer_state.hold_start_time = nil
        pointer_state.hold_start_pos  = nil
        pointer_state.is_long_press   = false
        pointer_state.long_press_sent = false
    end
end
