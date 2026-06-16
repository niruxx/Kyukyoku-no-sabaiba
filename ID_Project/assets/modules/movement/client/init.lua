-- modules/movement/client/init.lua
-- Client-side movement: mirrors the server movement logic exactly.
-- Both client and server run Rapier physics (gravity, collision, ground detection).
-- The client writes Velocity3d from input; Rapier integrates it into Transform.
-- The net prediction layer (predict.lua) handles reconciliation toward server
-- snapshots — it does NOT integrate velocity (Rapier does that).
-- Remote avatars are interpolated toward the server snapshot here.

local BINDINGS = require("modules/movement/shared/bindings.lua")
local Movement = require("modules/movement/shared/movement.lua")
local INTERP_SPEED = 10.0

-- Module-level accumulated time (for jump cooldown; mirrors server_time)
local client_time = 0

---------------------------------------------------------------------------
-- Detect VR mode by checking for VrButtonState resource.
---------------------------------------------------------------------------
local function is_vr_mode(world)
    local vr = world:get_resource("VrButtonState")
    return vr ~= nil
end

---------------------------------------------------------------------------
-- Init: register movement bindings + interpolation shadow.
-- Rapier stays active on the client — same physics as server.
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        ["or"] = { added = { "movement", "net_local" } },
        with = { "Transform", "movement" },
        optional = { "net_local" },
    })
    for _, entity in ipairs(entities) do
        -- Register movement bindings on the input component
        entity:patch({ input = { movement = BINDINGS } })

        -- Set up interpolation shadow
        entity:set({ net_sync_Transform = entity:get("Transform") })

        -- Init jump tracking on client side
        entity:patch({ movement = { last_jump_time = 0 } })

        print(string.format("[MOVEMENT/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Produce the local player's intended velocity from input.
-- Mirrors server movement logic exactly. Rapier handles gravity, collision,
-- and ground detection — same physics on both sides.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    client_time = client_time + dt

    local entities = world:query({
        with = { "input_movement", "movement", "Transform", "camera", "net_local" },
        optional = { "Velocity3d" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv = entity:get("movement")
        local cam = entity:get("camera")
        local t = entity:get("Transform")

        local speed = mv.speed or Movement.MOVE_SPEED
        local camera_yaw = cam.yaw or 0
        local jump_force = mv.jump_force or Movement.JUMP_FORCE

        -- Compute horizontal velocity (shared with server)
        local desired = Movement.compute_velocity(world, input, camera_yaw, speed)

        -- Read current velocity to preserve Y (gravity)
        local cur_vel = entity:get("Velocity3d") or { linvel = { x = 0, y = 0, z = 0 }}
        local cur_y = cur_vel.linvel and cur_vel.linvel.y or 0

        -- Set horizontal velocity, preserving Rapier's gravity Y
        entity:set({ Velocity3d = { linvel = {
            x = desired.x,
            y = cur_y,
            z = desired.z,
        }}})

        -- Jump: use raycast for grounded check (same as server)
        local is_grounded = Movement.is_grounded(world, entity, mv, client_time)
        if input.jump and is_grounded then
            entity:set({ Velocity3d = { linvel = {
                x = desired.x,
                y = jump_force,
                z = desired.z,
            }}})
            entity:patch({ movement = { last_jump_time = client_time } })
        end

        -- Update grounded state (for local use)
        if mv.grounded ~= is_grounded then
            entity:patch({ movement = { grounded = is_grounded } })
        end

        -- Rotation
        local target_rot = nil
        if is_vr_mode(world) then
            target_rot = world:call_static_method("Quat", "from_rotation_y", cam.yaw + math.pi)
        else
            target_rot = Movement.compute_rotation(world, desired.x, desired.z)
        end

        if target_rot and t and t.rotation then
            local new_rot = world:call_static_method("Quat", "slerp",
                t.rotation, target_rot, dt * Movement.ROT_SPEED)
            entity:patch({ Transform = { rotation = new_rot } })
        end

        ::continue::
    end
end, { label = "Movement", after = { "Input" } })

---------------------------------------------------------------------------
-- Interpolation for REMOTE avatars (not net_local): lerp/slerp toward the
-- server-authoritative net_sync_Transform. The local player is driven by the
-- net predict layer instead, so it is excluded here.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "movement", "net_sync_Transform", "Transform" },
        without = { "net_local" },
    })
    for _, entity in ipairs(entities) do
        local net_transform = entity:get("net_sync_Transform")
        local current = entity:get("Transform")
        if not net_transform or not current then goto continue end

        local t = math.min(1.0, INTERP_SPEED * dt)

        -- Lerp translation toward server position
        if net_transform.translation and current.translation then
            local new_pos = world:call_static_method("Vec3", "lerp",
                current.translation, net_transform.translation, t)
            entity:patch({ Transform = { translation = new_pos } })
        end

        -- Slerp rotation toward server rotation
        if net_transform.rotation and current.rotation then
            local new_rot = world:call_static_method("Quat", "slerp",
                current.rotation, net_transform.rotation, t)
            entity:patch({ Transform = { rotation = new_rot } })
        end

        ::continue::
    end
end, { label = "MovementInterpolation", after = { "Movement" } })
