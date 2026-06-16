-- modules/net/server/init.lua
-- Net server transport layer (instanced).
-- Manages renet connections, entity tracking, sync detection, and outbound replication.

local Net = require("modules/net/shared/net.lua")
local Tracking = require("modules/net/shared/tracking.lua")
local json = require("modules/dkjson.lua")

-- NetInfo resource for this instanced net scope.
-- net_mod's on_loaded hook reads this to discover the side.
local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("NetServerState", {
    next_net_id = 1,
    id_map = Net.create_id_map(),
    clients = {},              -- client_id → { transport_id, ready, owned_net_ids = {} }
    transport_to_client = {},  -- transport_id → client_id
    pending_spawns = Tracking.create_pending_queue(),  -- entity_id → [spawn broadcasts]
    pending_predicts = {},     -- entity_id → { client_id, predicted_eid, parent_net_id, spawn_time }
    initialized = false,
    elapsed_time = 0,          -- ticked in PreUpdate; drives predict-timeout
})

-- Alias for the shared tracking state (tracked, all_synced, synced_dirty)
local ts = Tracking.state()

local PREDICT_TIMEOUT = 5.0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Send a JSON message to a specific client (by stable client_id).
--- Resolves the renet transport_id internally.
--- @param channel number|nil  Defaults to CHANNEL_RELIABLE
local function send_to_client(world, name, client_id, msg, channel)
    local info = state.clients[client_id]
    if not info then return end
    channel = channel or Net.CHANNEL_RELIABLE
    local ok, err = pcall(world.call_resource_method, world, "RenetServer", "send_message",
        name, info.transport_id, channel, json.encode(msg))
    if not ok then
        print(string.format("[NET SERVER] send_message failed: %s", tostring(err)))
    end
end

--- Broadcast a message to all ready clients.
local function broadcast(world, name, msg, exclude_client)
    for client_id, info in pairs(state.clients) do
        if info.ready and client_id ~= exclude_client then
            send_to_client(world, name, client_id, msg)
        end
    end
end

--- Serialize all synced components from an entity for a spawn message.
local function serialize_spawn_components(world, entity, sync_config)
    entity = world:get_entity(entity:id()) -- get full entity
    local components = {}
    for comp_name, _ in pairs(sync_config) do
        local data = entity:get(comp_name)
        if data then
            components[comp_name] = data
        end
    end

    -- Include net_sync config itself so client can set up tracking
    components.net_sync = sync_config
    -- Include net_owner
    local net_owner = entity:get("net_owner")
    if net_owner then
        components.net_owner = net_owner
    end
    -- Include net_mod (always sent; client-side filtering handles per-entry targets)
    local net_mod = entity:get("net_mod")
    if net_mod then
        components.net_mod = net_mod
    end
    return components
end



--- Broadcast a spawn message for a tracked entity.
--- `exclude_client` (optional) is skipped — used so predicting clients don't receive
--- a duplicate SPAWN alongside their SPAWN_CONFIRM.
local function broadcast_spawn(world, entity, net_id, parent_net_id, exclude_client)
    local track = ts.tracked[net_id]
    if not track then return end

    local components = serialize_spawn_components(world, entity, track.sync_config)
    local owner_id = track.prev_owner

    for client_id, info in pairs(state.clients) do
        if not info.ready then goto skip end
        if exclude_client and client_id == exclude_client then goto skip end

        -- Filter components by target
        local filtered = {}
        for comp_name, comp_data in pairs(components) do
            local cfg = track.sync_config[comp_name]
            if cfg then
                local target = cfg.targets or cfg.target or "all"
                if Net.should_send_to(target, client_id, entity, owner_id) then
                    filtered[comp_name] = comp_data
                end
            else
                -- Infrastructure components (net_sync, net_owner) — always send
                filtered[comp_name] = comp_data
            end
        end



        -- Filter net_sync to remove entries for components that were target-filtered
        if filtered.net_sync then
            local filtered_sync = {}
            for comp_name, cfg in pairs(filtered.net_sync) do
                local target = cfg.targets or cfg.target or "all"
                if Net.should_send_to(target, client_id, entity, owner_id) then
                    filtered_sync[comp_name] = cfg
                end
            end
            filtered.net_sync = filtered_sync
        end

        send_to_client(world, net_info.name, client_id, {
            msg_type = Net.MSG.SPAWN,
            net_id = net_id,
            parent_net_id = parent_net_id,
            components = filtered,
        })
        ::skip::
    end
end

--- Broadcast a despawn message.
local function broadcast_despawn(world, net_id)
    broadcast(world, net_info.name, {
        msg_type = Net.MSG.DESPAWN,
        net_id = net_id,
    })
end

--- Send full world state to a newly connected client.
local function send_full_state(world, client_id)
    for net_id, track in pairs(ts.tracked) do
        local entity_id = state.id_map.net_to_entity[net_id]
        if entity_id then
            local entities = world:query({
                with = { "net_sync" },
                optional = { "ChildOf", "net_owner" },
            })
            for _, entity in ipairs(entities) do
                if entity:id() == entity_id then
                    local parent_net_id = Tracking.translate_child_of(entity, state.id_map)
                    local components = serialize_spawn_components(world, entity, track.sync_config)
                    local owner_id = track.prev_owner

                    -- Filter by target for this specific client
                    local filtered = {}
                    for comp_name, comp_data in pairs(components) do
                        local cfg = track.sync_config[comp_name]
                        if cfg then
                            local target = cfg.targets or cfg.target or "all"
                            if Net.should_send_to(target, client_id, entity, owner_id) then
                                filtered[comp_name] = comp_data
                            end
                        else
                            filtered[comp_name] = comp_data
                        end
                    end

                    -- Filter net_sync to remove entries for target-filtered components
                    if filtered.net_sync then
                        local filtered_sync = {}
                        for comp_name, cfg in pairs(filtered.net_sync) do
                            local target = cfg.targets or cfg.target or "all"
                            if Net.should_send_to(target, client_id, entity, owner_id) then
                                filtered_sync[comp_name] = cfg
                            end
                        end
                        filtered.net_sync = filtered_sync
                    end

                    send_to_client(world, net_info.name, client_id, {
                        msg_type = Net.MSG.SPAWN,
                        net_id = net_id,
                        parent_net_id = parent_net_id,
                        components = filtered,
                    })
                    break
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- System: NetServerInit (First)
-- Initialize renet server on `added { "net" }`
---------------------------------------------------------------------------
register_system("First", function(world)
    if state.initialized then return end

    local added = world:query({
        added = { "net" },
        optional = { "net" },
    })
    for _, entity in ipairs(added) do
        local net = entity:get("net")

        -- Validate name
        if not net.name or #net.name == 0 then
            print("[NET SERVER] Net entity must have a name")
            goto skip
        end

        -- Validate port
        if not net.port then
            print("[NET SERVER] Net entity must have a port")
            goto skip
        end

        -- Create Renet resources
        insert_resource("RenetServer", { name = net.name })
        insert_resource("NetcodeServerTransport", {
            name = net.name,
            port = net.port,
            max_clients = net.max_clients or 10,
        })
        
        -- Ensure the net entity is a valid spatial parent.
        -- Children (players, map, etc.) have Transform — Bevy requires
        -- the full parent chain to have Transform for GlobalTransform propagation.
        if not entity:has("Transform") then
            entity:set({ Transform = {} })
        end

        net_info.net_entity_id = entity:id()
        net_info.name = net.name or "default"
        net_info.scope_key = net.scope_key
        net_info.port = net.port
        state.initialized = true
        
        print(string.format("[NET SERVER] '%s' hosting on port %d (mode %s)", net.name, net.port, net.mode))

        break
        ::skip::
    end
end, { label = "NetServerInit" })

---------------------------------------------------------------------------
-- System: NetServerInbound (First)
-- Receive messages from all clients, dispatch handlers.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.initialized then return end

    local net_entities = world:query({ with = { "net" } })
    for _, net_entity in ipairs(net_entities) do
        local net = net_entity:get("net")

        -- New connections (renet gives us transport_ids)
        local ok_nc, new_transports = pcall(world.call_resource_method, world,
            "RenetServer", "get_new_connections", net.name)
        new_transports = ok_nc and new_transports or {}
        for _, transport_id in ipairs(new_transports) do
            -- Read stable client_id from ConnectToken user_data
            -- Returns nil when no player_id was embedded (initial connection)
            local ok_cid, cid_result = pcall(world.call_resource_method, world,
                "RenetServer", "get_client_user_data", transport_id)
            local client_id = (ok_cid and cid_result) or transport_id

            state.clients[client_id] = state.clients[client_id] or {
                transport_id = transport_id,
                ready = false,
                owned_net_ids = {},
            }
            state.clients[client_id].transport_id = transport_id
            state.transport_to_client[transport_id] = client_id

            print(string.format("[NET SERVER] Transport %d connected (client_id=%s, awaiting ack)",
                transport_id, tostring(client_id)))
            send_to_client(world, net.name, client_id, {
                msg_type = Net.MSG.CLIENT_ID,
                client_id = client_id,
            })
        end

        -- Disconnections (renet gives us transport_ids)
        local ok_dc, disconnected = pcall(world.call_resource_method, world,
            "RenetServer", "get_disconnections", net.name)
        disconnected = ok_dc and disconnected or {}
        for _, transport_id in ipairs(disconnected) do
            -- Resolve stable client_id
            local client_id = state.transport_to_client[transport_id]
            if not client_id then goto skip_dc end

            -- Clean up client tracking state
            state.transport_to_client[transport_id] = nil
            state.clients[client_id] = nil

            -- Despawn net_client entity
            for _, nc_entity in ipairs(world:query({ with = { "net_client" } })) do
                local nc = nc_entity:get("net_client")
                if nc and nc.client_id == client_id then
                    despawn(nc_entity)
                    break
                end
            end

            -- Check if server should tear down (no remaining ready clients)
            local has_ready = false
            for _, info in pairs(state.clients) do
                if info.ready then has_ready = true; break end
            end
            if not has_ready and net.port ~= 5001 then
                print(string.format("[NET SERVER] '%s' (port %d): 0 players remaining, tearing down",
                    net.name, net.port))
                -- Free the port allocation so the scope can be re-launched later
                local ok, ports = pcall(define_resource, "PortAllocator", { next_port = 5002, scope_ports = {} })
                if ok and ports and ports.free_by_port then
                    ports.free_by_port(net.port)
                end
                stop_current_script()
                return  -- stop processing, script is shutting down
            end
            ::skip_dc::
        end

        -- Receive messages (renet iterates transport_ids)
        local ok_cl, transports = pcall(world.call_resource_method, world,
            "RenetServer", "clients_id", net.name)
        transports = ok_cl and transports or {}
        for _, transport_id in ipairs(transports) do
            local client_id = state.transport_to_client[transport_id]
            if not client_id then goto skip_transport end
            -- Read incoming messages from both channels
            for _, channel in ipairs({ Net.CHANNEL_RELIABLE, Net.CHANNEL_UNRELIABLE }) do
                while true do
                    local ok_rm, raw = pcall(world.call_resource_method, world, "RenetServer", "receive_message",
                        net.name, transport_id, channel)
                    if not ok_rm or not raw then break end
                    -- print("[NET SERVER] Received: " .. raw)

                    local ok, msg = pcall(json.decode, raw, 1, json.null)
                    if not ok or type(msg) ~= "table" then goto skip end

                    local msg_type = msg.msg_type

                    if msg_type == Net.MSG.CLIENT_ID_ACK then
                        -- Client acknowledged their ID, mark ready
                        if not state.clients[client_id] then goto skip end
                        state.clients[client_id].ready = true
                        local is_observer = msg.observer or false
                        print(string.format("[NET SERVER] '%s' client %s ready%s",
                            net_info.name, tostring(client_id),
                            is_observer and " (observer)" or ""))

                        -- Spawn net_client entity (ECS-native connect signal)
                        spawn({ net_client = {
                            client_id = client_id,
                            observer = is_observer,
                        } }):with_parent(net_entity:id())

                        -- Send full world state
                        send_full_state(world, client_id)

                    elseif msg_type == Net.MSG.UPDATE then
                        -- Client-authoritative component update
                        local net_id = msg.net_id
                        local entity_id = state.id_map.net_to_entity[net_id]
                        if not entity_id then goto skip end

                        local track = ts.tracked[net_id]
                        if not track then goto skip end

                        local entities = world:query({
                            with = { "net_sync" },
                            optional = { "net_owner" },
                        })
                        for _, entity in ipairs(entities) do
                            if entity:id() == entity_id then
                                -- Verify authority
                                for comp_name, comp_data in pairs(msg.components or {}) do
                                    local cfg = track.sync_config[comp_name]
                                    if cfg and cfg.authority == "client" then
                                        -- Verify this client is the owner
                                        local owner = entity:get("net_owner")
                                        if owner and owner.client_id == client_id then
                                            if entity:has("net_sync_" .. comp_name) then
                                                entity:set({ ["net_sync_" .. comp_name] = comp_data })
                                            else
                                                entity:patch({ [comp_name] = comp_data })
                                            end
                                        end
                                    end
                                end
                                break
                            end
                        end

                    elseif msg_type == Net.MSG.SPAWN_REQUEST then
                        -- Do NOT trust the client's components. Spawn a shadow
                        -- entity with only `net_predict` (carrying the request
                        -- as a payload) + server-assigned `net_owner`. Mods
                        -- react to `added { net_predict }`, validate fields of
                        -- `net_predict.requested`, then `entity:set(...)` the
                        -- specific components they vouch for before removing
                        -- `net_predict` to approve.
                        local entity = spawn({
                            net_predict = {
                                client_id = client_id,
                                predicted_eid = msg.predicted_eid,
                                requested = msg.components or {},
                            },
                            net_owner = { client_id = client_id },
                        })
                        state.pending_predicts[entity:id()] = {
                            client_id = client_id,
                            predicted_eid = msg.predicted_eid,
                            parent_net_id = msg.parent_net_id,
                            spawn_time = state.elapsed_time,
                        }
                        print(string.format(
                            "[NET SERVER] Pending predict: entity=%d client=%d predicted_eid=%d",
                            entity:id(), client_id, msg.predicted_eid))

                    elseif msg_type == Net.MSG.DESPAWN_REQUEST then
                        -- Verify client ownership
                        local net_id = msg.net_id
                        local entity_id = state.id_map.net_to_entity[net_id]
                        if entity_id then
                            local entities = world:query({
                                with = { "net_sync" },
                                optional = { "net_owner" },
                            })
                            for _, entity in ipairs(entities) do
                                if entity:id() == entity_id then
                                    local owner = entity:get("net_owner")
                                    if owner and owner.client_id == client_id then
                                        -- Valid: despawn (NetSyncTrack will broadcast)
                                        despawn(entity_id)
                                    else
                                        -- Reject: re-spawn on the client
                                        local track = ts.tracked[net_id]
                                        if track then
                                            local parent_net_id = Tracking.translate_child_of(entity, state.id_map)
                                            local components = serialize_spawn_components(world, entity, track.sync_config)
                                            send_to_client(world, net_info.name, client_id, {
                                                msg_type = Net.MSG.SPAWN,
                                                net_id = net_id,
                                                parent_net_id = parent_net_id,
                                                components = components,
                                            })
                                        end
                                    end
                                    break
                                end
                            end
                        end

                    elseif msg_type == Net.MSG.RTT_PING then
                        send_to_client(world, net_info.name, client_id, {
                            msg_type = Net.MSG.RTT_PONG,
                            t = msg.t,
                        }, Net.CHANNEL_RELIABLE)

                    else
                        -- Inject the sender so mods can identify the client.
                        msg.client_id = client_id
                        -- Always fire a generic `net:receive` so mods can read
                        -- without knowing the message type up front.
                        world:write_event("net:receive", msg)
                        -- Try registered handlers, fallback to a typed event.
                        if not Net.dispatch(world, msg, client_id) then
                            world:write_event("net:" .. msg_type, msg)
                        end
                    end

                    ::skip::
                end
            end
            ::skip_transport::
        end
    end

end, { label = "NetServerInbound" })

---------------------------------------------------------------------------
-- System: NetServerTime (PreUpdate)
-- Advance elapsed_time used by predict-timeout.
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    state.elapsed_time = state.elapsed_time + world:delta_time()
end, { label = "NetServerTime" })

---------------------------------------------------------------------------
-- System: NetPredictFinalize (PostUpdate)
-- Sweep pending-predict entities after game mods have had a chance to react.
--   • entity gone (mod called despawn)             → SPAWN_REJECT
--   • entity alive, `net_predict` removed (approve)→ allocate net_id,
--       SPAWN_CONFIRM to predictor, broadcast SPAWN to others
--   • entity still has `net_predict` past timeout  → despawn (next tick rejects)
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized then return end

    for entity_id, pending in pairs(state.pending_predicts) do
        local entity = world:get_entity(entity_id)

        if not entity then
            -- Despawned by a mod (or by the timeout branch last tick) → reject.
            send_to_client(world, net_info.name, pending.client_id, {
                msg_type = Net.MSG.SPAWN_REJECT,
                predicted_eid = pending.predicted_eid,
            })
            state.pending_predicts[entity_id] = nil
            print(string.format("[NET SERVER] Predict rejected: entity=%d predicted_eid=%d",
                entity_id, pending.predicted_eid))

        elseif not entity:has("net_predict") then
            -- Approved → allocate net_id, install tracking, broadcast.
            local net_id = state.next_net_id; state.next_net_id = net_id + 1
            Net.map(state.id_map, net_id, entity_id)

            local sync_config = entity:get("net_sync") or {}
            local owner = entity:get("net_owner")
            ts.tracked[net_id] = {
                sync_config = sync_config,
                prev_owner = owner and owner.client_id or nil,
            }
            ts.synced_dirty = true

            send_to_client(world, net_info.name, pending.client_id, {
                msg_type = Net.MSG.SPAWN_CONFIRM,
                net_id = net_id,
                predicted_eid = pending.predicted_eid,
            })

            local parent_net_id = Tracking.translate_child_of(entity, state.id_map)
                                  or pending.parent_net_id
            broadcast_spawn(world, entity, net_id, parent_net_id, pending.client_id)

            state.pending_predicts[entity_id] = nil
            print(string.format("[NET SERVER] Predict approved: entity=%d net_id=%d",
                entity_id, net_id))

        elseif state.elapsed_time - pending.spawn_time > PREDICT_TIMEOUT then
            -- Timed out while still pending → despawn; next tick will reject.
            despawn(entity)
            print(string.format("[NET SERVER] Predict timeout: entity=%d", entity_id))
        end
    end
end, { label = "NetPredictFinalize" })

---------------------------------------------------------------------------
-- System: NetSyncTrack (First)
-- Tracks net_sync add/change/remove, reparenting, and ownership changes.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.initialized then return end

    -- Pass 1: net_sync added/changed/removed
    local changes = Tracking.detect_sync_changes(world)

    -- Added: allocate net_id, track, broadcast spawn (with parent queueing)
    for _, entity in ipairs(changes.added) do
        local net_id = state.next_net_id; state.next_net_id = net_id + 1
        Net.map(state.id_map, net_id, entity:id())
        local owner = entity:get("net_owner")
        ts.tracked[net_id] = {
            sync_config = entity:get("net_sync"),
            prev_owner = owner and owner.client_id or nil,
        }
        ts.synced_dirty = true

        -- Resolve parent's net_id for the spawn message
        local parent_net_id = Tracking.translate_child_of(entity, state.id_map)
        local child_of = entity:get("ChildOf")
        local parent_entity = child_of and world:get_entity(child_of)

        if parent_entity and parent_entity:has("net_sync") and not parent_net_id then
            -- Parent exists but doesn't have a net_id yet → queue
            Tracking.queue_pending(state.pending_spawns, child_of, {
                net_id = net_id, entity = entity,
            })
        else
            -- Parent resolved (or no parent) → broadcast immediately
            broadcast_spawn(world, entity, net_id, parent_net_id)
        end

        -- Flush any children that were waiting for THIS entity's net_id
        local waiting = Tracking.flush_pending(state.pending_spawns, entity:id())

        if waiting then
            for _, pending in ipairs(waiting) do
                broadcast_spawn(world, pending.entity, pending.net_id, net_id)
            end
        end

    end

    -- Changed: diff config, send per-client filtered updates
    for _, entity in ipairs(changes.changed) do
        local net_id = state.id_map.entity_to_net[entity:id()]
        if not net_id then goto skip_changed end

        local old_config = ts.tracked[net_id].sync_config
        local new_config = entity:get("net_sync")
        ts.tracked[net_id].sync_config = new_config
        ts.synced_dirty = true

        local owner_id = ts.tracked[net_id].prev_owner

        for client_id, info in pairs(state.clients) do
            if not info.ready then goto skip_sync_client end

            -- Filter net_sync: strip entries this client shouldn't see
            local filtered_sync = {}
            for comp_name, cfg in pairs(new_config) do
                local target = cfg.targets or cfg.target or "all"
                if Net.should_send_to(target, client_id, entity, owner_id) then
                    filtered_sync[comp_name] = cfg
                end
            end

            local update_components = { net_sync = filtered_sync }
            -- Include net_mod if the entity has it (always sent to all;
            -- client-side filter_entries_for_client handles per-entry targets).
            -- Must use full entity — query result only exposes queried components.
            local full_entity = world:get_entity(entity:id())
            local net_mod_data = full_entity and full_entity:get("net_mod")
            if net_mod_data then
                update_components.net_mod = net_mod_data
            end

            send_to_client(world, net_info.name, client_id, {
                msg_type = Net.MSG.UPDATE,
                net_id = net_id,
                components = update_components,
            })

            -- Send newly-added component data (only if target matches).
            -- Uses full_entity since query result can't access arbitrary components.
            if full_entity then
                for comp_name, _ in pairs(new_config) do
                    if not old_config[comp_name] then
                        local cfg = new_config[comp_name]
                        local target = cfg.targets or cfg.target or "all"
                        if Net.should_send_to(target, client_id, entity, owner_id) then
                            local data = full_entity:get(comp_name)
                            if data then
                                send_to_client(world, net_info.name, client_id, {
                                    msg_type = Net.MSG.UPDATE,
                                    net_id = net_id,
                                    components = { [comp_name] = data },
                                })
                            end
                        end
                    end
                end
            end

            ::skip_sync_client::
        end
        ::skip_changed::
    end

    -- Removed: broadcast despawn, clean tracking
    for _, entity in ipairs(changes.removed) do
        local net_id = state.id_map.entity_to_net[entity:id()]
        if net_id then

            broadcast_despawn(world, net_id)
            Net.unmap(state.id_map, net_id, entity:id())
            ts.tracked[net_id] = nil
            ts.synced_dirty = true
        end
    end

    -- Pass 2: reparenting (ChildOf changed)
    local entered, left = Tracking.detect_reparented(
        world, state.id_map
    )

    for _, entity in ipairs(left) do
        local net_id = state.id_map.entity_to_net[entity:id()]
        if net_id then
            broadcast_despawn(world, net_id)
            Net.unmap(state.id_map, net_id, entity:id())
            ts.tracked[net_id] = nil
            ts.synced_dirty = true
        end
    end

    for _, entity in ipairs(entered) do
        local net_id = state.next_net_id; state.next_net_id = net_id + 1
        Net.map(state.id_map, net_id, entity:id())
        local owner = entity:get("net_owner")
        ts.tracked[net_id] = {
            sync_config = entity:get("net_sync"),
            prev_owner = owner and owner.client_id or nil,
        }
        ts.synced_dirty = true
        broadcast_spawn(world, entity, net_id, Tracking.translate_child_of(entity, state.id_map))
    end

    -- Pass 3: ownership changes
    local ownership_changed = Tracking.detect_ownership_changes(world)

    for _, entity in ipairs(ownership_changed) do
        local new_owner = entity:get("net_owner")
        local new_cid = new_owner and new_owner.client_id or nil

        -- Propagate to all descendant net_sync entities
        local descendants = world:query({
            with = { "net_sync" },
            optional = { "net_sync", "net_owner" },
            entities = { entity:id() },
        })
        for _, desc in ipairs(descendants) do
            if desc:id() ~= entity:id() then
                if new_owner then
                    desc:patch({ net_owner = new_owner })
                else
                    desc:remove("net_owner")
                end
            end
        end

        -- Broadcast net_owner change/removal to all clients
        local net_id = state.id_map.entity_to_net[entity:id()]
        if net_id then
            -- Send net_owner update to all connected clients
            local owner_data = new_owner or json.null
            for client_id, info in pairs(state.clients) do
                if info.ready then
                    send_to_client(world, net_info.name, client_id, {
                        msg_type = Net.MSG.UPDATE,
                        net_id = net_id,
                        components = { net_owner = owner_data },
                    })
                end
            end
            local track = ts.tracked[net_id]
            local old_cid = track.prev_owner
            track.prev_owner = new_cid

            for comp_name, cfg in pairs(track.sync_config) do
                local target = cfg.targets or cfg.target or "all"
                
                local old_received = old_cid and Net.should_send_to(target, old_cid, entity, old_cid)
                local new_received = new_cid and Net.should_send_to(target, new_cid, entity, new_cid)
                local old_still_receives = old_cid and Net.should_send_to(target, old_cid, entity, new_cid)
                
                -- Send full component to new owner if they now receive it
                if new_received and new_cid then
                    local data = entity:get(comp_name)
                    if data then
                        send_to_client(world, net_info.name, new_cid, {
                            msg_type = Net.MSG.UPDATE,
                            net_id = net_id,
                            components = { [comp_name] = data },
                        })
                    end
                end
                
                -- Remove from old owner if they no longer receive it
                if old_received and not old_still_receives and old_cid and old_cid ~= new_cid then
                    send_to_client(world, net_info.name, old_cid, {
                        msg_type = Net.MSG.UPDATE,
                        net_id = net_id,
                        components = { [comp_name] = json.null },
                    })
                end
            end
        end
    end
end, { label = "NetSyncTrack", after = { "NetModLoader", "NetModBaseSync" } })

---------------------------------------------------------------------------
-- System: NetServerOutbound (PostUpdate)
-- Send changed synced component data to clients (delta only).
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized then return end

    -- Rebuild cached list only when tracking changed
    -- Efficient query: only entities with ≥1 changed synced component
    local entities = Tracking.get_changed_entities(world)

    for _, entity in ipairs(entities) do
        local net_id = state.id_map.entity_to_net[entity:id()]
        if not net_id then goto continue end
        local track = ts.tracked[net_id]
        if not track then goto continue end

        local changed = Tracking.collect_changed_components(entity, track.sync_config)
        if not next(changed) then goto continue end


        local owner_id = track.prev_owner

        for client_id, info in pairs(state.clients) do
            if not info.ready then goto skip_client end

            -- Split into reliable/unreliable buckets
            local reliable, unreliable = {}, {}
            for comp_name, comp_data in pairs(changed) do
                local cfg = track.sync_config[comp_name]
                if not cfg then goto skip_comp end

                -- Skip client-auth components TO the owner (they have latest)
                if cfg.authority == "client" and client_id == owner_id then
                    goto skip_comp
                end

                -- Apply target filter
                local target = cfg.targets or cfg.target or "all"
                if Net.should_send_to(target, client_id, entity, owner_id) then
                    if cfg.reliable == false then
                        unreliable[comp_name] = comp_data
                    else
                        reliable[comp_name] = comp_data
                    end
                end

                ::skip_comp::
            end

            if next(reliable) then
                send_to_client(world, net_info.name, client_id, {
                    msg_type = Net.MSG.UPDATE,
                    net_id = net_id,
                    components = reliable,
                }, Net.CHANNEL_RELIABLE)
            end

            if next(unreliable) then
                send_to_client(world, net_info.name, client_id, {
                    msg_type = Net.MSG.UPDATE,
                    net_id = net_id,
                    components = unreliable,
                }, Net.CHANNEL_UNRELIABLE)
            end

            ::skip_client::
        end

        ::continue::
    end
end, { label = "NetServerOutbound", after = { "NetSyncTrack" } })

---------------------------------------------------------------------------
-- System: NetServerSendToClient (PostUpdate)
-- Allows mods to send targeted messages to specific clients via events.
-- Mods write: world:write_event("net:send_to_client", {
--     client_id = N, msg = { msg_type = "...", ... }
-- })
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized then return end
    local events = world:read_events("net:send_to_client") or {}
    for _, evt in ipairs(events) do
        if evt.client_id and evt.msg then
            send_to_client(world, net_info.name, evt.client_id, evt.msg)
        end
    end
end, { label = "NetServerSendToClient", after = { "NetServerOutbound" } })

