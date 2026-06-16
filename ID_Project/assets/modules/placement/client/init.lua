-- modules/placement/client/init.lua
-- Client-side placement mod. While `placement` is on the entity (and not yet
-- confirmed), the local owner drives the entity's Transform via a raycast:
-- the mouse ray on desktop, or the VR pointer-hand controller ray in VR.
-- Confirm/cancel are handled by placement/shared via input bindings
-- (left-click / right-trigger to confirm; right-click / Escape / B to cancel).
--
-- Input bindings are registered through the input mod (input_placement).

local Placement = require("modules/placement/shared/init.lua")

local DEFAULT_FOV_DEG = 60

local function get_mouse_ray(world)
    local cameras = world:query({ "Camera3d", "Transform" })
    if #cameras == 0 then return nil end
    local cam = cameras[1]
    local cam_id = cam:id()
    local cam_t = cam:get("Transform")

    local forward = world:call_component_method(cam_id, "Transform", "forward")
    forward = forward and forward[1] or { x = 0, y = 0, z = -1 }
    local right = world:call_component_method(cam_id, "Transform", "right")
    right = right and right[1] or { x = 1, y = 0, z = 0 }
    local up = world:call_component_method(cam_id, "Transform", "up")
    up = up and up[1] or { x = 0, y = 1, z = 0 }

    local windows = world:query({ "Window" })
    if #windows == 0 then return nil end
    local window = windows[1]:get("Window")
    local cursor = window and window.internal and window.internal.physical_cursor_position
    if not cursor or not cursor.Some then return nil end

    local mx, my = cursor.Some.x, cursor.Some.y
    local w = (window.resolution and window.resolution.physical_width) or 1920
    local h = (window.resolution and window.resolution.physical_height) or 1080

    local ndc_x = (mx / w) * 2.0 - 1.0
    local ndc_y = 1.0 - (my / h) * 2.0

    local aspect = w / h
    local tan_half_fov = math.tan(math.rad(DEFAULT_FOV_DEG) / 2.0)
    local x_scale = ndc_x * tan_half_fov * aspect
    local y_scale = ndc_y * tan_half_fov

    local dir = {
        x = forward.x + right.x * x_scale + up.x * y_scale,
        y = forward.y + right.y * x_scale + up.y * y_scale,
        z = forward.z + right.z * x_scale + up.z * y_scale,
    }
    dir = world:call_static_method("Vec3", "normalize", dir) or dir
    return cam_t.translation, dir
end

--- VR controller ray: origin + forward of the pointer-hand controller.
--- Returns nil on desktop (no VrControllerState resource), so callers can
--- fall back to the mouse ray. Mirrors vr/pointer + vr/grabbable.
local function get_vr_ray(world)
    local ctrl = world:get_resource("VrControllerState")
    if not ctrl then return nil end
    local settings = define_resource("VrSettings", {})
    local hand = settings.pointer_hand or "right"
    if hand == "left" then
        return ctrl.left_position, ctrl.left_forward
    else
        return ctrl.right_position, ctrl.right_forward
    end
end

---------------------------------------------------------------------------
-- Init: register placement input bindings
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "placement" } })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { input_mode = "ui" } })
    end
end)

---------------------------------------------------------------------------
-- Update: raycast to track cursor, confirm/cancel via input bindings
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with = {
            "placement", "input_placement", "net_local", "Transform"
        },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_placement")

        local entity_id = entity:id()

        -- Read input state from the input mod

        -- Raycast to update position.
        -- In VR, point with the controller; on desktop, use the mouse ray.
        local origin, direction = get_vr_ray(world)
        if not origin then
            origin, direction = get_mouse_ray(world)
        end
        if not origin then return end
        local result = world:call_systemparam_method("MeshRayCast", "cast_ray", {
            origin = origin,
            direction = direction,
            early_exit = false,
        })

        -- First hit that is NOT the placement entity itself and is not
        -- opted out of pointing via Pickable::IGNORE (is_hoverable == false),
        -- e.g. the VR laser pointer.
        local hit_point = nil
        if result then
            for _, hit in ipairs(result) do
                local hit_eid = hit.entity
                if hit_eid ~= entity_id then
                    local hit_entity = world:get_entity(hit_eid)
                    local pick = hit_entity and hit_entity:get("Pickable")
                    if not (pick and pick.is_hoverable == false) then
                        hit_point = hit.data.point
                        break
                    end
                end
            end
        end

        local last_translation = entity:get("Transform").translation
        if hit_point and (math.abs(hit_point.x - last_translation.x) > 0.00001 or math.abs(hit_point.z - last_translation.z) > 0.00001 or math.abs(hit_point.y - last_translation.y) > 0.00001) then
            entity:patch({ Transform = { translation = hit_point } })
        end

        ::continue::
    end
end, { after = { "Input" } })