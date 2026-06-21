-- modules/movement/2d/client/init.lua
-- Client-side movement: mirrors the server movement logic exactly.
-- Both client and server run physics (Velocity2d integration into Transform).
-- The client writes Velocity2d from input; physics integrates it into Transform.
-- Remote avatars are interpolated toward the server snapshot here.

local BINDINGS     = require("modules/movement/shared/bindings.lua")
local Movement     = require("modules/movement/shared/movement.lua")

local INTERP_SPEED = 16.0   -- lerp fraction/sec for server-position correction

local state = define_resource("Movement2dClientState", {
    vel = {},     -- [entity_id] -> { x, y }
})

local function has_movement_input(input)
    return input and (input.forward or input.backward or input.left or input.right)
end

---------------------------------------------------------------------------
-- Init: register movement bindings + set up interpolation shadow
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        ["or"] = { added = { "movement/2d", "net_local" } },
        with   = { "Transform", "movement/2d" },
    })
    for _, entity in ipairs(entities) do
        entity:patch({
            input     = { movement = BINDINGS },
            Transform = { rotation = { x = 0, y = 0, z = 0, w = 1 } },
        })
        entity:set({ net_sync_Transform = entity:get("Transform") })

        print(string.format("[MOVEMENT/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Produce the local player's intended velocity from input.
-- Mirrors server movement logic exactly (shared smoothing function) so
-- physics integrates Velocity2d into Transform the same way on both sides.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "input_movement", "movement/2d", "Transform", "camera/2d" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv    = entity:get("movement/2d")
        if not input or not mv then goto continue end

        local speed   = mv.speed or Movement.MOVE_SPEED
        if input.sprint then speed = speed * 1.45 end
        local moving  = has_movement_input(input)
        local desired = moving and Movement.compute_velocity2d(input, speed) or { x = 0, y = 0 }

        local eid = entity:id()
        local pv  = state.vel[eid] or { x = 0, y = 0 }
        local new_vel = Movement.smooth_velocity2d(pv, desired, dt)
        state.vel[eid] = new_vel

        local t = entity:get("Transform")
        if t and t.translation then
            entity:patch({ Transform = { translation = {
                x = t.translation.x + new_vel.x * dt,
                y = t.translation.y + new_vel.y * dt,
                z = t.translation.z,
            }}})
        end

        -- Publish velocity for other systems (e.g. sprite animation facing/state)
        -- to read. Not used for movement integration itself anymore.
        entity:set({ Velocity2d = { linvel = { x = new_vel.x, y = new_vel.y }, angvel = 0 } })

        ::continue::
    end
end, { label = "Movement", after = { "Input" } })

---------------------------------------------------------------------------
-- Interpolation for REMOTE avatars (not net_local): lerp toward the
-- server-authoritative net_sync_Transform. The local player is driven by
-- its own prediction above, so it is excluded here (matches 3D movement).
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    local t  = math.min(1.0, INTERP_SPEED * dt)

    local entities = world:query({
        with    = { "movement/2d", "net_sync_Transform", "Transform" },
        without = { "net_local" },
    })
    for _, entity in ipairs(entities) do
        local net_transform = entity:get("net_sync_Transform")
        local current       = entity:get("Transform")
        if not net_transform or not current then goto continue end

        if net_transform.translation and current.translation then
            local new_pos = world:call_static_method("Vec3", "lerp",
                current.translation, net_transform.translation, t)
            entity:patch({ Transform = { translation = new_pos } })
        end

        if net_transform.rotation and current.rotation and not entity:has("camera/2d") then
            local new_rot = world:call_static_method("Quat", "slerp",
                current.rotation, net_transform.rotation, t)
            entity:patch({ Transform = { rotation = new_rot } })
        end

        ::continue::
    end
end, { label = "MovementInterpolation", after = { "Movement" } })
