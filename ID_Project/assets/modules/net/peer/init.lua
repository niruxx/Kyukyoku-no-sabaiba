-- modules/net/peer/init.lua
-- Peer server: accepts connections from other game servers for entity federation.
-- Each game server runs a peer server on port = game_port + 10000.
-- Completely independent from net/server — different renet instance,
-- different port, different message handling. The spawner never sees peers.
--
-- Also manages outbound peer CLIENT connections to other servers' peer ports.

local Peer = require("modules/net/peer/shared.lua")
local Tracking = require("modules/net/shared/tracking.lua")
local json = require("modules/dkjson.lua")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state = define_resource("NetPeerState", {
    initialized = false,
    server_name = nil,        -- name of our peer renet server instance
    scope_key = nil,          -- our scope key (e.g., "Hello-Rust2:main")
    game_port = nil,          -- the game server port we're paired with

    -- Inbound peers: other servers connected TO us
    -- transport_id → { scope_key, ready, mirror_ids = {} }
    inbound_peers = {},
    transport_to_peer = {},   -- transport_id → peer_id (scope_key)

    -- Outbound peers: our connections TO other servers
    -- peer_name → { port, scope_key, connected }
    outbound_peers = {},

    -- Mirror entity tracking: stable_id → local entity_id
    mirror_entities = {},

    -- Source entity tracking: stable_id → { entity_id, sent_initial }
    source_entities = {},
})

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function find_userdata_path(v, path)
    local t = type(v)
    if t == "userdata" then return path, v end
    if t == "table" then
        for k, sub in pairs(v) do
            local found, who = find_userdata_path(sub, path .. "." .. tostring(k))
            if found then return found, who end
        end
    end
    return nil
end

--- Send a message to an inbound peer (connected to our peer server).
local function send_to_inbound(world, transport_id, msg, channel)
    channel = channel or Peer.CHANNEL_RELIABLE
    local enc_ok, encoded_or_err = pcall(Peer.encode, msg)
    if not enc_ok then
        local path = find_userdata_path(msg, "msg")
        print(string.format(
            "[NET PEER] encode failed for inbound %d (%s): userdata at %s | msg_type=%s stable_id=%s",
            transport_id, tostring(encoded_or_err), tostring(path),
            tostring(msg.msg_type), tostring(msg.stable_id)))
        return
    end
    local ok, err = pcall(world.call_resource_method, world,
        "RenetServer", "send_message",
        state.server_name, transport_id, channel, encoded_or_err)
    if not ok then
        print(string.format("[NET PEER] Send to inbound %d failed: %s",
            transport_id, tostring(err)))
    end
end

--- Send a message on an outbound peer connection (our client → their server).
local function send_to_outbound(world, peer_name, msg, channel)
    channel = channel or Peer.CHANNEL_RELIABLE
    local enc_ok, encoded_or_err = pcall(Peer.encode, msg)
    if not enc_ok then
        local path = find_userdata_path(msg, "msg")
        print(string.format(
            "[NET PEER] encode failed for outbound '%s' (%s): userdata at %s | msg_type=%s stable_id=%s",
            peer_name, tostring(encoded_or_err), tostring(path),
            tostring(msg.msg_type), tostring(msg.stable_id)))
        return
    end
    local ok, err = pcall(world.call_resource_method, world,
        "RenetClient", "send_message",
        peer_name, channel, encoded_or_err)
    if not ok then
        print(string.format("[NET PEER] Send to outbound '%s' failed: %s",
            peer_name, tostring(err)))
    end
end

--- Broadcast a message to ALL connected peers (both inbound and outbound).
local function broadcast_to_peers(world, msg, channel)
    for tid, peer in pairs(state.inbound_peers) do
        if peer.ready then
            send_to_inbound(world, tid, msg, channel)
        end
    end
    for name, peer in pairs(state.outbound_peers) do
        if peer.connected then
            send_to_outbound(world, name, msg, channel)
        end
    end
end

---------------------------------------------------------------------------
-- Entity Sync: Inbound (receive mirror entities from peers)
---------------------------------------------------------------------------

local function handle_entity_spawn(world, msg)
    local stable_id = msg.stable_id
    if not stable_id then return end

    -- Don't double-spawn
    if state.mirror_entities[stable_id] then
        print(string.format("[NET PEER] Mirror for '%s' already exists, skipping spawn", stable_id))
        return
    end

    local components = msg.components or {}

    -- Add mirror marker (replaces net_owner — no local client controls this)
    components.net_peer_mirror = {
        stable_id = stable_id,
        source_peer = msg.source_scope_key or "unknown",
    }

    -- Remove net_owner if present (mirror entity has no local client)
    components.net_owner = nil

    -- Preserve net_sync so this server replicates the mirror to its own clients
    -- (the mirror is a "real" entity in this server's world)
    if not components.net_sync then
        components.net_sync = {}
    end

    -- Preserve net_mod so all mods load (full mirror, not stripped ghost)
    -- net_mod comes from the source entity's config

    local mirror = spawn(components)

    state.mirror_entities[stable_id] = mirror:id()

    print(string.format("[NET PEER] Spawned mirror entity for '%s' (eid=%s)",
        stable_id, tostring(mirror:id())))
end

local function handle_entity_update(world, msg)
    local stable_id = msg.stable_id
    if not stable_id then return end

    local mirror_eid = state.mirror_entities[stable_id]
    if not mirror_eid then return end

    local mirror = world:get_entity(mirror_eid)
    if not mirror then
        -- Entity was despawned externally, clean up tracking
        state.mirror_entities[stable_id] = nil
        return
    end

    if msg.components and next(msg.components) then
        mirror:patch(msg.components)
    end
end

local function handle_entity_despawn(world, msg)
    local stable_id = msg.stable_id
    if not stable_id then return end

    local mirror_eid = state.mirror_entities[stable_id]
    if not mirror_eid then return end

    local mirror = world:get_entity(mirror_eid)
    if mirror then
        despawn(mirror)
    end

    state.mirror_entities[stable_id] = nil

    print(string.format("[NET PEER] Despawned mirror entity for '%s'", stable_id))
end

--- Promote a mirror entity to source (authority switch received from peer).
--- The peer that was the source has demoted itself; we now take ownership.
local function handle_authority_switch(world, msg)
    local stable_id = msg.stable_id
    local client_id = msg.client_id
    if not stable_id or not client_id then
        print("[NET PEER] AUTHORITY_SWITCH missing stable_id or client_id")
        return false
    end

    local mirror_eid = state.mirror_entities[stable_id]
    if not mirror_eid then
        print(string.format("[NET PEER] AUTHORITY_SWITCH: no mirror entity for '%s'", stable_id))
        return false
    end

    local mirror = world:get_entity(mirror_eid)
    if not mirror then
        state.mirror_entities[stable_id] = nil
        print(string.format("[NET PEER] AUTHORITY_SWITCH: mirror entity '%s' already despawned", stable_id))
        return false
    end

    local mirror_data = mirror:get("net_peer_mirror") or {}

    if mirror_data.was_source then
        ---------------------------------------------------------------------------
        -- CASE: Demoted source returning home — re-promote in place.
        -- Entity already has all components (Velocity3d, mods, etc.).
        ---------------------------------------------------------------------------
        mirror:remove("net_peer_mirror")
        mirror:patch({ net_owner = { client_id = client_id } })

        -- Move from mirror tracking to source tracking
        state.mirror_entities[stable_id] = nil
        state.source_entities[stable_id] = {
            entity_id = mirror_eid,
            sent_initial = true,
        }

        print(string.format("[NET PEER] Authority switch: re-promoted '%s' (client=%s) to source (was_source)",
            stable_id, tostring(client_id)))
    else
        ---------------------------------------------------------------------------
        -- CASE: Peer-spawned mirror — incomplete entity, spawn a full player.
        ---------------------------------------------------------------------------
        local sync_config = mirror:get("net_sync") or {}
        local synced_state = Tracking.serialize_synced(world, mirror, sync_config)
        -- Include net_sync so the spawner can merge sync entries (e.g. camera)
        -- into the new entity's net_sync — otherwise broadcast_spawn won't
        -- include components like camera in the SPAWN message.
        synced_state.net_sync = sync_config

        -- Find the net_client entity for this client_id and signal promotion
        local promoted = false
        for _, e in ipairs(world:query({ with = { "net_client" } })) do
            local nc = e:get("net_client")
            if nc and nc.client_id == client_id then
                e:patch({ net_client = {
                    synced_state = synced_state,
                }})
                promoted = true
                break
            end
        end

        if not promoted then
            print(string.format("[NET PEER] AUTHORITY_SWITCH: no net_client entity for client %s", tostring(client_id)))
            return false
        end

        -- Despawn mirror — player/spawner will create a full player entity
        despawn(mirror)
        state.mirror_entities[stable_id] = nil

        print(string.format("[NET PEER] Authority switch: '%s' (client=%s) → spawning real player, mirror despawned",
            stable_id, tostring(client_id)))
    end

    return true
end

---------------------------------------------------------------------------
-- Entity Sync: Outbound (send net_peer_share entities to peers)
---------------------------------------------------------------------------

local function send_initial_spawn(world, entity, share, sync_config)
    local stable_id = share.stable_id

    -- Serialize all synced components
    local components = Tracking.serialize_synced(world, entity, sync_config)

    -- Include infrastructure that the mirror needs (serialize_synced excludes these)
    components.net_sync = sync_config
    components.net_peer_share = share

    broadcast_to_peers(world, {
        msg_type = Peer.MSG.ENTITY_SPAWN,
        stable_id = stable_id,
        source_scope_key = state.scope_key,
        components = components,
    })

    state.source_entities[stable_id] = {
        entity_id = entity:id(),
        sent_initial = true,
    }
end

local function send_entity_updates(world)
    -- Get entities with changed synced components.
    -- Pull net_peer_share/net_peer_mirror into the snapshot so we can read
    -- them below (query_changed only has net_sync + the synced components).
    local changed = Tracking.get_changed_entities(world, {
        optional = { "net_peer_share", "net_peer_mirror" },
    })

    for _, entity in ipairs(changed) do
        local share = entity:get("net_peer_share")
        if not share or not share.stable_id then goto continue end

        -- Only send entities WE are the source for (not mirrors)
        if entity:has("net_peer_mirror") then goto continue end

        local source = state.source_entities[share.stable_id]
        if not source or not source.sent_initial then goto continue end

        local sync_config = entity:get("net_sync")
        if not sync_config then goto continue end

        local changed_components = Tracking.collect_changed_components(entity, sync_config)
        if next(changed_components) then

            broadcast_to_peers(world, {
                msg_type = Peer.MSG.ENTITY_UPDATE,
                stable_id = share.stable_id,
                components = changed_components,
            }, Peer.CHANNEL_UNRELIABLE)  -- Transform updates are frequent, use unreliable
        end

        ::continue::
    end
end

---------------------------------------------------------------------------
-- System: PeerServerInit (First)
---------------------------------------------------------------------------
register_system("First", function(world)
    if state.initialized then return end

    local entities = world:query({ added = { "net_peer_server" } })
    for _, entity in ipairs(entities) do
        if state.initialized then goto continue end

        local cfg = entity:get("net_peer_server")
        if not cfg or not cfg.port or not cfg.name then
            print("[NET PEER] net_peer_server missing port or name")
            goto continue
        end

        -- Create a separate renet server for peer connections
        insert_resource("RenetServer", { name = cfg.name })
        insert_resource("NetcodeServerTransport", {
            name = cfg.name,
            port = cfg.port,
            max_clients = 10,
        })

        state.server_name = cfg.name
        state.scope_key = cfg.scope_key
        state.game_port = cfg.game_port
        state.initialized = true

        print(string.format("[NET PEER] Peer server '%s' listening on port %d (game_port=%d, scope=%s)",
            cfg.name, cfg.port, cfg.game_port or 0, cfg.scope_key or "?"))

        ::continue::
    end
end, { label = "PeerServerInit" })

---------------------------------------------------------------------------
-- System: PeerClientInit (First)
-- Create outbound peer connections when net_peer_connect entities appear.
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "net_peer_connect" } })
    for _, entity in ipairs(entities) do
        local cfg = entity:get("net_peer_connect")
        if not cfg.port or not cfg.name then
            print("[NET PEER] net_peer_connect missing port or name")
            goto continue
        end

        -- Don't double-connect
        if state.outbound_peers[cfg.name] then
            print(string.format("[NET PEER] Already connected to peer '%s'", cfg.name))
            goto continue
        end

        insert_resource("RenetClient", { name = cfg.name })
        insert_resource("NetcodeClientTransport", {
            name = cfg.name,
            server_addr = cfg.server_addr or "127.0.0.1",
            port = cfg.port,
        })

        state.outbound_peers[cfg.name] = {
            port = cfg.port,
            scope_key = cfg.scope_key,
            connected = false,
            entity_id = entity:id(),
        }

        print(string.format("[NET PEER] Connecting to peer '%s' at %s:%d (scope=%s)",
            cfg.name, cfg.server_addr or "127.0.0.1", cfg.port, cfg.scope_key or "?"))

        ::continue::
    end
end, { label = "PeerClientInit" })

---------------------------------------------------------------------------
-- System: PeerServerInbound (First)
-- Handle connections, disconnections, and messages from inbound peers.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.initialized then return end

    -- New peer connections
    local ok_nc, new_transports = pcall(world.call_resource_method, world,
        "RenetServer", "get_new_connections", state.server_name)
    for _, transport_id in ipairs(ok_nc and new_transports or {}) do
        state.inbound_peers[transport_id] = {
            scope_key = nil,
            ready = false,
            mirror_ids = {},
        }
        print(string.format("[NET PEER] Inbound peer connected: transport_id=%d", transport_id))
    end

    -- Peer disconnections
    local ok_dc, disconnected = pcall(world.call_resource_method, world,
        "RenetServer", "get_disconnections", state.server_name)
    for _, transport_id in ipairs(ok_dc and disconnected or {}) do
        local peer = state.inbound_peers[transport_id]
        if peer then
            -- Despawn all mirror entities from this peer
            for stable_id, mirror_eid in pairs(peer.mirror_ids) do
                local mirror = world:get_entity(mirror_eid)
                if mirror then despawn(mirror) end
                state.mirror_entities[stable_id] = nil
            end

            state.transport_to_peer[transport_id] = nil
            state.inbound_peers[transport_id] = nil
            print(string.format("[NET PEER] Inbound peer disconnected: %d (scope=%s)",
                transport_id, peer.scope_key or "?"))
        end
    end

    -- Receive messages from inbound peers
    local ok_cl, transports = pcall(world.call_resource_method, world,
        "RenetServer", "clients_id", state.server_name)
    for _, transport_id in ipairs(ok_cl and transports or {}) do
        for _, channel in ipairs({ Peer.CHANNEL_RELIABLE, Peer.CHANNEL_UNRELIABLE }) do
            while true do
                local ok_rm, raw = pcall(world.call_resource_method, world,
                    "RenetServer", "receive_message",
                    state.server_name, transport_id, channel)
                if not ok_rm or not raw then break end

                local msg = Peer.decode(raw)
                if not msg then goto skip_msg end

                -- Route by message type
                if msg.msg_type == Peer.MSG.PEER_HELLO then
                    local peer = state.inbound_peers[transport_id]
                    if peer then
                        peer.scope_key = msg.scope_key
                        peer.ready = true
                        state.transport_to_peer[transport_id] = msg.scope_key

                        print(string.format("[NET PEER] Peer hello from %d: scope=%s game_port=%s",
                            transport_id, msg.scope_key or "?", tostring(msg.game_port)))

                        -- Send welcome
                        send_to_inbound(world, transport_id, {
                            msg_type = Peer.MSG.PEER_WELCOME,
                            scope_key = state.scope_key,
                            game_port = state.game_port,
                        })

                        -- Send existing source entities to the newly connected peer
                        for stable_id, source in pairs(state.source_entities) do
                            local entity = world:get_entity(source.entity_id)
                            if entity then
                                local share = entity:get("net_peer_share")
                                local sync = entity:get("net_sync")
                                if share and sync then
                                    local components = Tracking.serialize_synced(world, entity, sync)
                                    components.net_sync = sync
                                    components.net_peer_share = share

                                    send_to_inbound(world, transport_id, {
                                        msg_type = Peer.MSG.ENTITY_SPAWN,
                                        stable_id = stable_id,
                                        source_scope_key = state.scope_key,
                                        components = components,
                                    })
                                    source.sent_initial = true
                                end
                            end
                        end
                    end

                elseif msg.msg_type == Peer.MSG.ENTITY_SPAWN then
                    handle_entity_spawn(world, msg)
                    -- Track which peer sent this mirror
                    local peer = state.inbound_peers[transport_id]
                    if peer and msg.stable_id then
                        peer.mirror_ids[msg.stable_id] = state.mirror_entities[msg.stable_id]
                    end

                elseif msg.msg_type == Peer.MSG.ENTITY_UPDATE then
                    handle_entity_update(world, msg)

                elseif msg.msg_type == Peer.MSG.ENTITY_DESPAWN then
                    handle_entity_despawn(world, msg)
                    local peer = state.inbound_peers[transport_id]
                    if peer and msg.stable_id then
                        peer.mirror_ids[msg.stable_id] = nil
                    end

                elseif msg.msg_type == Peer.MSG.AUTHORITY_SWITCH then
                    handle_authority_switch(world, msg)

                else
                    print(string.format("[NET PEER] Unknown inbound msg: %s", tostring(msg.msg_type)))
                end

                ::skip_msg::
            end
        end
    end
end, { label = "PeerServerInbound", after = { "PeerServerInit" } })

---------------------------------------------------------------------------
-- System: PeerClientInbound (First)
-- Handle outbound peer connection lifecycle + messages.
---------------------------------------------------------------------------
register_system("First", function(world)
    for peer_name, peer in pairs(state.outbound_peers) do
        -- Check connection status
        local ok_conn, is_connected = pcall(world.call_resource_method, world,
            "RenetClient", "is_connected", peer_name)
        if not ok_conn or not is_connected then
            if peer.connected then
                peer.connected = false
                print(string.format("[NET PEER] Outbound peer '%s' disconnected", peer_name))
            end
            goto next_peer
        end

        -- First time connected → send PEER_HELLO
        if not peer.connected then
            peer.connected = true
            print(string.format("[NET PEER] Outbound peer '%s' connected!", peer_name))

            send_to_outbound(world, peer_name, {
                msg_type = Peer.MSG.PEER_HELLO,
                scope_key = state.scope_key,
                game_port = state.game_port,
            })

            -- Send existing source entities to the newly connected peer
            for stable_id, source in pairs(state.source_entities) do
                local entity = world:get_entity(source.entity_id)
                if entity then
                    local share = entity:get("net_peer_share")
                    local sync = entity:get("net_sync")
                    if share and sync then
                        local components = Tracking.serialize_synced(world, entity, sync)
                        components.net_sync = sync
                        components.net_peer_share = share

                        send_to_outbound(world, peer_name, {
                            msg_type = Peer.MSG.ENTITY_SPAWN,
                            stable_id = stable_id,
                            source_scope_key = state.scope_key,
                            components = components,
                        })
                        source.sent_initial = true
                    end
                end
            end
        end

        -- Receive messages from remote peer server
        for _, channel in ipairs({ Peer.CHANNEL_RELIABLE, Peer.CHANNEL_UNRELIABLE }) do
            while true do
                local ok_rm, raw = pcall(world.call_resource_method, world,
                    "RenetClient", "receive_message",
                    peer_name, channel)
                if not ok_rm or not raw then break end

                local msg = Peer.decode(raw)
                if not msg then goto skip_msg end

                if msg.msg_type == Peer.MSG.PEER_WELCOME then
                    peer.scope_key = msg.scope_key
                    print(string.format("[NET PEER] Peer welcome from '%s': scope=%s",
                        peer_name, msg.scope_key or "?"))

                elseif msg.msg_type == Peer.MSG.ENTITY_SPAWN then
                    handle_entity_spawn(world, msg)

                elseif msg.msg_type == Peer.MSG.ENTITY_UPDATE then
                    handle_entity_update(world, msg)

                elseif msg.msg_type == Peer.MSG.ENTITY_DESPAWN then
                    handle_entity_despawn(world, msg)

                elseif msg.msg_type == Peer.MSG.AUTHORITY_SWITCH then
                    -- Authority switch can also come from a server we connected to
                    handle_authority_switch(world, msg)

                elseif msg.msg_type == Peer.MSG.AUTHORITY_ACK then
                    print(string.format("[NET PEER] Authority ack for '%s'",
                        msg.stable_id or "?"))

                else
                    print(string.format("[NET PEER] Unknown outbound msg: %s", tostring(msg.msg_type)))
                end

                ::skip_msg::
            end
        end

        ::next_peer::
    end
end, { label = "PeerClientInbound", after = { "PeerClientInit" } })

---------------------------------------------------------------------------
-- System: PeerOutbound (PostUpdate)
-- Detect new/changed net_peer_share entities and send to all peers.
-- ALWAYS tracks entities in source_entities (even without peers connected)
-- so that when peers connect later, the catchup code can find them.
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized then return end

    -- Check if we have any connected peers at all
    local has_peers = false
    for _, peer in pairs(state.inbound_peers) do
        if peer.ready then has_peers = true; break end
    end
    if not has_peers then
        for _, peer in pairs(state.outbound_peers) do
            if peer.connected then has_peers = true; break end
        end
    end

    -- ALWAYS track new net_peer_share entities (even without peers)
    local new_shareable = world:query({
        added = { "net_peer_share" },
        with = { "net_sync" },
        without = { "net_peer_mirror" },
    })
    for _, entity in ipairs(new_shareable) do
        local share = entity:get("net_peer_share")
        if share and share.stable_id then
            if not state.source_entities[share.stable_id] then
                -- Track the entity — send will happen when peers connect
                state.source_entities[share.stable_id] = {
                    entity_id = entity:id(),
                    sent_initial = false,
                }

                -- If peers are already connected, send now
                if has_peers then
                    local sync = entity:get("net_sync")
                    send_initial_spawn(world, entity, share, sync)
                end
            end
        end
    end

    -- Only send updates/despawns if we have peers
    if not has_peers then return end

    -- Detect changed synced components → send ENTITY_UPDATE
    send_entity_updates(world)

    -- Detect despawned entities → send ENTITY_DESPAWN
    local removed = world:query({ removed = { "net_peer_share" } })
    for _, entity in ipairs(removed) do
        -- Find which stable_id was removed
        for stable_id, source in pairs(state.source_entities) do
            if source.entity_id == entity:id() then
                broadcast_to_peers(world, {
                    msg_type = Peer.MSG.ENTITY_DESPAWN,
                    stable_id = stable_id,
                })
                state.source_entities[stable_id] = nil
                print(string.format("[NET PEER] Source entity '%s' despawned, notified peers", stable_id))
                break
            end
        end
    end
end, { label = "PeerOutbound" })

---------------------------------------------------------------------------
-- System: PeerAuthoritySwitch (PostUpdate)
-- Watches for `added { "net_peer_switch" }` on entities.
-- Portal (or any other mod) patches net_peer_switch = { target_scope = "..." }
-- to request an authority transfer. This system handles the renet messaging
-- and demotes the entity from source to mirror.
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized then return end

    local switching = world:query({
        added = { "net_peer_switch" },
        with = { "net_owner", "net_peer_share" },
    })
    for _, entity in ipairs(switching) do
        local switch = entity:get("net_peer_switch")
        if not switch or not switch.target_scope then goto continue end

        local net_owner = entity:get("net_owner")
        local share = entity:get("net_peer_share")
        if not net_owner or not share or not share.stable_id then goto continue end

        local client_id = net_owner.client_id
        local stable_id = share.stable_id
        local target_key = switch.target_scope

        -- Send AUTHORITY_SWITCH to the target scope's peer
        local sent = false

        -- Try outbound peers
        for peer_name, peer in pairs(state.outbound_peers) do
            if peer.scope_key == target_key and peer.connected then
                send_to_outbound(world, peer_name, {
                    msg_type = Peer.MSG.AUTHORITY_SWITCH,
                    stable_id = stable_id,
                    client_id = client_id,
                    source_scope_key = state.scope_key,
                })
                sent = true
                break
            end
        end
        -- Try inbound peers
        if not sent then
            for tid, peer in pairs(state.inbound_peers) do
                if peer.scope_key == target_key and peer.ready then
                    send_to_inbound(world, tid, {
                        msg_type = Peer.MSG.AUTHORITY_SWITCH,
                        stable_id = stable_id,
                        client_id = client_id,
                        source_scope_key = state.scope_key,
                    })
                    sent = true
                    break
                end
            end
        end

        if sent then
            print(string.format("[NET PEER] Authority switch: '%s' (client=%s) → scope '%s'",
                stable_id, tostring(client_id), target_key))

            -- Demote: source → mirror
            entity:remove("net_owner")
            entity:remove("net_peer_switch")
            entity:patch({
                net_peer_mirror = {
                    stable_id = stable_id,
                    source_peer = target_key,
                    was_source = true,
                },
            })

            -- Clear stale input so movement/server stops applying velocity
            if entity:has("input_movement") then
                entity:set({ input_movement = {
                    forward = false, backward = false,
                    left = false, right = false,
                    jump = false,
                }})
            end
            -- Zero velocity so the entity stops immediately
            if entity:has("Velocity3d") then
                entity:set({ Velocity3d = { linvel = { x = 0, y = 0, z = 0 }, angvel = { x = 0, y = 0, z = 0 } } })
            end

            -- Update tracking
            state.source_entities[stable_id] = nil
            state.mirror_entities[stable_id] = entity:id()
        else
            print(string.format("[NET PEER] WARN: No peer for scope '%s', cannot switch '%s'",
                target_key, stable_id))
            -- Remove trigger to prevent retry
            entity:remove("net_peer_switch")
        end

        ::continue::
    end
end, { label = "PeerAuthoritySwitch", after = { "PeerOutbound" } })

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Check if we have an active peer connection to a given scope.
function state.is_connected_to(scope_key)
    for _, peer in pairs(state.outbound_peers) do
        if peer.scope_key == scope_key and peer.connected then
            return true
        end
    end
    for _, peer in pairs(state.inbound_peers) do
        if peer.scope_key == scope_key and peer.ready then
            return true
        end
    end
    return false
end
