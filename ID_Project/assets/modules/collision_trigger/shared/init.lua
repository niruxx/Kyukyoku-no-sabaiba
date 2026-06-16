-- modules/collision_trigger/shared/init.lua
-- Generic collision trigger net_mod.
-- Patches enter/exit events each frame. No filtering — consumers
-- use world:query({ with = { "player" }, entities = ct.inside })
-- to apply their own logic.

-- Track per-trigger state in a resource (avoids JSON round-trip issues
-- and prevents patching the component every frame when nothing changed).
local tracker = define_resource("CollisionTriggerTracker", {
    -- entity_id → { [entity_id_string] = true }
    inside = {},
    -- entity_id → true (has stale entered/exited from last frame that needs clearing)
    dirty = {},
})

register_system("Update", function(world)
    -- Pass 1: Clear stale entered/exited from previous frame
    for trigger_id in pairs(tracker.dirty) do
        local trigger = world:get_entity(trigger_id)
        if trigger then
            trigger:set({ collision_trigger = {
                entered = {},
                exited = {},
            }})
        end
    end
    tracker.dirty = {}

    -- Pass 2: Compute new enter/exit deltas
    local triggers = world:query({
        with = { "collision_trigger", "CollidingEntities3d" },
    })
    for _, trigger in ipairs(triggers) do
        local tid = trigger:id()
        local colliding = trigger:get("CollidingEntities3d") or {}

        local prev_inside = tracker.inside[tid] or {}
        local curr_inside = {}

        for _, id in ipairs(colliding) do
            curr_inside[id] = true
        end

        -- Compute enter/exit deltas
        local entered, exited = {}, {}
        for id in pairs(curr_inside) do
            if not prev_inside[id] then entered[#entered + 1] = id end
        end
        for id in pairs(prev_inside) do
            if not curr_inside[id] then exited[#exited + 1] = id end
        end

        -- Update tracker
        tracker.inside[tid] = curr_inside

        -- Only patch component when there are actual events
        if #entered > 0 or #exited > 0 then
            trigger:set({ collision_trigger = {
                entered = entered,
                exited = exited,
                inside = curr_inside,
            }})
            -- Mark for cleanup next frame
            tracker.dirty[tid] = true
        end
    end

    -- Clean up tracker entries for despawned triggers
    for tid in pairs(tracker.inside) do
        if not world:get_entity(tid) then
            tracker.inside[tid] = nil
            tracker.dirty[tid] = nil
        end
    end
end, { label = "CollisionTrigger" })
