-- modules/title_screen/client/init.lua
-- Pixel-art start menu with animated title, star field, looping chiptune,
-- and options panel for resolution + volume.
--
-- Loaded via:  require("modules/title_screen/client/init.lua")
-- from Hello/scripts/main.lua (runs in root client scope).
--
-- input_mode is implicitly "ui" here (no input component yet).
-- When START GAME is clicked, the game entity is spawned and the title
-- screen despawns itself — main.lua's PreUpdate system detects the new
-- game component and launches the networked game in a child scope.
-- The spawned player entity (via net_mod { input, ... }) begins with
-- input_mode = "ui" by design until the player presses a movement key.

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local state = define_resource("TitleScreenState", {
    root_id          = nil,
    title_id         = nil,
    press_start_id   = nil,
    music_id         = nil,
    options_panel_id = nil,
    res_display_id   = nil,
    vol_display_id   = nil,
    options_visible  = false,
    anim_time        = 0.0,
    blink_timer      = 0.0,
    blink_on         = true,
    volume           = 0.7,
    resolution_index = 2,          -- 1=720p, 2=1080p, 3=1440p
    star_ids         = {},
    initialized      = false,
    frame_count      = 0,
})

local RESOLUTIONS = {
    { 1280, 720,  "1280 x 720  (HD)"  },
    { 1920, 1080, "1920 x 1080 (FHD)" },
    { 2560, 1440, "2560 x 1440 (QHD)" },
}

------------------------------------------------------------------------
-- Pixel-art colour palette
------------------------------------------------------------------------

local C = {
    void        = { r = 0.02, g = 0.02, b = 0.08, a = 1.0  },
    panel       = { r = 0.05, g = 0.05, b = 0.16, a = 0.95 },
    card        = { r = 0.06, g = 0.06, b = 0.18, a = 1.0  },
    btn         = { r = 0.08, g = 0.08, b = 0.22, a = 1.0  },
    btn_hover   = { r = 0.16, g = 0.16, b = 0.44, a = 1.0  },
    border      = { r = 0.26, g = 0.26, b = 0.72, a = 1.0  },
    border_hot  = { r = 0.50, g = 0.50, b = 1.00, a = 1.0  },
    accent      = { r = 0.35, g = 0.55, b = 1.00, a = 1.0  },
    gold        = { r = 1.00, g = 0.85, b = 0.20, a = 1.0  },
    white       = { r = 0.95, g = 0.95, b = 1.00, a = 1.0  },
    dim         = { r = 0.55, g = 0.55, b = 0.72, a = 1.0  },
    dim_hidden  = { r = 0.55, g = 0.55, b = 0.72, a = 0.0  },
    overlay     = { r = 0.00, g = 0.00, b = 0.00, a = 0.78 },
}

------------------------------------------------------------------------
-- HSL → RGB for rainbow title shimmer
------------------------------------------------------------------------

local function hue_color(h)
    local s, l = 0.85, 0.68
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    local function f(t)
        t = t % 1.0
        if t < 1/6 then return p + (q - p) * 6 * t
        elseif t < 1/2 then return q
        elseif t < 2/3 then return p + (q - p) * (2/3 - t) * 6
        else return p end
    end
    return { r = f(h + 1/3), g = f(h), b = f(h - 1/3), a = 1.0 }
end

------------------------------------------------------------------------
-- Shared button factories
------------------------------------------------------------------------

-- Wide menu button (300 × 54) with pixel-art border + hover
local function make_button(parent_id, label, on_click)
    local btn = spawn({
        Button         = {},
        Node           = {
            width          = { Px = 300 },
            height         = { Px = 54 },
            justify_content = "Center",
            align_items    = "Center",
            margin         = { bottom = { Px = 10 } },
            border         = { left = { Px = 3 }, right = { Px = 3 },
                               top  = { Px = 3 }, bottom = { Px = 3 } },
        },
        -- BackgroundColor = { C.btn },
        -- BorderColor     = { C.border },
        BorderRadius    = { top_left    = { Px = 2 }, top_right    = { Px = 2 },
                            bottom_left = { Px = 2 }, bottom_right = { Px = 2 } },
    }):with_parent(parent_id)

    spawn({
        Text      = { text = label },
        TextFont  = { font_size = 21 },
        TextColor = { color = C.white },
    }):with_parent(btn:id())

    btn:observe("Pointer<Over>",  function(_, b)
        -- b:patch({ BackgroundColor = { C.btn_hover }, BorderColor = { color = C.border_hot } })
    end)
    btn:observe("Pointer<Out>",   function(_, b)
        -- b:patch({ BackgroundColor = { color = C.btn      }, BorderColor = { color = C.border     } })
    end)
    btn:observe("Pointer<Click>", function(world, _) on_click(world) end)

    return btn:id()
end

-- Small square button (40 × 36) used in options rows
local function make_small_btn(parent_id, label, on_click)
    local btn = spawn({
        Button         = {},
        Node           = {
            width  = { Px = 40 }, height = { Px = 36 },
            justify_content = "Center", align_items = "Center",
            border = { left = { Px = 2 }, right = { Px = 2 },
                       top  = { Px = 2 }, bottom = { Px = 2 } },
        },
        -- BackgroundColor = { color = C.btn },
        BorderColor     = { color = C.border },
        BorderRadius    = { top_left    = { Px = 2 }, top_right    = { Px = 2 },
                            bottom_left = { Px = 2 }, bottom_right = { Px = 2 } },
    }):with_parent(parent_id)

    spawn({
        Text      = { text = label },
        TextFont  = { font_size = 16 },
        TextColor = { color = C.white },
    }):with_parent(btn:id())

    btn:observe("Pointer<Over>",  function(_, b)
        -- b:patch({ BackgroundColor = { color = C.btn_hover }, BorderColor = { color = C.border_hot } })
    end)
    btn:observe("Pointer<Out>",   function(_, b)
        -- b:patch({ BackgroundColor = { color = C.btn      }, BorderColor = { color = C.border     } })
    end)
    btn:observe("Pointer<Click>", function(world, _) on_click(world) end)

    return btn:id()
end

-- Section label (small all-caps dim text)
local function section_label(parent_id, text)
    spawn({
        Text      = { text = text },
        TextFont  = { font_size = 12 },
        TextColor = { color = C.dim },
        Node      = { margin = { bottom = { Px = 6 } } },
    }):with_parent(parent_id)
end

-- Pixel-art horizontal rule (thin accent bar)
local function pixel_rule(parent_id, width_px, margin_top, margin_bottom)
    spawn({
        Node = {
            width  = { Px = width_px },
            height = { Px = 4 },
            margin = { top = { Px = margin_top or 0 }, bottom = { Px = margin_bottom or 0 } },
        },
        -- BackgroundColor = { color = C.accent },
    }):with_parent(parent_id)
end

------------------------------------------------------------------------
-- Apply volume to GlobalVolume resource + music entity
------------------------------------------------------------------------

local function apply_volume(world)
    -- GlobalVolume resource (affects all audio in the scope)
    pcall(function()
        world:insert_resource("GlobalVolume", { volume = { Linear = state.volume } })
    end)
    -- Patch the music entity's PlaybackSettings directly
    if state.music_id then
        local m = world:get_entity(state.music_id)
        if m then
            m:patch({ PlaybackSettings = { volume = { Linear = state.volume } } })
        end
    end
end

------------------------------------------------------------------------
-- Apply window resolution
------------------------------------------------------------------------

local function apply_resolution(world, w, h)
    local wins = world:query({ with = { "Window" } })
    for _, win in ipairs(wins) do
        pcall(function()
            win:patch({ Window = { resolution = { width = w, height = h } } })
        end)
    end
end

------------------------------------------------------------------------
-- Build the entire title-screen UI (runs once on First frame)
------------------------------------------------------------------------

register_system("First", function(world)
    if state.initialized then return end
    state.initialized = true

    -- ── Full-screen root overlay ────────────────────────────────────
    local root = spawn({
        Node = {
            position_type   = "Absolute",
            left = { Px = 0 }, top    = { Px = 0 },
            right = { Px = 0 }, bottom = { Px = 0 },
            flex_direction  = "Column",
            justify_content = "Center",
            align_items     = "Center",
        },
        -- BackgroundColor = { color = C.void },
        GlobalZIndex    = { value = 200 },
    })
    state.root_id = root:id()

    -- ── Star-field (80 random pixel points) ────────────────────────
    math.randomseed(0xDEAD)
    for i = 1, 80 do
        local px  = math.random(0, 99)
        local py  = math.random(0, 99)
        local sz  = math.random(1, 3)
        local star = spawn({
            Node = {
                position_type = "Absolute",
                left   = { Percent = px },
                top    = { Percent = py },
                width  = { Px = sz },
                height = { Px = sz },
            },
            -- BackgroundColor = { color = { r = 0.85, g = 0.90, b = 1.0, a = 0.5 } },
        }):with_parent(state.root_id)

        state.star_ids[i] = {
            id    = star:id(),
            phase = math.random() * math.pi * 2,
            speed = 0.5 + math.random() * 1.8,
        }
    end

    -- ── Pixel scanline overlay (every-other-4px semi-transparent bars) ──
    -- 12 evenly-spaced decorative horizontal bars
    for i = 0, 11 do
        spawn({
            Node = {
                position_type = "Absolute",
                left   = { Px = 0 },
                right  = { Px = 0 },
                top    = { Percent = i * 8.5 },
                height = { Px = 2 },
            },
            -- BackgroundColor = { color = { r = 0, g = 0, b = 0, a = 0.08 } },
        }):with_parent(state.root_id)
    end

    -- ── Title column (centred vertically) ──────────────────────────
    local col = spawn({
        Node = {
            flex_direction  = "Column",
            align_items     = "Center",
        },
    }):with_parent(state.root_id)
    local col_id = col:id()

    -- Top pixel rule
    pixel_rule(col_id, 380, 0, 16)

    -- Giant title text
    local title_e = spawn({
        Text      = { text = "H E L L O" },
        TextFont  = { font_size = 90 },
        TextColor = { color = C.gold },
    }):with_parent(col_id)
    state.title_id = title_e:id()

    -- Engine sub-label
    spawn({
        Text      = { text = "G A M E   E N G I N E" },
        TextFont  = { font_size = 16 },
        TextColor = { color = C.accent },
        Node      = { margin = { top = { Px = 4 } } },
    }):with_parent(col_id)

    -- Version tag
    spawn({
        Text      = { text = "v0.4  |  Press Start" },
        TextFont  = { font_size = 12 },
        TextColor = { color = C.dim },
        Node      = { margin = { top = { Px = 4 } } },
    }):with_parent(col_id)

    -- Bottom pixel rule
    pixel_rule(col_id, 380, 16, 32)

    -- ── Menu card ──────────────────────────────────────────────────
    local card = spawn({
        Node = {
            flex_direction = "Column",
            align_items    = "Center",
            padding        = { left = { Px = 28 }, right  = { Px = 28 },
                               top  = { Px = 24 }, bottom = { Px = 24 } },
        },
        -- BackgroundColor = { color = C.panel },
        BorderRadius    = { top_left    = { Px = 4 }, top_right    = { Px = 4 },
                            bottom_left = { Px = 4 }, bottom_right = { Px = 4 } },
    }):with_parent(col_id)
    local card_id = card:id()

    -- START GAME ────────────────────────────────────────────────────
    -- Despawns title screen, spawns the game entity (picked up by
    -- main.lua's PreUpdate watcher) and transitions player into the
    -- networked world.  input_mode switches to "ui" on the spawned
    -- player entity while the spawn-point camera is active, then
    -- automatically switches to "game" on first movement input.
    make_button(card_id, "  START GAME", function(world)
        print("[TITLE_SCREEN] Launching Hello game ...")
        spawn({ game = { mode = "client", port = 5001, scope_key = "lobby" } })
        if state.root_id then
            despawn(state.root_id)
            state.root_id = nil
        end
    end)

    -- OPTIONS ───────────────────────────────────────────────────────
    make_button(card_id, "  OPTIONS", function(world)
        state.options_visible = not state.options_visible
        local p = world:get_entity(state.options_panel_id)
        if p then
            p:patch({ Node = { display = state.options_visible and "Flex" or "None" } })
        end
    end)

    -- EXIT ──────────────────────────────────────────────────────────
    make_button(card_id, "  EXIT", function(world)
        -- AppExit — sends Bevy's exit event
        pcall(function() world:exit() end)
        -- Fallback for engines that expose os.exit
        os.exit(0)
    end)

    -- Blinking hint below menu
    local ps = spawn({
        Text      = { text = "[ CLICK  START  TO  PLAY ]" },
        TextFont  = { font_size = 12 },
        TextColor = { color = C.dim },
        Node      = { margin = { top = { Px = 22 } } },
    }):with_parent(col_id)
    state.press_start_id = ps:id()

    -- ── Options overlay (full-screen dark modal) ────────────────────
    local opts_overlay = spawn({
        Node = {
            position_type   = "Absolute",
            left = { Px = 0 }, top    = { Px = 0 },
            right = { Px = 0 }, bottom = { Px = 0 },
            justify_content = "Center",
            align_items     = "Center",
            display         = "None",
        },
        -- BackgroundColor = { color = C.overlay },
        GlobalZIndex    = { value = 210 },
    }):with_parent(state.root_id)
    state.options_panel_id = opts_overlay:id()

    local opts_card = spawn({
        Node = {
            flex_direction = "Column",
            align_items    = "Stretch",
            min_width      = { Px = 430 },
            padding        = { left = { Px = 36 }, right  = { Px = 36 },
                               top  = { Px = 28 }, bottom = { Px = 28 } },
            row_gap        = { Px = 2 },
        },
        -- BackgroundColor = { color = C.card },
        BorderRadius    = { top_left    = { Px = 4 }, top_right    = { Px = 4 },
                            bottom_left = { Px = 4 }, bottom_right = { Px = 4 } },
    }):with_parent(opts_overlay:id())
    local opts_id = opts_card:id()

    -- Options header
    spawn({
        Text      = { text = "OPTIONS" },
        TextFont  = { font_size = 30 },
        TextColor = { color = C.gold },
        Node      = { margin = { bottom = { Px = 20 } } },
    }):with_parent(opts_id)

    -- ── Resolution row ─────────────────────────────────────────────
    section_label(opts_id, "SCREEN RESOLUTION")

    local res_row = spawn({
        Node = {
            flex_direction = "Row",
            align_items    = "Center",
            column_gap     = { Px = 10 },
            margin         = { bottom = { Px = 18 } },
        },
    }):with_parent(opts_id)
    local res_row_id = res_row:id()

    -- ◀ previous resolution
    make_small_btn(res_row_id, "◀", function(world)
        state.resolution_index = ((state.resolution_index - 2) % #RESOLUTIONS) + 1
        local res = RESOLUTIONS[state.resolution_index]
        local disp = world:get_entity(state.res_display_id)
        if disp then disp:set({ Text = { text = res[3] } }) end
        apply_resolution(world, res[1], res[2])
    end)

    -- Resolution label (centre of row)
    local res_lbl = spawn({
        Text      = { text = RESOLUTIONS[state.resolution_index][3] },
        TextFont  = { font_size = 15 },
        TextColor = { color = C.white },
        Node      = { width = { Px = 220 }, align_self = "Center" },
    }):with_parent(res_row_id)
    state.res_display_id = res_lbl:id()

    -- ▶ next resolution
    make_small_btn(res_row_id, "▶", function(world)
        state.resolution_index = (state.resolution_index % #RESOLUTIONS) + 1
        local res = RESOLUTIONS[state.resolution_index]
        local disp = world:get_entity(state.res_display_id)
        if disp then disp:set({ Text = { text = res[3] } }) end
        apply_resolution(world, res[1], res[2])
    end)

    -- ── Volume row ─────────────────────────────────────────────────
    section_label(opts_id, "AUDIO VOLUME")

    local vol_row = spawn({
        Node = {
            flex_direction = "Row",
            align_items    = "Center",
            column_gap     = { Px = 10 },
            margin         = { bottom = { Px = 24 } },
        },
    }):with_parent(opts_id)
    local vol_row_id = vol_row:id()

    local function vol_text(v) return string.format("%3d%%", math.floor(v * 100 + 0.5)) end

    -- − decrease volume
    make_small_btn(vol_row_id, "−", function(world)
        state.volume = math.max(0.0, state.volume - 0.1)
        local d = world:get_entity(state.vol_display_id)
        if d then d:set({ Text = { text = vol_text(state.volume) } }) end
        apply_volume(world)
    end)

    -- Volume percentage label
    local vol_lbl = spawn({
        Text      = { text = vol_text(state.volume) },
        TextFont  = { font_size = 15 },
        TextColor = { color = C.white },
        Node      = { width = { Px = 220 }, align_self = "Center" },
    }):with_parent(vol_row_id)
    state.vol_display_id = vol_lbl:id()

    -- + increase volume
    make_small_btn(vol_row_id, "+", function(world)
        state.volume = math.min(1.0, state.volume + 0.1)
        local d = world:get_entity(state.vol_display_id)
        if d then d:set({ Text = { text = vol_text(state.volume) } }) end
        apply_volume(world)
    end)

    -- Close options
    make_button(opts_id, "  CLOSE", function(world)
        state.options_visible = false
        local p = world:get_entity(state.options_panel_id)
        if p then p:patch({ Node = { display = "None" } }) end
    end)

    -- ── Title-screen music ──────────────────────────────────────────
    local ok, music_asset = pcall(load_asset, "modules/title_screen/audio/title_screen.wav")
    if ok and music_asset then
        local music_e = spawn({
            AudioPlayer     = music_asset,
            PlaybackSettings = {
                mode   = "Loop",
                volume = { Linear = state.volume },
            },
        }):with_parent(state.root_id)
        state.music_id = music_e:id()
        print("[TITLE_SCREEN] Music started (title_screen.wav, looping)")
    else
        print("[TITLE_SCREEN] WARNING: Could not load title_screen.wav — music skipped")
    end

    print("[TITLE_SCREEN] Ready")
end)

------------------------------------------------------------------------
-- Animation update: title shimmer, star blink, press-start blink
------------------------------------------------------------------------

register_system("Update", function(world)
    -- Stop animating once the title screen is gone
    if not state.root_id or not world:get_entity(state.root_id) then return end

    local dt = world:delta_time()
    state.anim_time  = state.anim_time + dt
    state.frame_count = state.frame_count + 1
    local t = state.anim_time

    -- Title rainbow shimmer (every frame, smooth)
    if state.title_id then
        local e = world:get_entity(state.title_id)
        if e then
            local col = hue_color((t * 0.14) % 1.0)
            e:patch({ TextColor = { color = col } })
        end
    end

    -- Star-field blinking (every 4 frames to save bandwidth)
    if state.frame_count % 4 == 0 then
        for _, star in ipairs(state.star_ids) do
            local alpha = 0.15 + 0.80 * (math.sin(t * star.speed + star.phase) * 0.5 + 0.5)
            local e = world:get_entity(star.id)
            if e then
                -- e:patch({ BackgroundColor = { r = 0.85, g = 0.90, b = 1.0, a = alpha } } )
            end
        end
    end
    end

    -- "PRESS START" blink (every 0.55 s)
    state.blink_timer = state.blink_timer + dt
    if state.blink_timer >= 0.55 then
        state.blink_timer = state.blink_timer - 0.55
        state.blink_on    = not state.blink_on
        if state.press_start_id then
            local e = world:get_entity(state.press_start_id)
            if e then
                local a = state.blink_on and 0.60 or 0.0
                e:patch({ TextColor = { color = { r = 0.55, g = 0.55, b = 0.72, a = a } } })
            end
        end
    end
end, { label = "TitleScreenAnim", after = { "Input" } })
