-- modules/camera/client/init.lua
-- Client-side camera base: manages camera defaults and activation.
-- Does NOT spawn Camera3d — sub-mods handle that:
--   camera/third_person → spawns Camera3d for orbit mode
--   camera/vr           → finds XR Camera3d from bevy_mod_openxr
-- Supports cross-scope transfer and CameraActivation for portal crossing.

---------------------------------------------------------------------------
-- CameraInit: set camera defaults from transfer or defaults
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({
        added = { "camera" },
        optional = { "net_transfer", "net_local" },
    })) do
        -- Check for transferred camera state
        local cfg = entity:get("camera")

        -- Set camera state — use transfer/existing data, or defaults
        entity:patch({ camera = cfg.yaw ~= nil and cfg or {
            yaw = 0,
            pitch = -0.3,
            distance = 8.0,
            height = 1.5,
            offset = { x = 1.0, y = 0, z = 0 },
        }})
    end
end, { label = "CameraInit" })

-- NOTE: Camera transfer sync (net_transfer → camera) is in camera/shared/init.lua
-- so it runs on both server and client (mirrors need updated camera data).

---------------------------------------------------------------------------
-- CameraActivation: activate/deactivate the Camera3d entity
-- when the player gains or loses net_local (portal crossing, authority switch).
--
-- Uses cam.camera_entity (set by sub-mods) to find the right Camera3d.
-- Falls back to CameraRegistry[scope_key] if camera_entity isn't set yet.
---------------------------------------------------------------------------
register_system("First", function(world)
    local net_info = define_resource("NetInfo", {})
    local camera_registry = define_resource("CameraRegistry", {})

    -- Detect when a camera entity gains net_local (authority switch IN)
    -- OR when camera component is added/changed on an entity with net_local
    local gained = world:query({
        ["or"] = { added = { "net_local" }, changed = { "camera" } },
        with = { "camera", "net_local" },
    })
    for _, entity in ipairs(gained) do
        local cam = entity:get("camera")

        -- Find the Camera3d entity for this player
        local cam_eid = cam and cam.camera_entity
        if not cam_eid and net_info.scope_key then
            cam_eid = camera_registry[net_info.scope_key]
        end
        if not cam_eid then goto skip_gained end

        local cam_entity = world:get_entity(cam_eid)
        if not cam_entity then goto skip_gained end

        -- Already active? Skip.
        local cam_comp = cam_entity:get("Camera")
        if cam_comp and cam_comp.is_active then goto skip_gained end

        -- Activate this camera
        cam_entity:patch({ Camera = { is_active = true }, IsDefaultUiCamera = true })
        print(string.format("[CAMERA/CLIENT] Activated camera entity %d (player gained net_local)", cam_eid))

        -- Deactivate all OTHER Camera3d entities in the registry
        for scope_key, other_cam_eid in pairs(camera_registry) do
            if other_cam_eid ~= cam_eid then
                local other = world:get_entity(other_cam_eid)
                if other then
                    other:patch({ Camera = { is_active = false }, IsDefaultUiCamera = false })
                end
            end
        end

        ::skip_gained::
    end

    -- Detect when a camera entity loses net_local (authority switch AWAY)
    local lost = world:query({
        removed = { "net_local" },
        with = { "camera" },
    })
    for _, entity in ipairs(lost) do
        local cam = entity:get("camera")
        local cam_eid = cam and cam.camera_entity
        if not cam_eid and net_info.scope_key then
            cam_eid = camera_registry[net_info.scope_key]
        end
        if not cam_eid then goto skip_lost end

        local cam_entity = world:get_entity(cam_eid)
        if cam_entity then
            cam_entity:patch({ Camera = { is_active = false }, IsDefaultUiCamera = false })
            print(string.format("[CAMERA/CLIENT] Deactivated camera entity %d (player lost net_local)", cam_eid))
        end

        ::skip_lost::
    end
end, { label = "CameraActivation", after = { "NetLocalMarker", "CameraInit" } })
