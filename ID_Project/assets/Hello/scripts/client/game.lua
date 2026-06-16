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
