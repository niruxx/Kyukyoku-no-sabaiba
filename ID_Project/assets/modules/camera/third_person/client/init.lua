-- modules/camera/third_person/client/init.lua
-- Client-side third-person orbit camera.
-- Spawns a sibling Camera3d entity, registers mouse motion/scroll bindings,
-- reads deltas from input.camera. Updates camera.yaw/pitch/distance.

local BINDINGS = require("modules/camera/third_person/shared/bindings.lua")

---------------------------------------------------------------------------
-- Init: spawn Camera3d + register bindings
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "camera/third_person" } })
    for _, entity in ipairs(entities) do
        -- Register camera bindings (local-only, no sync output)
        entity:patch({ input = { camera = BINDINGS } })

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

        print(string.format("[CAMERA/THIRD_PERSON/CLIENT] Spawned Camera3d=%d, registered bindings for entity %d",
            cam_entity_id, entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Mouse input: update yaw/pitch/distance from input_camera deltas
---------------------------------------------------------------------------
register_system("Update", function(world)
    local net_info = define_resource("NetInfo", {})
    local my_scope_key = net_info.scope_key

    local cameras = world:query({
        with = { "camera", "camera/third_person" },
        changed = { "input_camera" },
    })
    for _, cam_entity in ipairs(cameras) do
        local cam = cam_entity:get("camera")
        local cam_input = cam_entity:get("input_camera")
        if not cam_input then goto continue end

        local yaw = cam.yaw or 0
        local pitch = cam.pitch or -0.3

        -- Read mouse delta from input_camera.look
        local look = cam_input.look
        if look and (look.dx ~= 0 or look.dy ~= 0) then
            yaw = yaw - look.dx * 0.003
            pitch = pitch - look.dy * 0.003

            -- Clamp pitch to avoid flipping
            if pitch < -1.2 then pitch = -1.2 end
            if pitch > 0.2 then pitch = 0.2 end

            cam_entity:patch({ camera = { yaw = yaw, pitch = pitch } })
        end

        -- Read scroll wheel for distance from input_camera.zoom
        local zoom = cam_input.zoom
        if zoom and zoom.dy ~= 0 then
            local distance = cam.distance or 8.0
            distance = distance - zoom.dy * 0.5
            if distance < 2.0 then distance = 2.0 end
            if distance > 20.0 then distance = 20.0 end
            cam_entity:patch({ camera = { distance = distance } })
        end

        ::continue::
    end
end, { label = "Camera", after = { "Input" } })

---------------------------------------------------------------------------
-- Camera positioning: orbit behind the player using child camera entity
---------------------------------------------------------------------------
register_system("Update", function(world)
    local net_info = define_resource("NetInfo", {})
    local my_scope_key = net_info.scope_key
    
    local cameras = world:query({
        with = { "camera", "camera/third_person", "input", "Transform" },
    })
    for _, cam_entity in ipairs(cameras) do
        local cam = cam_entity:get("camera")
        local input = cam_entity:get("input")

        -- Get the child camera entity (spawned by this mod's init)
        local camera_child_id = cam.camera_entity
        if not camera_child_id then goto continue end

        local offset = cam.offset or { x = 0, y = 0, z = 0 }
        local height = cam.height or 1.5
        local distance = cam.distance or 8.0
        local yaw = cam.yaw or 0
        local pitch = cam.pitch or -0.3

        -- Offset rotated by yaw
        local cos_y = math.cos(yaw)
        local sin_y = math.sin(yaw)
        local ox = offset.x * cos_y + offset.z * sin_y
        local oy = offset.y
        local oz = -offset.x * sin_y + offset.z * cos_y

        -- Read player world position (camera is no longer a child entity)
        local player_t = cam_entity:get("Transform")
        local px = (player_t and player_t.translation and player_t.translation.x) or 0
        local py = (player_t and player_t.translation and player_t.translation.y) or 0
        local pz = (player_t and player_t.translation and player_t.translation.z) or 0

        -- Orbit position in world space
        local position = {
            x = px + distance * math.cos(pitch) * math.sin(yaw) + ox,
            y = py + height - distance * math.sin(pitch) + oy,
            z = pz + distance * math.cos(pitch) * math.cos(yaw) + oz,
        }
        local target = { x = px + ox, y = py + height + oy, z = pz + oz }

        world:call_component_method(camera_child_id, "Transform", "with_translation", position)
        world:call_component_method(camera_child_id, "Transform", "looking_at",
            target, { x = 0, y = 1, z = 0 })

        ::continue::
    end
end, { label = "CameraPosition", after = { "Camera", "Movement" } })

return { base = "camera" }
