-- modules/movement/server/init.lua
-- Server-authoritative movement: reads input_movement + camera.yaw, applies Rapier physics.
-- Uses shared movement computation for velocity + rotation.

local BINDINGS = require("modules/movement/shared/bindings.lua")
local Movement = require("modules/movement/shared/movement.lua")

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
    local entities = world:query({
        with = { "input_movement", "movement/2d", "Velocity2d", "camera/2d" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv = entity:get("movement/2d")
        if not input or not mv then goto continue end

        local speed = mv.speed or Movement.MOVE_SPEED
        local moving = input.forward or input.backward or input.left or input.right
        local desired = moving and Movement.compute_velocity2d(input, speed) or { x = 0, y = 0 }
        local cur_vel = entity:get("Velocity2d") or {}
        local linvel = cur_vel.linvel or {}

        local dx = desired.x - (linvel.x or 0)
        local dy = desired.y - (linvel.y or 0)
        local angular = cur_vel.angvel or 0
        if math.abs(dx) > 0.001 or math.abs(dy) > 0.001 or math.abs(angular) > 0.001 then
            entity:set({ Velocity2d = {
                linvel = { x = desired.x, y = desired.y },
                angvel = 0,
            }})
        end
        
        ::continue::
    end
end, { label = "Movement", after = { "Input" } })