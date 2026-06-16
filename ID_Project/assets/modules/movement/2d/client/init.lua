-- modules/movement/client/init.lua
-- Client-side movement: registers input bindings, runs local prediction,
-- and interpolates toward server-authoritative Transform.

local BINDINGS = require("modules/movement/shared/bindings.lua")
local Movement = require("modules/movement/shared/movement.lua")
local INTERP_SPEED = 10.0

local function has_movement_input(input)
    return input and (input.forward or input.backward or input.left or input.right)
end

---------------------------------------------------------------------------
-- Init: register movement bindings + set up interpolation shadow
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        ["or"] = { added = { "movement/2d", "net_local" } },
        with = { "Transform", "movement/2d" },
    })
    for _, entity in ipairs(entities) do
        -- Register movement bindings on the input component
        entity:patch({
            input = { movement = BINDINGS },
            Transform = { rotation = { x = 0, y = 0, z = 0, w = 1 } },
        })

        -- Set up interpolation shadow
        entity:set({ net_sync_Transform = entity:get("Transform") })

        print(string.format("[MOVEMENT/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Client-side prediction: apply movement locally for instant response
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "input_movement", "movement/2d", "Transform", "camera/2d" },
    })
    for _, entity in ipairs(entities) do
        local input = entity:get("input_movement")
        local mv = entity:get("movement/2d")
        if not input or not mv then goto continue end

        local speed = mv.speed or Movement.MOVE_SPEED
        local moving = has_movement_input(input)
        local vel = moving and Movement.compute_velocity2d(input, speed) or { x = 0, y = 0 }

        local t = entity:get("Transform")
        if moving and t and t.translation then
            entity:patch({ Transform = { translation = {
                x = t.translation.x + vel.x * dt,
                y = t.translation.y + vel.y * dt,
                z = t.translation.z,
            }}})
        end

        ::continue::
    end
end, { label = "Movement", after = { "Input" } })

---------------------------------------------------------------------------
-- Interpolation: lerp/slerp toward server-authoritative net_sync_Transform.
-- Blends prediction with server corrections so the player doesn't teleport.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "movement/2d", "net_sync_Transform", "Transform" },
    })
    for _, entity in ipairs(entities) do
        local net_transform = entity:get("net_sync_Transform")
        local current = entity:get("Transform")
        if not net_transform or not current then goto continue end

        local t = math.min(1.0, INTERP_SPEED * dt)

        -- Lerp translation toward server position
        if net_transform.translation and current.translation then
            local input = entity:get("input_movement")
            local snap_2d_idle = entity:has("camera/2d") and not has_movement_input(input)
            local new_pos = snap_2d_idle and net_transform.translation
                or world:call_static_method("Vec3", "lerp",
                    current.translation, net_transform.translation, t)
            entity:patch({ Transform = { translation = new_pos } })
        end

        -- Slerp rotation toward server rotation
        if net_transform.rotation and current.rotation and not entity:has("camera/2d") then
            local new_rot = world:call_static_method("Quat", "slerp",
                current.rotation, net_transform.rotation, t)
            entity:patch({ Transform = { rotation = new_rot } })
        end

        ::continue::
    end
end, { label = "MovementInterpolation", after = { "Movement" } })
