-- modules/camera/first_person/client/init.lua
-- Client-side first-person camera.
-- Reuses the base `camera` mod (which spawns the Camera3d child entity and
-- handles activation). This mod registers mouse-look bindings, updates
-- yaw/pitch from mouse motion, and snaps the camera to the player's eye
-- position each frame looking along yaw/pitch.

local BINDINGS = require("modules/camera/first_person/shared/bindings.lua")

local EYE_HEIGHT = 0.7   -- offset above the player entity origin
local LOOK_SENSITIVITY = 0.0025
local PITCH_LIMIT = 1.4  -- radians (~80°)

---------------------------------------------------------------------------
-- Init: register look bindings + first-person camera defaults.
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "camera/first_person" } })) do
        entity:patch({
            input = { camera = BINDINGS },
        })

        -- Spawn a sibling Camera3d entity.
        -- Not parented to the player, so player rotation does not propagate.
        -- CameraPosition writes a world-space Transform each frame.
        local net_info = define_resource("NetInfo", {})
        local camera_registry = define_resource("CameraRegistry", {})
        local is_primary = (net_info.port == 5001)

        local cam_child = spawn({
            Camera3d = {},
            Camera = {
                order = (net_info.port - 5001) + 1,
                is_active = is_primary,
            },
            Transform = {},
            IsDefaultUiCamera = is_primary and {} or nil,
        })

        -- Register in CameraRegistry so portal client can find this camera
        local cam_entity_id = cam_child:id()
        if net_info.scope_key then
            camera_registry[net_info.scope_key] = cam_entity_id
        end

        -- Store camera entity id for base and positioning
        entity:patch({ camera = { camera_entity = cam_entity_id } })

        print(string.format("[CAMERA/FIRST_PERSON] Initialized for entity %d", entity:id()))
    end
end, { after = { "CameraInit" } })

---------------------------------------------------------------------------
-- Mouse look: update yaw/pitch from accumulated mouse motion.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local cameras = world:query({
        with = { "camera", "camera/first_person" },
        changed = { "input_camera" },
    })
    for _, cam_entity in ipairs(cameras) do
        local cam = cam_entity:get("camera")
        local cam_input = cam_entity:get("input_camera")
        if not cam_input then goto continue end

        local look = cam_input.look
        if look and (look.dx ~= 0 or look.dy ~= 0) then
            local yaw = (cam.yaw or 0) - look.dx * LOOK_SENSITIVITY
            local pitch = (cam.pitch or 0) - look.dy * LOOK_SENSITIVITY
            if pitch < -PITCH_LIMIT then pitch = -PITCH_LIMIT end
            if pitch > PITCH_LIMIT then pitch = PITCH_LIMIT end
            cam_entity:patch({ camera = { yaw = yaw, pitch = pitch } })
        end

        ::continue::
    end
end, { label = "Camera", after = { "Input" } })

---------------------------------------------------------------------------
-- Positioning: snap the Camera3d child to the player's eyes, looking along
-- the yaw/pitch direction.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local cameras = world:query({
        with = { "camera", "camera/first_person", "Transform" },
    })
    for _, cam_entity in ipairs(cameras) do
        local cam = cam_entity:get("camera")
        local cam_child_id = cam.camera_entity
        if not cam_child_id then goto continue end

        local yaw = cam.yaw or 0
        local pitch = cam.pitch or 0
        local height = cam.height or EYE_HEIGHT

        local t = cam_entity:get("Transform")
        local px = (t and t.translation and t.translation.x) or 0
        local py = (t and t.translation and t.translation.y) or 0
        local pz = (t and t.translation and t.translation.z) or 0

        -- Forward direction consistent with movement (forward key = -Z rotated by yaw).
        local cp = math.cos(pitch)
        local fwd = {
            x = -math.sin(yaw) * cp,
            y = math.sin(pitch),
            z = -math.cos(yaw) * cp,
        }

        local eye = { x = px, y = py + height, z = pz }
        local target = { x = eye.x + fwd.x, y = eye.y + fwd.y, z = eye.z + fwd.z }

        world:call_component_method(cam_child_id, "Transform", "with_translation", eye)
        world:call_component_method(cam_child_id, "Transform", "looking_at",
            target, { x = 0, y = 1, z = 0 })

        ::continue::
    end
end, { label = "CameraPosition", after = { "Camera", "Movement" } })

return { base = "camera" }
