-- modules/player/spawner/init.lua
-- Server-only player spawner: manages spawn points + player entity lifecycle.
-- Loaded via `mod` (not net_mod) on the server only.
-- Reacts to net_client entities (added/removed) instead of events.
-- client_id is the stable cross-server identity.

local NUM_SPAWNS = 8
local SPAWN_RADIUS = 3.0
local SPAWN_HEIGHT = 5.0

local spawner_state = define_resource("PlayerSpawnerState", {
    spawn_points = {},     -- index → { entity_id, occupied, client_id }
    player_entities = {},  -- client_id → entity_id
    spawner_entity_id = nil,
})


---------------------------------------------------------------------------
-- Init: create spawn point entities in a circle
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ with = { "player/spawner" } })
    for _, entity in ipairs(entities) do

        spawner_state.spawner_entity_id = entity:id()

        -- The spawner is always a child of the net entity (by construction)
        local parent_id = entity:get("ChildOf")
        if parent_id then
            spawner_state.net_entity_id = parent_id
        end

        -- Create spawn points in a circle
        for i = 1, NUM_SPAWNS do
            local angle = (i / NUM_SPAWNS) * 2 * math.pi
            local x = math.cos(angle) * SPAWN_RADIUS
            local z = math.sin(angle) * SPAWN_RADIUS

            local sp = spawn({
                spawn_point = { occupied = false, index = i },
                Transform = { translation = { x = x, y = SPAWN_HEIGHT, z = z } },
            }):with_parent(entity:id())

            spawner_state.spawn_points[i] = {
                entity_id = sp:id(),
                occupied = false,
                client_id = nil,
            }
        end

        print(string.format("[PLAYER/SPAWNER] Created %d spawn points (radius=%.1f)",
            NUM_SPAWNS, SPAWN_RADIUS))

        return true -- done
    end
end)

---------------------------------------------------------------------------
-- Handle client connections: react to added { "net_client" }
-- Optionally reads net_transfer for cross-scope position restoration.
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    for _, entity in ipairs(world:query({
        ["or"] = { added = { "net_client" }, changed = { "net_client" } },
        optional = { "net_transfer" },
    })) do
        local nc = entity:get("net_client")
        if not nc then goto continue end

        local client_id = nc.client_id

        -- Double-spawn guard: skip if this client already has a player
        if spawner_state.player_entities[client_id] then
            goto continue
        end

        -- Observer clients don't get a player spawned immediately.
        -- Their player will arrive via net_peer authority switch (portal crossing).
        -- When that happens, net_peer patches net_client.synced_state, triggering
        -- the `changed { net_client }` path which creates the player with synced state.
        -- synced_state overrides observer — it means "authority switch happened, spawn now."
        if nc.observer and not nc.synced_state then
            print(string.format("[PLAYER/SPAWNER] Skipping spawn for observer client %s",
                tostring(client_id)))
            goto continue
        end

        -- Get net entity: from init, or from net_client's parent (both are children of net entity)
        local net_entity_id = define_resource("NetInfo", {}).net_entity_id or spawner_state.net_entity_id
        spawner_state.net_entity_id = net_entity_id

        if not net_entity_id then
            print(string.format("[PLAYER/SPAWNER] ERROR: No net entity for client %s", tostring(client_id)))
            goto continue
        end

        -- Determine spawn position:
        -- 1. Portal promotion: use synced state from mirror (synced_state)
        -- 2. Transfer data: cross-scope position restoration
        -- 3. Spawn point: default
        local transfer = entity:get("net_transfer")
        local synced_state = nc.synced_state
        local spawn_pos

        if synced_state and synced_state.Transform and synced_state.Transform.translation then
            -- Portal promotion: use mirror's position
            spawn_pos = synced_state.Transform.translation
            print(string.format("[PLAYER/SPAWNER] Portal promotion for client %s", tostring(client_id)))
        elseif transfer and transfer.data and transfer.data.Transform and transfer.data.Transform.translation then
            -- Use transferred position
            spawn_pos = transfer.data.Transform.translation
            print(string.format("[PLAYER/SPAWNER] Using transfer position for client %s", tostring(client_id)))
        end

        -- Find free spawn point (fallback if no transfer)
        local spawn_index = nil

        if not spawn_pos then
            spawn_pos = { x = 0, y = SPAWN_HEIGHT, z = 0 }
            for i, sp in ipairs(spawner_state.spawn_points) do
                if not sp.occupied then
                    spawn_index = i
                    sp.occupied = true
                    sp.client_id = client_id

                    -- Read spawn point transform
                    local sp_entity = world:get_entity(sp.entity_id)
                    if sp_entity then
                        local t = sp_entity:get("Transform")
                        if t and t.translation then
                            spawn_pos = t.translation
                        end
                        sp_entity:patch({ spawn_point = { occupied = true } })
                    end
                    break
                end
            end

            if not spawn_index then
                print(string.format("[PLAYER/SPAWNER] WARNING: No free spawn point for client %s", tostring(client_id)))
                spawn_index = 0
            end
        else
            -- Still claim a spawn point for bookkeeping
            for i, sp in ipairs(spawner_state.spawn_points) do
                if not sp.occupied then
                    spawn_index = i
                    sp.occupied = true
                    sp.client_id = client_id
                    local sp_entity = world:get_entity(sp.entity_id)
                    if sp_entity then
                        sp_entity:patch({ spawn_point = { occupied = true } })
                    end
                    break
                end
            end
            spawn_index = spawn_index or 0
        end

        -- Build spawn components — start with defaults, then merge synced_state
        -- data so camera orbit params etc. are part of the entity from the start
        -- (prevents ModLoader base resolution from overwriting with empty defaults).
        local spawn_components = {
            Transform = { translation = spawn_pos },
            RigidBody3d = "Dynamic",
            Collider3d = { capsule_y = { radius = 0.4, half_height = 0.5 } },
            LockedAxes3d = "ROTATION_LOCKED",
            Velocity3d = { linvel = { x = 0, y = 0, z = 0 }, angvel = { x = 0, y = 0, z = 0 } },
            net_owner = { client_id = client_id },
            net_sync = {
                Transform = { authority = "server", reliable = false, predict = true },
                RigidBody3d = { authority = "server" },
                Collider3d = { authority = "server" },
                LockedAxes3d = { authority = "server" },
            },
            net_peer_share = { stable_id = "player_" .. tostring(client_id) },
            net_transfer = { id = "player" },
            player = { client_id = client_id, spawn_index = spawn_index },
            net_mod = {
                { player = {} },
                { input = {} },
                { camera = {}, net_sync = { authority = "client", target = "owner" } },
                { vr = {} },
                { movement = {} },
                { animation = {
                    model = "Placeholder-Character/Model",
                    scene = "-Idle.glb#Scene0",
                    clips = {
                        idle = "-Idle.glb#Animation0",
                        walk = "-Walk.glb#Animation0",
                        jump = "-Jump.glb#Animation0",
                        fall = "-Jump.glb#Animation0",
                    },
                }},
                { abilities = {} },
                { sidebar = {}, net_sync = { authority = "client", target = "owner" } },
            },
        }

        -- Merge synced_state game state into spawn components.
        -- Only add components the spawner doesn't already define — this naturally
        -- preserves infrastructure (net_mod, net_sync, Transform, etc.) while
        -- picking up game state (camera, movement, etc.) from the mirror.
        if synced_state then
            for comp_name, comp_data in pairs(synced_state) do
                if not spawn_components[comp_name] then
                    spawn_components[comp_name] = comp_data
                end
            end
            -- Shallow-merge net_sync entries so the SPAWN message includes
            -- sync config for synced_state components (e.g. camera)
            if synced_state.net_sync then
                for k, v in pairs(synced_state.net_sync) do
                    if not spawn_components.net_sync[k] then
                        spawn_components.net_sync[k] = v
                    end
                end
            end
        end

        local player = spawn(spawn_components)

        spawner_state.player_entities[client_id] = player:id()

        print(string.format("[PLAYER/SPAWNER] Spawned player for client %s at spawn point %d (pos=%.1f,%.1f,%.1f)",
            tostring(client_id), spawn_index, spawn_pos.x, spawn_pos.y, spawn_pos.z))

        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Handle client disconnections: react to removed { "net_client" }
-- Free spawn point, despawn player entity.
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    for _, entity in ipairs(world:query({ removed = { "net_client" } })) do
        -- net_client data is gone (entity despawned), find by tracked state
        -- We need to check which client_ids are no longer present
    end

    -- Also check our tracked players against current net_clients
    -- If a tracked player's net_client entity is gone, clean up
    for client_id, player_eid in pairs(spawner_state.player_entities) do
        -- Check if net_client for this client still exists
        local still_connected = false
        for _, nc_entity in ipairs(world:query({ with = { "net_client" } })) do
            local nc = nc_entity:get("net_client")
            if nc and nc.client_id == client_id then
                still_connected = true
                break
            end
        end

        if not still_connected then
            -- Free spawn point
            for i, sp in ipairs(spawner_state.spawn_points) do
                if sp.client_id == client_id then
                    sp.occupied = false
                    sp.client_id = nil

                    local sp_entity = world:get_entity(sp.entity_id)
                    if sp_entity then
                        sp_entity:patch({ spawn_point = { occupied = false } })
                    end
                    break
                end
            end

            -- Despawn player entity
            local player = world:get_entity(player_eid)
            if player then
                despawn(player)
            end
            spawner_state.player_entities[client_id] = nil

            print(string.format("[PLAYER/SPAWNER] Cleaned up player for disconnected client %s", tostring(client_id)))
        end
    end
end, { after = { "NetServerInbound" } })
