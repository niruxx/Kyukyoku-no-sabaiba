-- modules/camera/2d/client/init.lua
-- Client-side top-down 2D follow camera.

local BINDINGS = require("modules/camera/2d/shared/bindings.lua")

---------------------------------------------------------------------------
-- Init: register local bindings, set defaults, spawn Camera2d entity
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({
        added = { "camera/2d" },
        optional = { "net_transfer" },
    })) do
        local cfg = entity:get("camera/2d") or {}

        entity:patch({
            input = { ["camera/2d"] = BINDINGS },
            ["camera/2d"] = {
                zoom = cfg.zoom or 1.0,
                min_zoom = cfg.min_zoom or 0.25,
                max_zoom = cfg.max_zoom or 4.0,
                z = cfg.z or 1000.0,
            },
        })

        local net_info = define_resource("NetInfo", {})
        local port = net_info.port or 5001
        local is_primary = (port == 5001)

        local cam_entity = spawn({
            Camera2d = {},
            Camera = {
                order = (port - 5001) + 1,
                is_active = is_primary,
            },
            Transform = {},
            IsDefaultUiCamera = is_primary and {} or nil,
        })

        entity:patch({ ["camera/2d"] = { camera_entity = cam_entity:id() } })
        print(string.format("[CAMERA2D/CLIENT] Spawned Camera2d %d for entity %d",
            cam_entity:id(), entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Local zoom state from mouse wheel
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, entity in ipairs(world:query({
        with = { "camera/2d" },
        changed = { "input_camera/2d" },
    })) do
        local cam = entity:get("camera/2d")
        local input = entity:get("input_camera/2d")
        if not cam or not input or not input.zoom or input.zoom.dy == 0 then goto continue end

        local zoom = cam.zoom or 1.0
        zoom = zoom - input.zoom.dy * 0.1
        if zoom < (cam.min_zoom or 0.25) then zoom = cam.min_zoom or 0.25 end
        if zoom > (cam.max_zoom or 4.0) then zoom = cam.max_zoom or 4.0 end
        entity:patch({ ["camera/2d"] = { zoom = zoom } })

        ::continue::
    end
end, { label = "Camera2dInput", after = { "Input" } })

---------------------------------------------------------------------------
-- Follow player in the XY plane. Zoom is applied through Transform scale so
-- this stays inside the Lua component surface we already use elsewhere.
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, entity in ipairs(world:query({
        with = { "camera/2d", "Transform" },
    })) do
        local cam = entity:get("camera/2d")
        local player_t = entity:get("Transform")
        if not cam or not cam.camera_entity or not player_t or not player_t.translation then
            goto continue
        end

        local cam_t = {
            translation = {
                x = player_t.translation.x or 0,
                y = player_t.translation.y or 0,
                z = cam.z or 1000.0,
            },
            scale = {
                x = cam.zoom or 1.0,
                y = cam.zoom or 1.0,
                z = 1.0,
            },
        }

        local cam_entity = world:get_entity(cam.camera_entity)
        if cam_entity then
            cam_entity:patch({ Transform = cam_t })
        end

        ::continue::
    end
end, { label = "Camera2dPosition", after = { "MovementInterpolation", "Movement2d" } })
