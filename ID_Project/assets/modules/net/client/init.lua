-- modules/net/client/init.lua
-- Net client transport layer (instanced).
-- Manages renet connection, spawn/update/despawn handling, and client-authoritative outbound.

local Net = require("modules/net/shared/net.lua")
local Tracking = require("modules/net/shared/tracking.lua")
local json = require("modules/dkjson.lua")

-- Generic client-side prediction + replay reconciliation (registers its own systems
-- and an RTT_PONG handler in this scope; opt-in via net_sync `predict = true`).
require("modules/net/client/predict.lua")

-- NetInfo resource for this instanced net scope.
-- net_mod's on_loaded hook reads this to discover the side.
local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "client"

local state = define_resource("NetClientState", {
    client_id = nil,
    connected = false,
    id_map = Net.create_id_map(),
    pending_spawns = Tracking.create_pending_queue(),  -- parent_net_id → [{ net_id, entity_id }]
    next_predicted = -1,
    predicted = {},             -- predicted_eid → { entity_id, spawn_time }
    predicted_by_eid = {},      -- entity_id → predicted_eid (reverse map; defends against duplicate prediction)
    server_despawned = {},      -- net_id → true (prevent echo on client-initiated despawn)
    initialized = false,
    elapsed_time = 0,           -- ticked in PreUpdate; drives prediction timeout
})

-- Alias for the shared tracking state (tracked, all_synced, synced_dirty)
local ts = Tracking.state()

local PREDICT_TIMEOUT = 5.0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Send a JSON message to the server.
--- @param channel number|nil  Defaults to CHANNEL_RELIABLE
local function send_to_server(world, name, msg, channel)
    channel = channel or Net.CHANNEL_RELIABLE
    local ok, err = pcall(world.call_resource_method, world, "RenetClient", "send_message",
        name, channel, json.encode(msg))
    if not ok then
        print(string.format("[NET CLIENT] send_message failed: %s", tostring(err)))
    end
end

---------------------------------------------------------------------------
-- System: NetClientInit (First)
-- Initialize renet client on `added { "net" }`
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
            print("[NET CLIENT] Net entity must have a name")
            goto skip
        end

        -- Validate port
        if not net.port then
            print("[NET CLIENT] Net entity must have a port")
            goto skip
        end

        insert_resource("RenetClient", { name = net.name })
        insert_resource("NetcodeClientTransport", {
            name = net.name,
            server_addr = net.ip,
            port = net.port,
            player_id = net.player_id,  -- embedded in ConnectToken as stable client_id (nil = server assigns)
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
        state.observer = net.observer or false
        state.initialized = true
        
        print(string.format("[NET CLIENT] '%s' connecting to %s:%d%s",
            net.name, net.ip, net.port,
            state.observer and " (observer)" or ""))

        break
        ::skip::
    end
end, { label = "NetClientInit" })

---------------------------------------------------------------------------
-- System: NetClientInbound (First)
-- Process all incoming messages from the server.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.initialized then return end

    local net_entities = world:query({ with = { "net" } })
    for _, net_entity in ipairs(net_entities) do
        local net = net_entity:get("net")
    
        -- Receive messages from both channels
        for _, channel in ipairs({ Net.CHANNEL_RELIABLE, Net.CHANNEL_UNRELIABLE }) do
            while true do
                local ok_rm, raw = pcall(world.call_resource_method, world, "RenetClient", "receive_message",
                    net.name, channel)
                if not ok_rm or not raw then break end
                -- print("[NET CLIENT] Received: " .. raw)

                local ok, msg = pcall(json.decode, raw, 1, json.null)
                if not ok or type(msg) ~= "table" then goto skip end

                local msg_type = msg.msg_type

                if msg_type == Net.MSG.CLIENT_ID then
                    -- Server assigned us a stable client_id
                    state.client_id = msg.client_id
                    net_info.client_id = msg.client_id
                    state.connected = true
                    print(string.format("[NET CLIENT] '%s' assigned client_id=%s",
                        net.name, tostring(state.client_id)))

                    -- Acknowledge
                    send_to_server(world, net.name, {
                        msg_type = Net.MSG.CLIENT_ID_ACK,
                        client_id = state.client_id,
                        observer = state.observer or nil,
                    })

                elseif msg_type == Net.MSG.SPAWN then
                    -- print("[NET CLIENT] Spawn Received: " .. raw)
                    -- Defense-in-depth: skip if we already track this net_id
                    -- (e.g., predicted entity was confirmed and the server also broadcast).
                    if state.id_map.net_to_entity[msg.net_id] then goto skip end

                    -- Server spawned an entity
                    local entity = spawn(msg.components)
                    local entity_id = entity:id()
                    Net.map(state.id_map, msg.net_id, entity_id)
                    ts.tracked[msg.net_id] = {
                        sync_config = msg.components.net_sync or {},
                    }
                    ts.synced_dirty = true

                    -- Resolve parent (uses net_id as key since that's what the server sends)
                    if msg.parent_net_id then
                        local parent_eid = state.id_map.net_to_entity[msg.parent_net_id]
                        if parent_eid then
                            entity:with_parent(parent_eid)
                        else
                            Tracking.queue_pending(state.pending_spawns, msg.parent_net_id, {
                                net_id = msg.net_id, entity_id = entity_id,
                            })
                        end
                    end

                    -- Flush children waiting for THIS entity's net_id as their parent
                    local waiting = Tracking.flush_pending(state.pending_spawns, msg.net_id)
                    if waiting then
                        for _, p in ipairs(waiting) do
                            local child = world:get_entity(p.entity_id)
                            if child then child:with_parent(entity_id) end
                        end
                    end

                    print("info", "[NET CLIENT] Spawned net_id=" .. tostring(msg.net_id) ..
                        " entity=" .. tostring(entity_id))

                elseif msg_type == Net.MSG.UPDATE then
                    -- Server sent component updates
                    local eid = state.id_map.net_to_entity[msg.net_id]
                    if not eid then goto skip end

                    local entity = world:get_entity(eid)
                    if not entity then goto skip end

                    for comp_name, comp_data in pairs(msg.components or {}) do
                        if comp_name == "net_sync" then
                            -- Update tracked sync config
                            entity:set({ net_sync = comp_data })
                            ts.tracked[msg.net_id].sync_config = comp_data
                            ts.synced_dirty = true
                        elseif comp_data == nil or comp_data == json.null then
                            -- Owner-targeted removal
                            entity:remove(comp_name)
                        elseif entity:has("net_sync_" .. comp_name) then
                            -- Intercept: write to shadow component
                            entity:set({ ["net_sync_" .. comp_name] = comp_data })
                        else
                            -- Direct patch
                            entity:patch({ [comp_name] = comp_data })
                        end
                    end

                elseif msg_type == Net.MSG.DESPAWN then
                    -- Server despawned an entity
                    state.server_despawned[msg.net_id] = true
                    local eid = state.id_map.net_to_entity[msg.net_id]
                    if eid then
                        Net.unmap(state.id_map, msg.net_id, eid)
                        ts.tracked[msg.net_id] = nil
                        ts.synced_dirty = true
                        despawn(eid)
                        print("info", "[NET CLIENT] Despawned net_id=" .. tostring(msg.net_id))
                    end

                elseif msg_type == Net.MSG.SPAWN_CONFIRM then
                    -- Server confirmed a predicted spawn → remap, populate tracking, drop marker.
                    local pred = state.predicted[msg.predicted_eid]
                    if pred then
                        local eid = pred.entity_id
                        local entity = world:get_entity(eid)
                        if entity then
                            Net.map(state.id_map, msg.net_id, eid)
                            ts.tracked[msg.net_id] = {
                                sync_config = entity:get("net_sync") or {},
                            }
                            ts.synced_dirty = true
                            entity:remove("net_predict")
                        end
                        state.predicted[msg.predicted_eid] = nil
                        state.predicted_by_eid[eid] = nil
                        print("[NET CLIENT] Spawn confirmed: predicted=" ..
                            tostring(msg.predicted_eid) .. " → net_id=" .. tostring(msg.net_id))
                    end

                elseif msg_type == Net.MSG.SPAWN_REJECT then
                    -- Server rejected a predicted spawn — despawn the predicted entity
                    local pred = state.predicted[msg.predicted_eid]
                    if pred then
                        despawn(pred.entity_id)
                        state.predicted[msg.predicted_eid] = nil
                        state.predicted_by_eid[pred.entity_id] = nil
                        print("info", "[NET CLIENT] Spawn rejected: predicted=" ..
                            tostring(msg.predicted_eid))
                    end

                else
                    -- Try registered handlers, fallback to event
                    if not Net.dispatch(world, msg, nil) then
                        world:write_event("net:" .. msg_type, msg)
                    end
                end

                ::skip::
            end
        end
    end
end, { label = "NetClientInbound" })

---------------------------------------------------------------------------
-- System: NetLocalMarker (First, after NetClientInbound)
-- Patches `net_local = true` on entities owned by this client.
-- Removes it when ownership transfers to another client.
-- Any mod can query { with = { "net_local" } } to find the local player.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.client_id then return end

    local entities = world:query({
        ["or"] = { added = { "net_owner" }, changed = { "net_owner" } },
        optional = { "net_local" },
    })
    for _, entity in ipairs(entities) do
        local owner = entity:get("net_owner")
        local is_mine = owner and owner.client_id == state.client_id
        local was_mine = entity:get("net_local")

        if is_mine and not was_mine then
            entity:patch({ net_local = true })
            print(string.format("[NET CLIENT] +net_local entity=%d client_id=%s",
                entity:id(), tostring(state.client_id)))
        elseif not is_mine and was_mine then
            entity:remove("net_local")
            print(string.format("[NET CLIENT] -net_local entity=%d (owner=%s, me=%s)",
                entity:id(), tostring(owner and owner.client_id), tostring(state.client_id)))
        end
    end

    -- Also handle net_owner removal (entity no longer owned by anyone)
    local removed = world:query({
        removed = { "net_owner" },
        with = { "net_local" },
    })
    for _, entity in ipairs(removed) do
        entity:remove("net_local")
        print(string.format("[NET CLIENT] -net_local (owner removed) entity=%d", entity:id()))
    end
end, { label = "NetLocalMarker", after = { "NetClientInbound" } })

---------------------------------------------------------------------------
-- System: NetClientTime (PreUpdate)
-- Advance elapsed_time used by prediction timeout.
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    state.elapsed_time = state.elapsed_time + world:delta_time()
end, { label = "NetClientTime" })

---------------------------------------------------------------------------
-- System: NetPredictTrack (First, after NetClientInbound)
-- Detects locally-spawned net_sync entities (i.e., `added { net_sync }` for
-- entities that aren't in the server-assigned id_map) and treats them as
-- predicted: marks `net_local`, auto-patches `net_predict`, allocates a
-- predicted_eid, and sends SPAWN_REQUEST to the server.
--
-- Users don't need to write `net_predict = {}` in their spawn — adding
-- `net_sync` to a fresh client-side entity is the signal.
---------------------------------------------------------------------------
register_system("First", function(world)
    if not state.initialized or not state.connected then return end

    local entities = world:query({
        added = { "net_sync" },
    })
    if #entities == 0 then return end

    local net_entities = world:query({ with = { "net" } })
    if #net_entities == 0 then return end
    local net_name = net_entities[1]:get("net").name

    for _, entity in ipairs(entities) do
        local eid = entity:id()

        -- Skip entities that came from the server (already in id_map).
        if state.id_map.entity_to_net[eid] then goto continue end
        -- Defensive: skip if we've already started predicting this entity.
        if state.predicted_by_eid[eid] then goto continue end

        local predicted_eid = state.next_predicted
        state.next_predicted = state.next_predicted - 1

        state.predicted[predicted_eid] = {
            entity_id = eid,
            spawn_time = state.elapsed_time,
        }
        state.predicted_by_eid[eid] = predicted_eid

        -- Mark net_local + net_predict immediately so mods can query
        -- { with = "net_local" } and `added { net_predict, … }` before the
        -- server has confirmed the spawn.
        entity:patch({ net_local = true, net_predict = {} })

        -- The query-result entity is filtered to the queried components only,
        -- so entity:get("net_mod"), entity:get("placement"), etc. would return
        -- nil even though those components exist. Refetch the full snapshot
        -- (same pattern as net/server's serialize_spawn_components).
        local full = world:get_entity(eid) or entity
        local components = Tracking.collect_predict_components(full)
        local parent_net_id = nil
        local child_of = full:get("ChildOf")
        if child_of then parent_net_id = state.id_map.entity_to_net[child_of] end

        send_to_server(world, net_name, {
            msg_type = Net.MSG.SPAWN_REQUEST,
            predicted_eid = predicted_eid,
            components = components,
            parent_net_id = parent_net_id,
        })

        print(string.format("[NET CLIENT] Predict spawn: entity=%d predicted_eid=%d",
            eid, predicted_eid))

        ::continue::
    end
end, { label = "NetPredictTrack", after = { "NetClientInbound" } })

---------------------------------------------------------------------------
-- System: NetSend (PostUpdate)
-- Drain `net:send` events and forward each message to the server.
-- Mods write { msg_type = "...", payload = { ... } } to send custom messages.
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized or not state.connected then return end
    local events = world:read_events("net:send") or {}
    if #events == 0 then return end

    local net_entities = world:query({ with = { "net" } })
    if #net_entities == 0 then return end
    local net_name = net_entities[1]:get("net").name

    for _, evt in ipairs(events) do
        send_to_server(world, net_name, evt)
    end
end, { label = "NetSend" })

---------------------------------------------------------------------------
-- System: NetPredictTimeout (Last)
-- Despawn predicted entities that have been pending longer than PREDICT_TIMEOUT.
---------------------------------------------------------------------------
register_system("Last", function(world)
    if not state.initialized then return end
    local now = state.elapsed_time
    for pred_eid, pred in pairs(state.predicted) do
        if now - pred.spawn_time > PREDICT_TIMEOUT then
            local entity = world:get_entity(pred.entity_id)
            if entity then despawn(entity) end
            state.predicted[pred_eid] = nil
            state.predicted_by_eid[pred.entity_id] = nil
            print(string.format("[NET CLIENT] Predict timeout: predicted_eid=%d", pred_eid))
        end
    end
end, { label = "NetPredictTimeout" })

---------------------------------------------------------------------------
-- System: NetClientOutbound (PostUpdate)
-- Send client-authoritative component changes to the server.
-- Also handles client-initiated despawn requests.
---------------------------------------------------------------------------
register_system("PostUpdate", function(world)
    if not state.initialized or not state.connected then return end

    local net_entities = world:query({ with = { "net" } })
    for _, net_entity in ipairs(net_entities) do
        local net = net_entity:get("net")

        -- Send client-authoritative component updates
        local entities = Tracking.get_changed_entities(world)
        for _, entity in ipairs(entities) do
            local net_id = state.id_map.entity_to_net[entity:id()]
            if not net_id then goto continue end
            local track = ts.tracked[net_id]
            if not track then goto continue end

            local reliable, unreliable = {}, {}
            for comp_name, cfg in pairs(track.sync_config) do
                -- Only send components where client has authority AND it changed
                if cfg.authority == "client" and entity:is_changed(comp_name) then
                    local data = entity:get(comp_name)
                    if cfg.reliable == false then
                        unreliable[comp_name] = data
                    else
                        reliable[comp_name] = data
                    end
                end
            end

            if next(reliable) then
                send_to_server(world, net.name, {
                    msg_type = Net.MSG.UPDATE,
                    net_id = net_id,
                    components = reliable,
                }, Net.CHANNEL_RELIABLE)
            end

            if next(unreliable) then
                send_to_server(world, net.name, {
                    msg_type = Net.MSG.UPDATE,
                    net_id = net_id,
                    components = unreliable,
                }, Net.CHANNEL_UNRELIABLE)
            end

            ::continue::
        end

        -- Client-initiated despawn requests
        local sync_changes = Tracking.detect_sync_changes(world)
        for _, entity in ipairs(sync_changes.removed) do
            local net_id = state.id_map.entity_to_net[entity:id()]
            if net_id and not state.server_despawned[net_id] then
                -- Client initiated this despawn → request server confirmation
                send_to_server(world, net.name, {
                    msg_type = Net.MSG.DESPAWN_REQUEST,
                    net_id = net_id,
                })
            end
            -- Clean up tracking regardless
            if net_id then
                state.server_despawned[net_id] = nil
                Net.unmap(state.id_map, net_id, entity:id())
                ts.tracked[net_id] = nil
                ts.synced_dirty = true
            end
        end
    end
end, { label = "NetClientOutbound" })
