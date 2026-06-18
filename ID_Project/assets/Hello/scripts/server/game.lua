-- Hello Server — Game Instance Bootstrap
-- Sets up mod infrastructure and net_mod systems.
-- Runs instanced at its own state_id — all systems and resources
-- share this scope, so NetInfo.side is naturally accessible everywhere.
--
-- NOTE: net/server is NOT required here. It's loaded by ModLoader when
-- the callback in server/main.lua spawns the net entity with
-- mod = { net = {...}, script = "modules/net/server/init.lua" }.

require("modules/mod/init.lua")
require("modules/net_mod/instance.lua")

local game = {}

function game.init(net_entity)
    -- Map (shared script — both sides spawn identical geometry)
    spawn({
        net_mod = { ["map/default"] = {} },
    }):with_parent(net_entity:id())

    -- Player spawner (server-only — manages spawn points + player lifecycle)
    spawn({
        mod = {
            ["player/spawner"] = {},
        },
    }):with_parent(net_entity:id())
end

function game.init2d(net_entity)
    -- Map (shared script — both sides spawn identical geometry)
    spawn({
        net_mod = { ["map/tiled"] = { tmx_path = "map.tmx" } },
    }):with_parent(net_entity:id())

    -- Player spawner (server-only — manages spawn points + player lifecycle)
    spawn({
        mod = {
            ["player/2d/spawner"] = {},
        },
    }):with_parent(net_entity:id())
end

function game.init_zombie(net_entity)
    -- Tiled map (shared — both sides spawn identical geometry)
    spawn({
        net_mod = { ["map/tiled"] = { tmx_path = "map.tmx" } },
    }):with_parent(net_entity:id())

    -- Zombie-game player spawner (weapons instead of abilities, adds player_health)
    spawn({
        mod = { ["player/2d/zombie_spawner"] = {} },
    }):with_parent(net_entity:id())

    -- Horde spawner: sends waves every ~15-25 s, growing in size each wave
    spawn({
        mod = { ["zombie_spawner"] = {} },
    }):with_parent(net_entity:id())
end

return game