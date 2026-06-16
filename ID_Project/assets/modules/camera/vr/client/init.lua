-- modules/camera/vr/client/init.lua
-- VR camera: finds the XR-managed Camera3d (spawned by bevy_mod_openxr).
-- Positions the XR tracking root at the player entity.
-- Applies right-stick smooth turn by rotating the tracking root.
-- Sets camera.yaw for movement direction (based on movement_direction setting).
-- Does NOT spawn its own Camera3d — OpenXR provides it.

local json = require "modules/dkjson.lua"

local SMOOTH_TURN_SPEED = 2.0  -- radians/sec at full stick deflection
local STICK_DEADZONE    = 0.15

-- Persistent accumulated turn from right stick (survives across frames)
local vr_cam_state = define_resource("VrCameraState", {
    stick_yaw = 0,  -- accumulated right-stick rotation in radians
})

---------------------------------------------------------------------------
-- Init: find XR Camera3d, register in CameraRegistry
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "camera/vr" }, with = { "ScopeWorld" } })
    for _, entity in ipairs(entities) do
        -- Find the XR-managed Camera3d entity (spawned by bevy_mod_openxr)
        local xr_cameras = world:query({ with = { "Camera3d", "Transform" } })
        local cam_entity_id = nil

        if #xr_cameras > 0 then
            cam_entity_id = xr_cameras[1]:id()
            xr_cameras[1]:patch({
                IsDefaultUiCamera = {},
                ScopeWorld = entity:get("ScopeWorld"),
            })
            print(string.format("[CAMERA/VR/CLIENT] Using XR camera entity %d", cam_entity_id))
            print(json.encode(entity:get("ScopeWorld")))
        else
            print("[CAMERA/VR/CLIENT] WARNING - no XR Camera3d found yet")
        end

        -- Register in CameraRegistry
        if cam_entity_id then
            local net_info = define_resource("NetInfo", {})
            local camera_registry = define_resource("CameraRegistry", {})
            if net_info.scope_key then
                camera_registry[net_info.scope_key] = cam_entity_id
            end
            entity:patch({ camera = { camera_entity = cam_entity_id } })
        end
    end
end)

---------------------------------------------------------------------------
-- Camera yaw + tracking root positioning.
-- 1. Apply right-stick smooth turn (accumulates in vr_cam_state.stick_yaw).
-- 2. Position tracking root at player's world position + stick rotation.
-- 3. Compute camera.yaw for movement direction:
--      "head" mode: yaw = HMD look direction (hmd_forward)
--      "body" mode: yaw = stick rotation only (default)
-- Runs BEFORE Movement so movement uses the correct forward direction.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local cameras = world:query({
        with = { "camera", "camera/vr", "Transform" },
    })
    if #cameras == 0 then return end

    -- Read VR button state for thumbstick
    local vr_btns = world:get_resource("VrButtonState")
    -- Read VR controller state for HMD orientation
    local vr_ctrl = world:get_resource("VrControllerState")

    -- Find XR tracking root
    local tracking_roots = world:query({ with = { "XrTrackingRoot", "Transform" } })

    -- Read VR settings for movement direction mode
    local vr_settings = define_resource("VrSettings", {})
    local move_dir = vr_settings.movement_direction or "head"

    -- 1. Accumulate right-stick smooth turn
    if vr_btns then
        local stick_x = vr_btns.right_thumbstick_x or 0
        if math.abs(stick_x) > STICK_DEADZONE then
            -- Positive stick_x = turn right → negative yaw (clockwise in Bevy Y-up)
            vr_cam_state.stick_yaw = vr_cam_state.stick_yaw - stick_x * SMOOTH_TURN_SPEED * dt
        end
    end

    for _, cam_entity in ipairs(cameras) do
        local cam = cam_entity:get("camera")
        local player_t = cam_entity:get("Transform")
        if not cam or not player_t or not player_t.translation then goto continue end

        local px = player_t.translation.x or 0
        local py = player_t.translation.y or 0
        local pz = player_t.translation.z or 0
        local height = -0.5

        -- 2. Apply tracking root transform: position + smooth turn rotation
        if #tracking_roots > 0 then
            local root = tracking_roots[1]
            local rot = world:call_static_method("Quat", "from_rotation_y", vr_cam_state.stick_yaw)
            root:set({ Transform = {
                translation = { x = px, y = py + height, z = pz },
                rotation = rot,
            }})
        end

        -- 3. Compute camera.yaw for movement direction
        local yaw = vr_cam_state.stick_yaw  -- default: body direction (stick only)

        if move_dir == "head" and vr_ctrl then
            -- "head" mode: use full HMD forward direction (includes physical head turn)
            -- Negate both args: atan2(fwd.x, fwd.z) gives π for -Z, but
            -- compute_velocity expects 0 for -Z (Bevy forward). Negating both
            -- args shifts by π to match the movement convention.
            local fwd = vr_ctrl.hmd_forward
            if fwd and (math.abs(fwd.x) > 0.001 or math.abs(fwd.z) > 0.001) then
                yaw = math.atan2(-fwd.x, -fwd.z)
            end
        end

        cam_entity:patch({ camera = { yaw = yaw } })

        ::continue::
    end
end, { label = "CameraPosition", before = { "Movement" }, after = { "CameraInit" } })

return { base = "camera" }
