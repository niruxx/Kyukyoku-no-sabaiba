-- modules/sword/client/init.lua
-- Left-click sword slash aimed at the mouse cursor.
-- Reads cursor position from the primary Window to compute a world-space
-- direction (window center ≈ player position for a centred camera).
-- Fires once per click; 0.35 s cooldown prevents spam.

local SLASH_COOLDOWN = 0.35   -- seconds between slashes
local SLASH_DURATION = 0.18   -- visual lifetime
local SLASH_REACH    = 36.0   -- distance from player centre to slash centre
local SLASH_W        = 52.0   -- long axis of slash sprite
local SLASH_H        = 10.0   -- short axis of slash sprite

-- Plain Lua tables — avoids define_resource copy-on-read issues for mutable timers.
local elapsed    = 0.0
local last_slash = -999.0
local slashes    = {}   -- [entity_id] → elapsed_seconds (number)

local img = load_asset("character-spritesheet.png")

---------------------------------------------------------------------------
-- Elapsed counter
---------------------------------------------------------------------------
register_system("PreUpdate", function(world)
    elapsed = elapsed + world:delta_time()
end)

---------------------------------------------------------------------------
-- Init: register left-mouse binding on the player's input component
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "sword" } })
    for _, entity in ipairs(entities) do
        entity:patch({ input = { sword = {
            attack = { mouse = "Left", mode = "game" },
        }}})
        print(string.format("[SWORD/CLIENT] Initialized for entity %d", entity:id()))
    end
end)

---------------------------------------------------------------------------
-- Slash on left-click
-- `changed = { "input_sword" }` fires only on press (true) and release (false).
-- The `not sw.attack` guard skips the release event.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        with    = { "sword", "Transform" },
        changed = { "input_sword" },
    })
    for _, entity in ipairs(entities) do
        local sw = entity:get("input_sword")
        if not sw or not sw.attack then goto continue end

        if elapsed - last_slash < SLASH_COOLDOWN then goto continue end
        last_slash = elapsed

        local t = entity:get("Transform")
        if not t or not t.translation then goto continue end
        local pos = t.translation

        -- Resolve aim direction: window centre → cursor.
        -- Camera is centred on player so window centre ≈ player world pos.
        local dir_x, dir_y = 0.0, -1.0   -- fallback: downward
        for _, win in ipairs(world:query({ with = { "Window" } })) do
            local w = win:get("Window")
            if w and w.cursor and w.cursor.position then
                local cp  = w.cursor.position
                local res = w.resolution
                local ww  = (res and (res.width  or res.physical_width))  or 1920
                local wh  = (res and (res.height or res.physical_height)) or 1080
                local cx  = cp.x - ww * 0.5
                local cy  = -(cp.y - wh * 0.5)  -- flip Y: screen-down → world-up
                local len = math.sqrt(cx * cx + cy * cy)
                if len > 1.0 then
                    dir_x = cx / len
                    dir_y = cy / len
                end
            end
        end

        -- Spawn slash visual offset from player in aim direction
        local angle = math.atan2(dir_y, dir_x)
        local rot   = world:call_static_method("Quat", "from_rotation_z", angle)
        local vis = spawn({
            Transform = {
                translation = { x = pos.x + dir_x * SLASH_REACH,
                                y = pos.y + dir_y * SLASH_REACH,
                                z = pos.z + 0.5 },
                rotation = rot,
            },
            Sprite = {
                image       = img,
                rect        = { min = { x = 0, y = 0 }, max = { x = 64, y = 64 } },
                custom_size = { x = SLASH_W, y = SLASH_H },
                color       = { r = 0.95, g = 0.95, b = 1.0, a = 1.0 },
            },
        })
        slashes[vis:id()] = 0.0   -- store timer as a plain number

        ::continue::
    end
end, { label = "SwordSlash", after = { "Input" } })

---------------------------------------------------------------------------
-- Animate slash: expand + fade, then despawn
-- Uses a to_remove list so we never modify `slashes` during iteration.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt        = world:delta_time()
    local to_remove = {}

    for eid, timer in pairs(slashes) do
        local new_t  = timer + dt
        local entity = world:get_entity(eid)

        if not entity or new_t >= SLASH_DURATION then
            if entity then despawn(entity) end
            to_remove[#to_remove + 1] = eid
        else
            slashes[eid] = new_t   -- write back the incremented number
            local p = new_t / SLASH_DURATION
            entity:patch({ Sprite = {
                custom_size = { x = SLASH_W * (1.0 + p * 0.7),
                                y = SLASH_H * (1.0 + p * 0.3) },
                color = { r = 0.95, g = 0.95, b = 1.0, a = 1.0 - p },
            }})
        end
    end

    for _, eid in ipairs(to_remove) do
        slashes[eid] = nil
    end
end, { after = { "SwordSlash" } })
