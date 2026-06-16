-- modules/vr/grabbable/client/init.lua
-- VR Grabbable: grip-to-move any entity with a vr_grabbable component.
-- Loaded on the player entity by the VR orchestrator.
-- Uses input bindings for grip detection and MeshRayCast to find targets.
--
-- Technique: ray-projection grab (like the old vr_ui_v2.lua).
-- On grab start, store the distance from controller to hit point and
-- the offset from hit point to entity center. While held, project the
-- controller's ray forward by that distance, then add the offset.
-- This makes the panel follow the aim direction naturally.
--
-- Usage: Add { vr_grabbable = { lock_rotation = true } } to any entity
-- with a Transform + Mesh3d to make it grabbable.

local BINDINGS = require("modules/vr/grabbable/shared/bindings.lua")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local grab_state = define_resource("VrGrabState", {
    grabbed_entity = nil,   -- entity id (number) of grabbed entity
    distance       = nil,   -- distance from controller to hit point at grab start
    offset         = nil,   -- {x, y, z} from hit point to entity center
    lock_rotation  = true,  -- from vr_grabbable at grab start
    was_pressed    = false, -- edge detection for grip
})

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Get pointer hand's position, forward, and rotation from VrControllerState
local function get_pointer_controller(world)
    local settings = define_resource("VrSettings", {})
    local hand = settings.pointer_hand or "right"
    local ctrl = world:get_resource("VrControllerState")
    if not ctrl then return nil, nil, nil end
    if hand == "left" then
        return ctrl.left_position, ctrl.left_forward, ctrl.left_rotation
    else
        return ctrl.right_position, ctrl.right_forward, ctrl.right_rotation
    end
end

---------------------------------------------------------------------------
-- Init: register grab input bindings on the player entity
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        ["or"] = { added = { "vr/grabbable", "net_local" } },
        with  = { "input", "vr/grabbable" },
    })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { grabbable = BINDINGS } })
        print(string.format("[VR/GRABBABLE] Registered grab bindings for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Update: grip-to-move logic (ray-projection technique)
---------------------------------------------------------------------------
register_system("Update", function(world)
    -- Find the local player entity with grab input
    local entities = world:query({
        with = { "input_grabbable", "net_local" },
    })
    if #entities == 0 then return end

    local player = entities[1]
    local input_grab = player:get("input_grabbable")
    -- grab binds right_grip (a VR button → digital boolean output)
    local is_pressed = input_grab.grab == true

    -- Edge detection
    local just_pressed  = is_pressed and not grab_state.was_pressed
    local just_released = not is_pressed and grab_state.was_pressed
    grab_state.was_pressed = is_pressed

    local pos, fwd, rot = get_pointer_controller(world)
    if not pos or not fwd then return end

    -- === Grab start ===
    if just_pressed then
        local ray = { origin = pos, direction = fwd, early_exit = false }
        local ok, result = pcall(world.call_systemparam_method, world,
            "MeshRayCast", "cast_ray", ray)

        if ok and result and type(result) == "table" then
            for _, hit in ipairs(result) do
                local hit_entity = world:get_entity(hit.entity)
                if hit_entity then
                    local grabbable = hit_entity:get("vr_grabbable")
                    if grabbable and hit.data then
                        local t = hit_entity:get("Transform")
                        if t and t.translation and hit.data.point then
                            local hit_point = hit.data.point

                            -- Distance from controller to hit point
                            local dx = hit_point.x - pos.x
                            local dy = hit_point.y - pos.y
                            local dz = hit_point.z - pos.z
                            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

                            -- Offset from hit point to entity center
                            grab_state.grabbed_entity = hit.entity
                            grab_state.distance = dist
                            grab_state.offset = {
                                x = t.translation.x - hit_point.x,
                                y = t.translation.y - hit_point.y,
                                z = t.translation.z - hit_point.z,
                            }
                            grab_state.lock_rotation = grabbable.lock_rotation ~= false

                            print(string.format(
                                "[VR/GRABBABLE] Grabbed entity %d (dist=%.3f, offset=(%.3f,%.3f,%.3f))",
                                hit.entity, dist,
                                grab_state.offset.x, grab_state.offset.y, grab_state.offset.z))
                            break
                        end
                    end
                end
            end
        end
    end

    -- === Grab release ===
    if just_released and grab_state.grabbed_entity then
        print(string.format("[VR/GRABBABLE] Released entity %d", grab_state.grabbed_entity))
        grab_state.grabbed_entity = nil
        grab_state.distance = nil
        grab_state.offset = nil
    end

    -- === While grabbing: ray-projection movement ===
    -- Project controller ray forward by stored distance, then add offset.
    -- This naturally handles controller rotation — tilting the controller
    -- moves the panel because the projected hit point changes.
    if grab_state.grabbed_entity and is_pressed and grab_state.distance then
        local entity = world:get_entity(grab_state.grabbed_entity)
        if entity then
            -- Project ray forward by stored distance
            local hit_x = pos.x + fwd.x * grab_state.distance
            local hit_y = pos.y + fwd.y * grab_state.distance
            local hit_z = pos.z + fwd.z * grab_state.distance

            -- Apply offset from hit point to entity center
            local new_pos = {
                x = hit_x + grab_state.offset.x,
                y = hit_y + grab_state.offset.y,
                z = hit_z + grab_state.offset.z,
            }

            entity:set({ Transform = {
                translation = new_pos,
                rotation = entity:get("Transform").rotation or { x = 0, y = 0, z = 0, w = 1 },
                scale = entity:get("Transform").scale or { x = 1, y = 1, z = 1 },
            }})
        else
            -- Entity was despawned while grabbed
            grab_state.grabbed_entity = nil
            grab_state.distance = nil
            grab_state.offset = nil
        end
    end
end, { label = "VrGrabbable", after = { "Input", "VrPointer" } })
