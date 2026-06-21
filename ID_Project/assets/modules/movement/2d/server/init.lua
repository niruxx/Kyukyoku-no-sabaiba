-- modules/movement/server/init.lua
-- Server-authoritative movement: reads input_movement + camera.yaw, applies Rapier physics.
-- Uses shared movement computation for velocity + rotation.

local BINDINGS = require("modules/movement/shared/bindings.lua")
local Movement = require("modules/movement/shared/movement.lua")

local state = define_resource("Movement2dServerState", {
    vel = {},     -- [entity_id] -> { x, y }
})

---------------------------------------------------------------------------
-- Init: register bindings, set net_sync authority, ensure physics components
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "movement/2d" } })
    for _, entity in ipairs(entities) do
        -- Register movement bindings (server-side validation whitelist)
        entity:patch({
            input = { movement = BINDINGS },
            net_sync = {
                input_movement = { authority = "client" },
            }
        })

        -- Read config overrides
        local cfg = entity:get("movement/2d") or {}
        local speed = cfg.speed or Movement.MOVE_SPEED
        local jump_force = cfg.jump_force or Movement.JUMP_FORCE

        entity:patch({ movement = {
            speed = speed,
            jump_force = jump_force,
            grounded = false,
        }})
        if entity:has("camera/2d") then
            entity:patch({ Transform = { rotation = { x = 0, y = 0, z = 0, w = 1 } } })
        end

        print(string.format("[MOVEMENT/SERVER] Initialized for entity %d (speed=%s)",
            entity:id(), tostring(speed)))
    end
end)

---------------------------------------------------------------------------
-- Movement system: apply velocity from input_movement, use camera.yaw for direction
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt      = world:delta_time()
    local entities = world:query({
        with = { "input_movement", "movement/2d", "camera/2d", "Transform" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv    = entity:get("movement/2d")
        if not input or not mv then goto continue end

        local speed   = mv.speed or Movement.MOVE_SPEED
        if input.sprint then speed = speed * 1.45 end
        local moving  = input.forward or input.backward or input.left or input.right
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