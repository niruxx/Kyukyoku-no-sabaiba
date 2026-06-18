-- modules/player/2d/zombie_spawner/init.lua
-- Zombie-game player spawner: same pattern as player/2d/spawner but
-- loads the `weapons` mod instead of `abilities`, and gives every player
-- a `player_health` component that the zombie AI drains on contact.

local NUM_SPAWNS    = 8
local SPAWN_RADIUS  = 96.0
local SPAWN_Z       = 0.0

local state = define_resource("ZombiePlayerSpawnerState", {
    spawn_points   = {},
    player_entities = {},
    spawner_entity_id = nil,
    net_entity_id = nil,
})

---------------------------------------------------------------------------
-- Init: create spawn-point ring
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ with = { "player/2d/zombie_spawner" } })
    for _, entity in ipairs(entities) do
        state.spawner_entity_id = entity:id()

        local parent_id = entity:get("ChildOf")
        if parent_id then state.net_entity_id = parent_id end

        for i = 1, NUM_SPAWNS do
            local angle = (i / NUM_SPAWNS) * 2 * math.pi
            local x = math.cos(angle) * SPAWN_RADIUS
            local y = math.sin(angle) * SPAWN_RADIUS

            local sp = spawn({
                spawn_point = { occupied = false, index = i },
                Transform   = { translation = { x = x, y = y, z = SPAWN_Z } },
            }):with_parent(entity:id())

            state.spawn_points[i] = {
                entity_id = sp:id(),
                occupied  = false,
                client_id = nil,
            }
        end

        print(string.format("[PLAYER/ZOMBIE_SPAWNER] Created %d spawn points (radius=%.0f)",
            NUM_SPAWNS, SPAWN_RADIUS))

        return true
    end
end)

---------------------------------------------------------------------------
-- Handle client connections: spawn a player entity with weapons + health
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    for _, entity in ipairs(world:query({
        ["or"] = { added = { "net_client" }, changed = { "net_client" } },
    })) do
        local nc = entity:get("net_client")
        if not nc then goto continue end

        local client_id = nc.client_id
        if state.player_entities[client_id] then goto continue end
        if nc.observer and not nc.synced_state then goto continue end

        local net_entity_id = define_resource("NetInfo", {}).net_entity_id or state.net_entity_id
        state.net_entity_id = net_entity_id

        if not net_entity_id then
            print(string.format("[PLAYER/ZOMBIE_SPAWNER] ERROR: No net entity for client %s", tostring(client_id)))
            goto continue
        end

        -- Resolve spawn position
        local spawn_pos   = { x = 0, y = 0, z = SPAWN_Z }
        local spawn_index = 0

        for i, sp in ipairs(state.spawn_points) do
            if not sp.occupied then
                spawn_index  = i
                sp.occupied  = true
                sp.client_id = client_id

                local sp_entity = world:get_entity(sp.entity_id)
                if sp_entity then
                    local t = sp_entity:get("Transform")
                    if t and t.translation then spawn_pos = t.translation end
                    sp_entity:patch({ spawn_point = { occupied = true } })
                end
                break
            end
        end

        if spawn_index == 0 then
            print(string.format("[PLAYER/ZOMBIE_SPAWNER] WARNING: No free spawn for client %s", tostring(client_id)))
        end

        local player = spawn({
            Transform      = { translation = spawn_pos },
            RigidBody2d    = "KinematicVelocityBased",
            Collider2d     = { capsule_y = { radius = 8.0, half_height = 10.0 } },
            LockedAxes2d   = "ROTATION_LOCKED",
            Velocity2d     = { linvel = { x = 0, y = 0 }, angvel = 0 },
            GravityScale2d = 0.0,
            net_owner      = { client_id = client_id },
            net_sync       = {
                Transform       = { authority = "server", reliable = false },
                RigidBody2d     = { authority = "server" },
                Collider2d      = { authority = "server" },
                LockedAxes2d    = { authority = "server" },
                GravityScale2d  = { authority = "server" },
                player_health   = { authority = "server" },
                respawn_request = { authority = "client" },
            },
            net_transfer    = { id = "player" },
            player          = { client_id = client_id, spawn_index = spawn_index },
            player_health   = { hp = 100, max_hp = 100 },
            respawn_request = { active = false },
            net_mod       = {
                { player = {} },
                { input  = { input_mode = "ui" } },
                { ["camera/2d"]   = {}, net_sync = { authority = "client", target = "owner" } },
                { ["movement/2d"] = { speed = 160.0 } },
                { ["animation/sprite"] = {
                    image     = "character-spritesheet.png",
                    tile_size = { x = 64, y = 64 },
                    columns   = 13,
                    rows      = 54,
                    scale     = 1.0,
                    clips = {
                        idle       = { frames = { 130 }, fps = 1 },
                        idle_down  = { frames = { 130 }, fps = 1 },
                        idle_right = { frames = { 143 }, fps = 1 },
                        idle_left  = { frames = { 117 }, fps = 1 },
                        idle_up    = { frames = { 104 }, fps = 1 },
                        walk_down  = { frames = { 130, 131, 132, 133, 134, 135, 136, 137, 138 }, fps = 50 },
                        walk_right = { frames = { 143, 144, 145, 146, 147, 148, 149, 150, 151 }, fps = 50 },
                        walk_left  = { frames = { 117, 118, 119, 120, 121, 122, 123, 124, 125 }, fps = 50 },
                        walk_up    = { frames = { 104, 105, 106, 107, 108, 109, 110, 111, 112 }, fps = 50 },
                    },
                }},
                -- weapons replaces abilities: Q=railgun, E=explosives, R=nova
                { weapons = {} },
                -- hud: health bar + cooldown overlay (owner only, client-only)
                { hud = {}, net_sync = { authority = "client", target = "owner" } },
                { sidebar = {}, net_sync = { authority = "client", target = "owner" } },
            },
        })

        state.player_entities[client_id] = player:id()

        print(string.format("[PLAYER/ZOMBIE_SPAWNER] Spawned player for client %s at point %d (%.0f,%.0f)",
            tostring(client_id), spawn_index, spawn_pos.x, spawn_pos.y))

        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Handle client disconnections: free spawn point and despawn player
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    for client_id, player_eid in pairs(state.player_entities) do
        local still_connected = false

        for _, nc_entity in ipairs(world:query({ with = { "net_client" } })) do
            local nc = nc_entity:get("net_client")
            if nc and nc.client_id == client_id then
                still_connected = true
                break
            end
        end

        if not still_connected then
            for _, sp in ipairs(state.spawn_points) do
                if sp.client_id == client_id then
                    sp.occupied  = false
                    sp.client_id = nil
                    local sp_entity = world:get_entity(sp.entity_id)
                    if sp_entity then
                        sp_entity:patch({ spawn_point = { occupied = false } })
                    end
                    break
                end
            end

            local player = world:get_entity(player_eid)
            if player then despawn(player) end
            state.player_entities[client_id] = nil

            print(string.format("[PLAYER/ZOMBIE_SPAWNER] Cleaned up player for client %s", tostring(client_id)))
        end
    end
end, { after = { "NetServerInbound" } })

---------------------------------------------------------------------------
-- Respawn: client patches respawn_request.active=true → server resets hp
-- and teleports the player back to their assigned spawn point.
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, player in ipairs(world:query({
        with    = { "player", "player_health", "respawn_request" },
        changed = { "respawn_request" },
    })) do
        local rr = player:get("respawn_request")
        if not rr or not rr.active then goto cont end

        local pdata     = player:get("player")
        local client_id = pdata and pdata.client_id

        -- Find this player's assigned spawn point
        local spawn_pos = { x = 0, y = 0, z = 0 }
        for _, sp in ipairs(state.spawn_points) do
            if sp.client_id == client_id then
                local sp_entity = world:get_entity(sp.entity_id)
                if sp_entity then
                    local t = sp_entity:get("Transform")
                    if t and t.translation then spawn_pos = t.translation end
                end
                break
            end
        end

        player:patch({
            player_health   = { hp = 100, max_hp = 100 },
            respawn_request = { active = false },
            Transform       = { translation = spawn_pos },
        })

        print(string.format("[PLAYER/ZOMBIE_SPAWNER] Respawned player (client %s) at (%.0f,%.0f)",
            tostring(client_id), spawn_pos.x, spawn_pos.y))

        ::cont::
    end
end)
