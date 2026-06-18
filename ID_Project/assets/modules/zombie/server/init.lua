-- modules/zombie/server/init.lua
-- Zombie AI: chases the nearest living player and deals damage on contact.
-- Loaded via net_mod on each zombie entity — the script is shared (ref-counted),
-- so register_system runs once; world:query processes ALL zombie entities.

local ATTACK_RANGE   = 28    -- pixels, distance at which zombie deals damage
local ATTACK_DPS     = 8     -- HP lost per second while zombie is in attack range
local MIN_MOVE_DIST  = 2.0   -- stop chasing when within this range (prevents vibration)

---------------------------------------------------------------------------
-- Zombie AI: move toward the nearest living player, attack on contact
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt      = world:delta_time()
    local players = world:query({ with = { "player", "Transform", "player_health" } })
    local zombies = world:query({ with = { "zombie", "Transform", "Velocity2d" } })

    for _, zombie in ipairs(zombies) do
        local zdata = zombie:get("zombie")
        if not zdata then goto cont_zombie end

        local zt = zombie:get("Transform")
        if not zt or not zt.translation then goto cont_zombie end

        local speed = zdata.speed or 55
        local zx    = zt.translation.x
        local zy    = zt.translation.y

        -- Find nearest living player
        local nearest_dist = math.huge
        local chase_x, chase_y = 0, 0
        local found = false

        for _, player in ipairs(players) do
            local ph = player:get("player_health")
            -- Skip dead players
            if ph and (ph.hp or 0) <= 0 then goto cont_player end

            local pt = player:get("Transform")
            if not pt or not pt.translation then goto cont_player end

            local dx   = pt.translation.x - zx
            local dy   = pt.translation.y - zy
            local dist = math.sqrt(dx * dx + dy * dy)

            if dist < nearest_dist then
                nearest_dist = dist
                chase_x      = pt.translation.x
                chase_y      = pt.translation.y
                found        = true
            end

            ::cont_player::
        end

        if found then
            local dx   = chase_x - zx
            local dy   = chase_y - zy
            local dist = math.sqrt(dx * dx + dy * dy)

            local vx, vy = 0, 0
            if dist > MIN_MOVE_DIST then
                vx = (dx / dist) * speed
                vy = (dy / dist) * speed
            end
            zombie:patch({ Velocity2d = { linvel = { x = vx, y = vy }, angvel = 0 } })

            -- Melee attack: deal damage to every player within attack range
            if nearest_dist < ATTACK_RANGE then
                for _, player in ipairs(players) do
                    local ph = player:get("player_health")
                    if not ph or (ph.hp or 0) <= 0 then goto cont_attack end

                    local pt = player:get("Transform")
                    if not pt or not pt.translation then goto cont_attack end

                    local pdx  = pt.translation.x - zx
                    local pdy  = pt.translation.y - zy
                    local pdist = math.sqrt(pdx * pdx + pdy * pdy)

                    if pdist < ATTACK_RANGE then
                        local new_hp = math.max(0, ph.hp - ATTACK_DPS * dt)
                        player:patch({ player_health = { hp = new_hp } })
                        if new_hp <= 0 then
                            print(string.format("[ZOMBIE/SERVER] Player killed! (client %s)",
                                tostring(player:get("player") and player:get("player").client_id)))
                        end
                    end

                    ::cont_attack::
                end
            end
        else
            -- No living players — stand still
            zombie:patch({ Velocity2d = { linvel = { x = 0, y = 0 }, angvel = 0 } })
        end

        ::cont_zombie::
    end
end, { label = "ZombieAI" })
