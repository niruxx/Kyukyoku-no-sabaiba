-- modules/map/lobby/server/init.lua
-- Server side of the lobby map: bake trimesh colliders from the lobby GLB (shared).
-- No visuals on the server — the client loads the scene for rendering.
require("modules/map/lobby/shared/init.lua")
