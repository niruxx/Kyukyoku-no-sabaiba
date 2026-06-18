-- modules/movement/2d/client/init.lua
-- Client-side movement: registers input bindings, runs smoothed local prediction,
-- and interpolates toward server-authoritative Transform.

local BINDINGS     = require("modules/movement/shared/bindings.lua")
local Movement     = require("modules/movement/shared/movement.lua")

local CLIENT_ACCEL = 16.0   -- lerp fraction/sec when accelerating (client prediction)
local CLIENT_DECEL = 22.0   -- lerp fraction/sec when decelerating (client prediction)
local INTERP_SPEED = 16.0   -- lerp fraction/sec for server-position correction

-- Per-entity predicted velocity (module-local, never synced)
local pred_vels = {}   -- [entity_id] → { vx, vy }

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
-- Client-side prediction: smoothed acceleration matching the server rates
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
        local moving  = has_movement_input(input)
        local desired = moving and Movement.compute_velocity2d(input, speed) or { x = 0, y = 0 }

        local eid = entity:id()
        local pv  = pred_vels[eid] or { vx = 0, vy = 0 }

        local is_moving = math.abs(desired.x) + math.abs(desired.y) > 0.1
        local rate      = is_moving and CLIENT_ACCEL or CLIENT_DECEL
        local t         = math.min(1.0, rate * dt)

        pv.vx = pv.vx + (desired.x - pv.vx) * t
        pv.vy = pv.vy + (desired.y - pv.vy) * t
        pred_vels[eid] = pv

        local tr = entity:get("Transform")
        if tr and tr.translation and (math.abs(pv.vx) + math.abs(pv.vy) > 0.01) then
            entity:patch({ Transform = { translation = {
                x = tr.translation.x + pv.vx * dt,
                y = tr.translation.y + pv.vy * dt,
                z = tr.translation.z,
            }}})
        end

        ::continue::
    end
end, { label = "Movement", after = { "Input" } })

---------------------------------------------------------------------------
-- Interpolation: smoothly blend prediction with server-authoritative position
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    local t  = math.min(1.0, INTERP_SPEED * dt)

    local entities = world:query({
        with = { "movement/2d", "net_sync_Transform", "Transform" },
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
