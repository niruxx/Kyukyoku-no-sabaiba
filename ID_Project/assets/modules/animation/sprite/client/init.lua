-- modules/animation/sprite/client/init.lua

local AnimationSprite = require("modules/animation/sprite/shared/init.lua")

local json = require("modules/dkjson.lua")

local cache = define_resource("AnimationCache", {
    sprite_layouts = {},
})

local function frame_rect(frame, columns, tile_size)
    local tile_w = tile_size.x or tile_size[1] or 16
    local tile_h = tile_size.y or tile_size[2] or 16
    local col = frame % columns
    local row = math.floor(frame / columns)
    local x = col * tile_w
    local y = row * tile_h
    return {
        min = { x = x, y = y },
        max = { x = x + tile_w, y = y + tile_h },
    }
end

---------------------------------------------------------------------------
-- Init: load model + clips
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "animation/sprite" } })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation/sprite")
            
        local image_path = anim.image
        if not image_path then
            print(string.format("[ANIMATION/SPRITE/CLIENT] WARNING: entity %d sprite has no image", entity:id()))
            goto continue
        end

        local tile_size = anim.tile_size or { x = 16, y = 16 }
        local columns = anim.columns or 1
        local rows = anim.rows or 1

        local image = load_asset(image_path)
        local clips = anim.clips or {}
        local idle = clips.idle or { frames = { 0 }, fps = 1 }
        local first_frame = (idle.frames and idle.frames[1]) or 0
        local scale = anim.scale or 1.0

        local anim_entity = spawn({
            Transform = {
                translation = { x = 0, y = 0, z = anim.z or 1.0 },
                scale = { x = scale, y = scale, z = 1.0 },
            },
            Sprite = {
                image = image,
                rect = frame_rect(first_frame, columns, tile_size),
                custom_size = { x = tile_size.x or 16, y = tile_size.y or 16 },
            },
        }):with_parent(entity:id())

        entity:patch({ ["animation/sprite"] = {
            state = anim.state or "idle",
            speed = anim.speed or 1.0,
            anim_entity_id = anim_entity:id(),
            _last_state = null,
            _frame_index = 1,
            _frame_timer = 0,
        }})

        print(string.format("[ANIMATION/SPRITE/CLIENT] Sprite spawned for entity %d (image=%s)",
            entity:id(), image_path))

        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Sprite playback: advance atlas frame for animation.sprite clips.
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()

    local entities = world:query({
        with = { "animation/sprite" },
    })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation/sprite")
        if not anim.anim_entity_id then goto continue end

        local clips = anim.clips or {}
        local state = anim.state or "idle"
        local clip = clips[state] or clips.idle
        if not clip or not clip.frames or #clip.frames == 0 then goto continue end

        local frame_index = anim._frame_index or 1
        local frame_timer = anim._frame_timer or 0

        if anim._last_state ~= state then
            frame_index = 1
            frame_timer = 0
        end

        local fps = (clip.fps or 1) * (anim.speed or 1.0)
        if fps > 0 and #clip.frames > 1 then
            frame_timer = frame_timer + dt
            local frame_time = 1.0 / fps
            while frame_timer >= frame_time do
                frame_timer = frame_timer - frame_time
                frame_index = frame_index + 1
                if frame_index > #clip.frames then frame_index = 1 end
            end
        end

        local anim_entity = world:get_entity(anim.anim_entity_id)
        if anim_entity then
            local tile_size = anim.tile_size or { x = 16, y = 16 }
            local columns = anim.columns or 1
            anim_entity:patch({
                Sprite = {
                    rect = frame_rect(clip.frames[frame_index] or clip.frames[1], columns, tile_size),
                    custom_size = { x = tile_size.x or 16, y = tile_size.y or 16 },
                },
            })
        end

        if anim._last_state ~= state or anim._frame_index ~= frame_index or anim._frame_timer ~= frame_timer then
            entity:patch({ ["animation/sprite"] = {
                _last_state = state,
                _frame_index = frame_index,
                _frame_timer = frame_timer,
            }})
        end

        ::continue::
    end
end, { label = "SpriteAnimation", after = { "Animation" } })
