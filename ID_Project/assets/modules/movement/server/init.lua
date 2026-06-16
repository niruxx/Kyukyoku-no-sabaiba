-- modules/movement/server/init.lua
-- Server-authoritative movement: reads input_movement + camera.yaw, applies Rapier physics.
-- Uses shared movement computation for velocity + rotation.

local BINDINGS = require("modules/movement/shared/bindings.lua")
local Movement = require("modules/movement/shared/movement.lua")

---------------------------------------------------------------------------
-- Detect VR mode by checking for VrButtonState resource.
---------------------------------------------------------------------------
local function is_vr_mode(world)
    local vr = world:get_resource("VrButtonState")
    return vr ~= nil
end

-- Module-level accumulated time (reset-safe; only used for jump cooldown)
local server_time = 0

---------------------------------------------------------------------------
-- Init: register bindings, set net_sync authority, ensure physics components
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "movement" } })
    for _, entity in ipairs(entities) do
        -- Register movement bindings (server-side validation whitelist)
        entity:patch({
            input = { movement = BINDINGS },
            net_sync = {
                input_movement = { authority = "client" },
            }
        })

        -- Read config overrides
        local cfg = entity:get("movement") or {}
        local speed = cfg.speed or Movement.MOVE_SPEED
        local jump_force = cfg.jump_force or Movement.JUMP_FORCE

        entity:patch({ movement = {
            speed = speed,
            jump_force = jump_force,
            grounded = false,
            last_jump_time = 0,
        }})

        -- Ensure Velocity3d exists (peer-spawned mirrors may lack it
        -- since it's not in net_sync and Avian may not auto-create it)
        if not entity:has("Velocity3d") then
            entity:set({ Velocity3d = { linvel = { x = 0, y = 0, z = 0 }, angvel = { x = 0, y = 0, z = 0 } } })
        end

        print(string.format("[MOVEMENT/SERVER] Initialized for entity %d (speed=%s)",
            entity:id(), tostring(speed)))
    end
end)

---------------------------------------------------------------------------
-- Movement system: apply velocity from input_movement, use camera.yaw for direction
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    server_time = server_time + dt

    local entities = world:query({
        with = { "input_movement", "movement", "Velocity3d", "Transform", "camera" },
        without = { "net_peer_mirror" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv = entity:get("movement")
        local cam = entity:get("camera")

        local speed = mv.speed or Movement.MOVE_SPEED
        local camera_yaw = cam.yaw or 0
        local jump_force = mv.jump_force or Movement.JUMP_FORCE

        -- Compute desired velocity (shared with client)
        local desired = Movement.compute_velocity(world, input, camera_yaw, speed)

        -- Read current velocity to preserve Y (gravity)
        local cur_vel = entity:get("Velocity3d")
        local cur_y = cur_vel and cur_vel.linvel and cur_vel.linvel.y or 0

        -- Set horizontal velocity, preserving gravity Y
        entity:set({ Velocity3d = { linvel = {
            x = desired.x,
            y = cur_y,
            z = desired.z,
        }}})

        -- Jump: use rapier raycast for grounded check
        local is_grounded = Movement.is_grounded(world, entity, mv, server_time)
        if input.jump and is_grounded then
            -- Apply jump as a direct velocity change (more reliable than impulse
            -- for character controllers — impulse depends on mass and can be
            -- consumed over multiple substeps)
            entity:set({ Velocity3d = { linvel = {
                x = desired.x,
                y = jump_force,
                z = desired.z,
            }}})
            -- Record jump time for cooldown
            entity:patch({ movement = { last_jump_time = server_time } })
        end

        -- Update grounded state
        if mv.grounded ~= is_grounded then
            entity:patch({ movement = { grounded = is_grounded } })
        end

        ::continue::
    end
end, { label = "Movement", after = { "CameraPosition" } })

---------------------------------------------------------------------------
-- Rotation system: slerp toward horizontal velocity direction every frame.
-- Decoupled from input changes so the slerp can complete while the player
-- holds a movement key without touching the camera.
-- VR mode: rotates toward camera.yaw (HMD direction) instead of velocity,
-- so strafing doesn't spin the model.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "movement", "camera", "Velocity3d", "Transform" },
    })
    for _, entity in ipairs(entities) do
        local mv = entity:get("movement")
        local target_rot = nil

        if is_vr_mode(world) then
            -- VR mode: rotate model toward camera yaw (HMD look direction)
            -- Add π because model default forward is +Z but camera faces -Z
            local cam = entity:get("camera")
            local yaw = cam and cam.yaw
            if yaw then
                target_rot = world:call_static_method("Quat", "from_rotation_y", yaw + math.pi)
            end
        else
            -- Desktop mode: rotate toward velocity direction
            local vel = entity:get("Velocity3d")
            if not vel or not vel.linvel then goto continue end
            target_rot = Movement.compute_rotation(world, vel.linvel.x or 0, vel.linvel.z or 0)
        end

        if target_rot then
            local cur = entity:get("Transform")
            if cur and cur.rotation then
                local new_rot = world:call_static_method("Quat", "slerp",
                    cur.rotation, target_rot, dt * Movement.ROT_SPEED)
                entity:patch({ Transform = { rotation = new_rot } })
            end
        end

        ::continue::
    end
end, { label = "MovementRotation", after = { "Movement" } })
