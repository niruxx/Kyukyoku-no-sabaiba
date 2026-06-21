-- Hello Client — Game Instance Bootstrap
-- Sets up mod infrastructure and net_mod systems.
-- Runs instanced at its own state_id — all systems and resources
-- share this scope, so NetInfo.side is naturally accessible everywhere.
--
-- NOTE: net/client is NOT required here. It's loaded by ModLoader when
-- the callback in main.lua spawns the net entity with
-- mod = { net = {...}, script = "modules/net/client/init.lua" }.

require("modules/mod/init.lua")
require("modules/net_mod/instance.lua")

-- Fade-in overlay: starts opaque black and fades to transparent over ~1.5 s
local fade = define_resource("FadeInState", {
    overlay_id = nil,
    alpha      = 1.0,
    done       = false,
})

register_system("First", function(world)
    local overlay = spawn({
        Node = {
            position_type = "Absolute",
            left   = { Px = 0 }, top    = { Px = 0 },
            right  = { Px = 0 }, bottom = { Px = 0 },
        },
        BackgroundColor = { color = { r = 0, g = 0, b = 0, a = 1.0 } },
        GlobalZIndex    = { value = 100 },
    })
    fade.overlay_id = overlay:id()
    return true
end)

register_system("Update", function(world)
    if fade.done then return end
    local dt = world:delta_time()
    fade.alpha = fade.alpha - dt * 0.67  -- ~1.5 s fade
    if fade.alpha <= 0.0 then
        fade.alpha = 0.0
        fade.done  = true
        local e = world:get_entity(fade.overlay_id)
        if e then despawn(e) end
    else
        local e = world:get_entity(fade.overlay_id)
        if e then
            e:patch({ BackgroundColor = { color = { r = 0, g = 0, b = 0, a = fade.alpha } } })
        end
    end
end)

