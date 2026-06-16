-- modules/animation/server/init.lua
-- Server-side animation: state machine driven by Velocity3d.
-- Writes animation.state + animation.speed (net_synced to clients).

local BASE_WALK_SPEED = 6.0  -- speed at which walk animation plays at 1.0x

---------------------------------------------------------------------------
-- Init: configure net_sync for animation
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "animation" } })
    for _, entity in ipairs(entities) do
        -- Animation is server-authoritative
        entity:patch({ net_sync = {
            animation = { authority = "server" },
        }})

        -- Initialize state if not already set
        local anim = entity:get("animation") or {}
        if not anim.state then
            entity:patch({ animation = { state = "idle", speed = 1.0 } })
        end

        print(string.format("[ANIMATION/SERVER] Initialized for entity %d (model=%s)",
            entity:id(), tostring(anim.model)))
    end
end)

---------------------------------------------------------------------------
-- State machine: determine animation state from Velocity3d
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with = { "animation", "Velocity3d" },
    })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation")
        if not anim then goto continue end

        local vel = entity:get("Velocity3d")
        if not vel or not vel.linvel then goto continue end

        local vy = vel.linvel.y or 0
        local vx = vel.linvel.x or 0
        local vz = vel.linvel.z or 0
        local horiz_speed = math.sqrt(vx * vx + vz * vz)

        -- Determine state
        local new_state = "idle"
        local new_speed = 1.0

        if vy < -1.0 then
            new_state = "fall"
        elseif vy > 1.0 then
            new_state = "jump"
        elseif horiz_speed > 0.1 then
            new_state = "walk"
            -- Scale animation speed proportional to movement speed
            new_speed = horiz_speed / BASE_WALK_SPEED
            if new_speed < 0.3 then new_speed = 0.3 end
            if new_speed > 2.0 then new_speed = 2.0 end
        end

        -- Guard: only write when state or speed changed
        if anim.state ~= new_state or (new_state == "walk" and math.abs((anim.speed or 1.0) - new_speed) > 0.05) then
            entity:patch({ animation = { state = new_state, speed = new_speed } })
        end

        ::continue::
    end
end, { label = "Animation", after = { "Movement" } })
