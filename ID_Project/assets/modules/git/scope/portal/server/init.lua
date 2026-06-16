-- modules/git/scope/portal/server/init.lua
-- Portal behavior server-side: symmetric config, scope management, crossing.
--
-- Loaded via net_mod:
--   net_mod = { ["git/scope/portal"] = { scope_a = { name = "Repo:branch-a" }, scope_b = { name = "Repo:branch-b" } } }
--
-- The portal entity should have:
--   - Transform (position in the world)
--   - A mesh (used as the stencil mask by the render pipeline)
--   - net_mod entry for this mod

local Portal = require("modules/git/scope/portal/shared/init.lua")
local Net = require("modules/net/shared/net.lua")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Get the centralized PortAllocator resource (inherited from server/main.lua via scope tree).
--- @return table ports  The shared PortAllocator table with alloc() function
local function get_port_allocator()
    return define_resource("PortAllocator", { next_port = 5002, scope_ports = {} })
end

--- Ensure a scope has a running server + client, launching if needed.
--- Uses ScopeInstances for dedup, PortAllocator for port allocation.
--- Spawns `game` entities so server/main.lua and main.lua pick them up.
--- @param scope_key string The scope identifier
--- @return integer port The port number the scope server is running on
local function ensure_scope_server(scope_key)
    local ports = get_port_allocator()

    -- Already running? Return existing port.
    local scope_instances = define_resource("ScopeInstances", {})
    if scope_instances[scope_key] then
        return ports.scope_ports[scope_key] or scope_instances[scope_key].port
    end

    local port, is_new = ports.alloc(scope_key)

    if is_new then
        print(string.format("[PORTAL] Requesting game server for scope '%s' on port %d",
            scope_key, port))

        -- Launch server game only — each client spawns its own client connection
        -- (via portal/client or selector)
        spawn({
            game = { mode = "server", port = port, scope_key = scope_key },
        })
    else
        print(string.format("[PORTAL] Reusing existing server for scope '%s' on port %d", scope_key, port))
    end

    return port
end

---------------------------------------------------------------------------
-- System: PortalPlacementConfirmed — portal just had placement removed
-- This means a player confirmed the portal's position via the placement mod.
-- Now we initialize it as a full portal with symmetric config + net_transfer.
-- Also adds collision_trigger net_mod for crossing detection.
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({
        with = { "git/scope/portal" },
        removed = { "placement" },
    })
    for _, entity in ipairs(entities) do
        if not world:get_entity(entity:id()) then goto continue end -- Placement despawns on cancel

        local cfg = entity:get("git/scope/portal")
        if not cfg or not cfg.scope_b then goto continue end

        -- Only launch server for scopes that aren't already running.
        -- scope_a can be nil (portal placed from lobby — lobby is already running).
        local net_info = define_resource("NetInfo", {})
        local my_scope_key = net_info.scope_key
        local scope_a_port = ensure_scope_server(cfg.scope_a.name)
        local scope_b_port = ensure_scope_server(cfg.scope_b.name)

        local scope_instances = define_resource("ScopeInstances", {})
        local scope_a_info = scope_instances[cfg.scope_a.name]
        local scope_b_info = scope_instances[cfg.scope_b.name]

        entity:patch({
            ["git/scope/portal"] = {
                scope_a = {
                    name = cfg.scope_a.name,
                    id = scope_a_info and scope_a_info.scope_id,
                    port = scope_a_port
                },
                scope_b = {
                    name = cfg.scope_b.name,
                    id = scope_b_info and scope_b_info.scope_id,
                    port = scope_b_port
                },
            },
            net_mod = { collision_trigger = {} },
            net_sync = {
                ["git/scope/portal"] = { authority = "server" },
                Transform = { authority = "server" },
            },
            net_transfer = {},  -- non-owned: relay auto-spawns mirrors
        })

        -- Establish peer connection to the target scope's peer server.
        -- Each scope's peer server listens on game_port + 10000.
        -- This creates an outbound renet client that connects to scope_b's peer port.
        local peer_state = define_resource("NetPeerState", {})
        local peer_target_port = scope_b_port + 10000
        local peer_name = "peer_to_" .. tostring(scope_b_port)

        if not peer_state.outbound_peers or not peer_state.outbound_peers[peer_name] then
            spawn({
                net_peer_connect = {
                    name = peer_name,
                    port = peer_target_port,
                    scope_key = cfg.scope_b.name,
                    server_addr = "127.0.0.1",  -- local for now, remote later
                },
            })
            print(string.format("[PORTAL] Peer connect → '%s' (port %d, scope=%s)",
                peer_name, peer_target_port, cfg.scope_b.name))
        end

        print(string.format("[PORTAL] Placement confirmed: %s <-> %s",
            tostring(cfg.scope_a.name), cfg.scope_b.name))

        ::continue::
    end
end, { label = "PortalPlacementConfirmed", after = { "PortalInit" } })

---------------------------------------------------------------------------
-- System: PortalCrossing — react to collision_trigger events on portals
-- When a player enters the portal sensor, initiate authority switch
-- and send SCOPE_SWITCH to the crossing client.
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, portal in ipairs(world:query({
        changed = { "collision_trigger" },
        with = { "git/scope/portal" },
    })) do
        local ct = portal:get("collision_trigger")
        local cfg = portal:get("git/scope/portal")
        if #(ct.entered or {}) == 0 then goto continue end

        -- Skip if portal hasn't been fully configured yet
        if not cfg.scope_a or not cfg.scope_a.port or not cfg.scope_b or not cfg.scope_b.port then
            goto continue
        end

        local net_info = define_resource("NetInfo", {})
        local my_scope_key = net_info.scope_key

        -- Determine target scope from portal's symmetric config
        local target_scope_key, target_port
        if my_scope_key == cfg.scope_a.name then
            target_scope_key = cfg.scope_b.name
            target_port = cfg.scope_b.port
        elseif my_scope_key == cfg.scope_b.name then
            target_scope_key = cfg.scope_a.name
            target_port = cfg.scope_a.port
        else
            goto continue
        end

        -- Process entered entities — only players with net_owner trigger crossing
        for _, entity_id in ipairs(ct.entered or {}) do
            local player = world:get_entity(entity_id)
            if not player then goto skip_player end
            if not player:has("player") then goto skip_player end

            local owner = player:get("net_owner")
            if not owner then goto skip_player end

            -- Skip mirror entities (they're controlled by another scope)
            if player:has("net_peer_mirror") then goto skip_player end

            -- 1. Initiate authority switch via net_peer
            player:patch({
                net_peer_switch = { target_scope = target_scope_key },
            })

            -- 2. Send SCOPE_SWITCH to the specific client via event bridge
            world:write_event("net:send_to_client", {
                client_id = owner.client_id,
                msg = {
                    msg_type = Net.MSG.SCOPE_SWITCH,
                    target_scope_key = target_scope_key,
                    target_port = target_port,
                },
            })

            print(string.format("[PORTAL] Player %d (client %s) crossing → scope '%s'",
                entity_id, tostring(owner.client_id), target_scope_key))

            ::skip_player::
        end

        ::continue::
    end
end, { label = "PortalCrossing", after = { "CollisionTrigger" } })
