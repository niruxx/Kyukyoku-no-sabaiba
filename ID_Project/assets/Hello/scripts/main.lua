-- Hello Client — Game Launcher
-- Watches for `game` components and launches isolated game instances.
-- Each game runs in its own scope (sibling of other games), fully isolated.
-- Tracks active instance for teardown on scope switch (portal crossing).

local active = define_resource("ActiveGameInstance", {
    port = nil,           -- currently active port
    script_handle = nil,  -- handle to stop_current_script on old instance
    player_id = nil,      -- stable cross-server identity (generated once)
})

-- Worktree helper — creates git worktrees and returns asset_root paths.
local worktree = require("modules/git/scope/shared/worktree.lua")

register_system("PreUpdate", function(world)
    local games = world:query({ added = { "game" } })
    for _, entity in ipairs(games) do
        local cfg = entity:get("game")
        -- Skip server-mode games (handled by server/main.lua launcher)
        if cfg and cfg.mode == "server" then goto continue end

        local port = (cfg and cfg.port) or 5001
        local scope_key = cfg and cfg.scope_key
        local observer = cfg and cfg.observer
        local asset_root = worktree.get_asset_root(scope_key)

        -- Track active instance (first launch or portal switch)
        active.port = port

        require_async("Hello/scripts/client/game.lua", function()
            -- Callback runs in the new instance's scope (child of root, sibling of others).
            -- client_id, port, scope_key are captured by Lua closure from the parent scope.
            spawn({
                mod = {
                    net = {
                        mode = "client",
                        ip = "127.0.0.1",
                        port = port,
                        name = "game_" .. tostring(port),
                        player_id = active.player_id,  -- ConnectToken user_data (stable identity)
                        scope_key = scope_key,
                        observer = observer,  -- Portal observer: defer player spawn
                    },
                    script = "modules/net/client/init.lua",
                },
            })
        end, { instanced = true, reload = false, asset_root = asset_root })

        ::continue::
    end
end)

-- Generate a stable player identity for this session.
-- ALL connections (lobby, portal observers, etc.) use this same identity
-- so that net_owner.client_id matches across servers.
active.player_id = math.random(1, 2^53)

-- Launch initial game
spawn({ game = { mode = "client", port = 5001, scope_key = "lobby" } })
