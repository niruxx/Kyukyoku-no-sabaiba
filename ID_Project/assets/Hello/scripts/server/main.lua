-- Hello Server — Game Launcher
-- Watches for `game` components and launches isolated game server instances.
-- Each game runs in its own scope (sibling of other games), fully isolated.
-- Defines the PortAllocator resource for centralized port management.
-- Child scopes (portals, selectors) inherit this resource via scope tree lineage.

-- Centralized port allocation for all game instances.
-- Child scopes access this via define_resource — shares_lineage returns the
-- parent's table instead of creating a new one.
local ports = define_resource("PortAllocator", {
    next_port = 5002,     -- next available port (5001 is lobby)
    scope_ports = {},     -- scope_key -> assigned port
})

--- Allocate (or reuse) a port for a scope key.
--- @param scope_key string The scope identifier (e.g., "Hello-Rust2:main")
--- @return number port The assigned port number
--- @return boolean is_new Whether a new port was allocated (vs reused)
function ports.alloc(scope_key)
    if ports.scope_ports[scope_key] then
        return ports.scope_ports[scope_key], false
    end
    local port = ports.next_port
    ports.scope_ports[scope_key] = port
    ports.next_port = port + 1
    return port, true
end

--- Free a port allocation for a scope key.
--- Called when a game server is torn down so the scope can be re-launched later.
--- @param scope_key string The scope identifier to release
function ports.free(scope_key)
    if ports.scope_ports[scope_key] then
        print(string.format("[PORT_ALLOC] Freed port %d for scope '%s'",
            ports.scope_ports[scope_key], scope_key))
        ports.scope_ports[scope_key] = nil
    end
end

--- Free a port allocation by port number (reverse lookup).
--- Used by the net server teardown which knows its port but not scope_key.
--- @param port number The port number to release
function ports.free_by_port(port)
    for scope_key, p in pairs(ports.scope_ports) do
        if p == port then
            print(string.format("[PORT_ALLOC] Freed port %d for scope '%s' (by port)",
                port, scope_key))
            ports.scope_ports[scope_key] = nil
            return
        end
    end
end

-- Register lobby on port 5001
ports.scope_ports["lobby"] = 5001

-- Shared state bus for cross-scope transfer (children access via lineage).
local transfers = define_resource("TransferState", {})
transfers._primary = {}  -- [client_id] = port (which instance is authoritative)

-- Scope instances registry — maps scope_key to scope info.
-- Child scopes (portals, selectors) access via define_resource lineage.
local scope_instances = define_resource("ScopeInstances", {})

-- Worktree helper — creates git worktrees and returns asset_root paths.
local worktree = require("modules/git/scope/shared/worktree.lua", { reload = false })

-- Game server launcher: watches for `game` entities with mode="server"
-- and launches isolated server instances (same pattern as client main.lua).
register_system("PreUpdate", function(world)
    local games = world:query({ added = { "game" } })
    for _, entity in ipairs(games) do
        local cfg = entity:get("game")
        -- Only handle server-mode games
        if not cfg or cfg.mode ~= "server" then goto continue end

        local port = cfg.port or 5001
        local name = "game_" .. tostring(port)
        local scope_key = cfg.scope_key
        local asset_root = worktree.get_asset_root(scope_key)

        print(string.format("[SERVER LAUNCHER] Launching game server on port %d (name=%s, scope=%s)",
            port, name, tostring(scope_key)))

        require_async("Hello/scripts/server/game.lua", function(game)
            -- Register this scope in the shared instances registry
            if scope_key then
                scope_instances[scope_key] = {
                    scope_id = __SCOPE_ID__,
                    port = port,
                }
            end

            local net_entity = spawn({
                mod = {
                    net = { mode = "server", port = port, name = name, scope_key = scope_key },
                    script = "modules/net/server/init.lua",
                },
            })

            -- Peer server for server-to-server entity federation.
            -- Listens on game_port + 10000. Other game servers connect here
            -- to exchange entity state for portal rendering.
            local peer_name = "peer_" .. tostring(port)
            spawn({
                net_peer_server = {
                    port = port + 10000,
                    name = peer_name,
                    scope_key = scope_key,
                    game_port = port,
                },
                mod = {
                    ["net/peer"] = {},
                },
            }):with_parent(net_entity:id())

            game.init_zombie(net_entity)
        end, { instanced = true, reload = false, asset_root = asset_root })

        ::continue::
    end
end)

-- Launch initial game server (lobby on port 5001)
spawn({ game = { mode = "server", port = 5001, scope_key = "lobby" } })
