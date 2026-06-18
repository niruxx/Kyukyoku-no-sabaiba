-- modules/zombie/client/init.lua
-- Zombie visuals: green-tinted sprite + floating HP% label above each zombie.
-- Labels are absolute-positioned UI nodes updated every frame from world-space
-- position, converting through the local camera entity's Transform.

-- Module-local table mapping zombie entity_id → label info
local zombie_hp_labels = {}   -- [eid] → { container_id, text_id, max_hp }

---------------------------------------------------------------------------
-- First: spawn sprite + HP label node for each newly-added zombie
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "zombie" } })) do
        local image = load_asset("character-spritesheet.png")
        local zdata = entity:get("zombie")

        -- Capture max_hp from the initial (full) hp value
        local max_hp = (zdata and zdata.hp) or 3

        -- Green-tinted sprite child
        spawn({
            Transform = { translation = { x = 0, y = 0, z = 0.5 } },
            Sprite    = {
                image       = image,
                rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                custom_size = { x = 32, y = 32 },
                color       = { r = 0.25, g = 0.9, b = 0.2, a = 1.0 },
            },
        }):with_parent(entity:id())

        -- Absolute UI label (parked off-screen; Update positions it each frame)
        local container = spawn({
            Node = {
                position_type = "Absolute",
                left          = { Px = -9999 },
                top           = { Px = -9999 },
            },
            GlobalZIndex = { value = 40 },
        })
        local text_e = spawn({
            Text      = { text = "" },
            TextFont  = { font_size = 11 },
            TextColor = { color = { r = 1.0, g = 0.9, b = 0.1, a = 0.0 } },
        }):with_parent(container:id())

        zombie_hp_labels[entity:id()] = {
            container_id = container:id(),
            text_id      = text_e:id(),
            max_hp       = max_hp,
        }

        print(string.format("[ZOMBIE/CLIENT] Visual spawned for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Update: reposition and refresh each HP label every frame
---------------------------------------------------------------------------
register_system("Update", function(world)
    -- Find local player's camera position (camera/2d module is on the player entity)
    local cam_x, cam_y = 0, 0
    for _, cam_e in ipairs(world:query({ with = { "camera/2d", "Transform" } })) do
        local ct = cam_e:get("Transform")
        if ct and ct.translation then
            cam_x = ct.translation.x
            cam_y = ct.translation.y
        end
        break
    end

    -- Get window resolution for screen-centre computation
    local win_w, win_h = 1920, 1080
    for _, win in ipairs(world:query({ with = { "Window" } })) do
        local wd = win:get("Window")
        if wd and wd.resolution then
            win_w = wd.resolution.width  or win_w
            win_h = wd.resolution.height or win_h
        end
        break
    end

    for eid, label in pairs(zombie_hp_labels) do
        local zombie = world:get_entity(eid)
        if not zombie then
            -- Zombie despawned — remove the label node
            local c = world:get_entity(label.container_id)
            if c then despawn(c) end
            zombie_hp_labels[eid] = nil
            goto cont
        end

        local zdata = zombie:get("zombie")
        local zt    = zombie:get("Transform")
        if not zdata or not zt or not zt.translation then goto cont end

        local hp     = math.max(0, zdata.hp or 0)
        local max_hp = label.max_hp
        local pct    = math.floor((hp / max_hp) * 100)

        -- Only show when the zombie has taken damage (and is still alive)
        local show = hp > 0 and hp < max_hp

        -- World → screen (2D orthographic: 1 world-unit = 1 pixel; Y axis flipped)
        local wx   = zt.translation.x
        local wy   = zt.translation.y
        local sx   = (wx - cam_x) + win_w * 0.5 - 14   -- ~14px left to centre text
        local sy   = -(wy - cam_y) + win_h * 0.5 - 38  -- 38px above sprite centre

        local c = world:get_entity(label.container_id)
        if c then
            c:patch({ Node = {
                position_type = "Absolute",
                left = { Px = show and sx or -9999 },
                top  = { Px = show and sy or -9999 },
            }})
        end

        local text_e = world:get_entity(label.text_id)
        if text_e then
            -- Colour shifts green → yellow → red as HP drops
            local r, g
            if pct > 50 then     r, g = 0.2,  0.9
            elseif pct > 25 then r, g = 1.0,  0.75
            else                 r, g = 1.0,  0.2
            end

            text_e:patch({
                Text      = { text  = pct .. "%" },
                TextColor = { color = { r = r, g = g, b = 0.05, a = show and 1.0 or 0.0 } },
            })
        end

        ::cont::
    end
end)
