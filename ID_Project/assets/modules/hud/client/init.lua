-- modules/hud/client/init.lua
-- Top-left HUD: health bar + per-weapon cooldown bars.
-- Full-screen death overlay with respawn button when player hp reaches 0.
-- Loaded via net_mod { hud = {} } with target="owner" so it only fires
-- for the player entity owned by this client — never for other players.
-- Cooldown state is read from the shared ClientWeaponCooldowns resource
-- (owned and incremented by weapons/client/init.lua).

---------------------------------------------------------------------------
-- Shared cooldown resource — weapons/client writes, we read
---------------------------------------------------------------------------
local cd = define_resource("ClientWeaponCooldowns", {
    elapsed    = 0.0,
    last_fired = { railgun = -999.0, explosives = -999.0, nova = -999.0 },
    cooldowns  = { railgun = 0.5,    explosives = 2.5,    nova  = 8.0   },
})

---------------------------------------------------------------------------
-- Display metadata for each weapon
---------------------------------------------------------------------------
local WEAPONS = {
    { key = "Q", name = "railgun",    label = "Rail Gun"   },
    { key = "E", name = "explosives", label = "Explosives" },
    { key = "R", name = "nova",       label = "Nova"       },
}

local BAR_W    = 160
local BAR_H    = 10
local HP_BAR_H = 14
local PANEL_W  = 240
local PAD      = 10

---------------------------------------------------------------------------
-- Colours
---------------------------------------------------------------------------
local C = {
    bg         = { r = 0.0,  g = 0.0,  b = 0.0,  a = 0.70 },
    track      = { r = 0.15, g = 0.15, b = 0.15, a = 1.0  },
    hp_high    = { r = 0.18, g = 0.82, b = 0.25, a = 1.0  },
    hp_mid     = { r = 0.95, g = 0.75, b = 0.05, a = 1.0  },
    hp_low     = { r = 0.90, g = 0.15, b = 0.10, a = 1.0  },
    cd_ready   = { r = 0.20, g = 0.75, b = 1.00, a = 1.0  },
    cd_cool    = { r = 0.45, g = 0.45, b = 0.55, a = 1.0  },
    label      = { r = 0.90, g = 0.90, b = 0.90, a = 1.0  },
    dim        = { r = 0.55, g = 0.55, b = 0.60, a = 1.0  },
    key_badge  = { r = 0.22, g = 0.22, b = 0.30, a = 1.0  },
    separator  = { r = 0.25, g = 0.25, b = 0.35, a = 1.0  },
    death_bg   = { r = 0.00, g = 0.00, b = 0.00, a = 0.78 },
    death_red  = { r = 0.95, g = 0.10, b = 0.10, a = 1.0  },
    spawn_btn  = { r = 0.08, g = 0.32, b = 0.08, a = 1.0  },
    spawn_hov  = { r = 0.15, g = 0.55, b = 0.15, a = 1.0  },
    spawn_bdr  = { r = 0.30, g = 0.80, b = 0.30, a = 1.0  },
}

---------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------
local hud = define_resource("HudState", {
    initialized     = false,
    player_eid      = nil,
    hp_fill_id      = nil,
    hp_text_id      = nil,
    weapon_fills    = {},
    weapon_texts    = {},
    is_dead         = false,
    death_screen_id = nil,
})

---------------------------------------------------------------------------
-- Layout helpers
---------------------------------------------------------------------------
local function row(parent_id, gap_px)
    return spawn({
        Node = {
            flex_direction = "Row",
            align_items    = "Center",
            column_gap     = { Px = gap_px or 6 },
            margin         = { bottom = { Px = 5 } },
        },
    }):with_parent(parent_id)
end

local function make_bar(parent_id, w, h, fill_pct, fill_color)
    local track = spawn({
        Node = {
            width    = { Px = w },
            height   = { Px = h },
            overflow = { x = "Hidden", y = "Hidden" },
        },
        BackgroundColor = { color = C.track },
        BorderRadius    = { top_left = { Px = 2 }, top_right    = { Px = 2 },
                            bottom_left = { Px = 2 }, bottom_right = { Px = 2 } },
    }):with_parent(parent_id)

    local fill = spawn({
        Node = {
            width  = { Percent = fill_pct },
            height = { Percent = 100 },
        },
        BackgroundColor = { color = fill_color },
        BorderRadius    = { top_left = { Px = 2 }, top_right    = { Px = 2 },
                            bottom_left = { Px = 2 }, bottom_right = { Px = 2 } },
    }):with_parent(track:id())

    return fill:id()
end

local function key_badge(parent_id, key_text)
    local badge = spawn({
        Node = {
            width           = { Px = 22 },
            height          = { Px = 22 },
            justify_content = "Center",
            align_items     = "Center",
        },
        BackgroundColor = { color = C.key_badge },
        BorderRadius    = { top_left = { Px = 3 }, top_right    = { Px = 3 },
                            bottom_left = { Px = 3 }, bottom_right = { Px = 3 } },
    }):with_parent(parent_id)

    spawn({
        Text      = { text = key_text },
        TextFont  = { font_size = 11 },
        TextColor = { color = C.label },
    }):with_parent(badge:id())
end

---------------------------------------------------------------------------
-- Death screen: full-screen overlay with YOU DIED + RESPAWN button
---------------------------------------------------------------------------
local function spawn_death_screen()
    local player_eid = hud.player_eid

    local overlay = spawn({
        Node = {
            position_type   = "Absolute",
            left            = { Px = 0 },
            top             = { Px = 0 },
            width           = { Percent = 100 },
            height          = { Percent = 100 },
            flex_direction  = "Column",
            justify_content = "Center",
            align_items     = "Center",
            row_gap         = { Px = 20 },
        },
        BackgroundColor = { color = C.death_bg },
        GlobalZIndex    = { value = 100 },
    })
    local oid = overlay:id()

    spawn({
        Text      = { text = "YOU DIED" },
        TextFont  = { font_size = 72 },
        TextColor = { color = C.death_red },
    }):with_parent(oid)

    spawn({
        Text      = { text = "Zombies got you..." },
        TextFont  = { font_size = 20 },
        TextColor = { color = C.dim },
        Node      = { margin = { bottom = { Px = 12 } } },
    }):with_parent(oid)

    local btn = spawn({
        Button = {},
        Node   = {
            width           = { Px = 220 },
            height          = { Px = 58 },
            justify_content = "Center",
            align_items     = "Center",
            border          = { left = { Px = 2 }, right  = { Px = 2 },
                                top  = { Px = 2 }, bottom = { Px = 2 } },
        },
        BackgroundColor = { color = C.spawn_btn },
        BorderColor     = { color = C.spawn_bdr },
        BorderRadius    = { top_left = { Px = 6 }, top_right    = { Px = 6 },
                            bottom_left = { Px = 6 }, bottom_right = { Px = 6 } },
    }):with_parent(oid)

    spawn({
        Text      = { text = "RESPAWN" },
        TextFont  = { font_size = 22 },
        TextColor = { color = { r = 0.9, g = 1.0, b = 0.9, a = 1.0 } },
    }):with_parent(btn:id())

    btn:observe("Pointer<Over>", function(_, b)
        b:patch({ BackgroundColor = { color = C.spawn_hov } })
    end)
    btn:observe("Pointer<Out>", function(_, b)
        b:patch({ BackgroundColor = { color = C.spawn_btn } })
    end)
    btn:observe("Pointer<Click>", function(world, _)
        local player = world:get_entity(player_eid)
        if player then
            player:patch({ respawn_request = { active = true } })
        end
    end)

    return oid
end

---------------------------------------------------------------------------
-- Build HUD once when the owner's player entity gains the "hud" component
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "hud" } })) do
        if hud.initialized then goto continue end
        hud.initialized = true
        hud.player_eid  = entity:id()

        local root = spawn({
            Node = {
                position_type  = "Absolute",
                left           = { Px = 12 },
                top            = { Px = 12 },
                flex_direction = "Column",
                padding        = { left = { Px = PAD }, right  = { Px = PAD },
                                   top  = { Px = PAD }, bottom = { Px = PAD } },
                row_gap        = { Px = 4 },
                min_width      = { Px = PANEL_W },
            },
            BackgroundColor = { color = C.bg },
            BorderRadius    = { top_left = { Px = 6 }, top_right    = { Px = 6 },
                                bottom_left = { Px = 6 }, bottom_right = { Px = 6 } },
            GlobalZIndex    = { value = 50 },
        })
        local root_id = root:id()

        spawn({
            Text      = { text = "HEALTH" },
            TextFont  = { font_size = 10 },
            TextColor = { color = C.dim },
            Node      = { margin = { bottom = { Px = 3 } } },
        }):with_parent(root_id)

        local hp_row_id = row(root_id, 8):id()

        spawn({
            Text      = { text = "♥" },
            TextFont  = { font_size = 14 },
            TextColor = { color = C.hp_high },
        }):with_parent(hp_row_id)

        hud.hp_fill_id = make_bar(hp_row_id, BAR_W, HP_BAR_H, 100, C.hp_high)

        local hp_text_e = spawn({
            Text      = { text = "100" },
            TextFont  = { font_size = 11 },
            TextColor = { color = C.label },
            Node      = { min_width = { Px = 28 } },
        }):with_parent(hp_row_id)
        hud.hp_text_id = hp_text_e:id()

        spawn({
            Node = {
                width  = { Percent = 100 },
                height = { Px = 1 },
                margin = { top = { Px = 3 }, bottom = { Px = 3 } },
            },
            BackgroundColor = { color = C.separator },
        }):with_parent(root_id)

        spawn({
            Text      = { text = "WEAPONS" },
            TextFont  = { font_size = 10 },
            TextColor = { color = C.dim },
            Node      = { margin = { bottom = { Px = 3 } } },
        }):with_parent(root_id)

        for _, wep in ipairs(WEAPONS) do
            local wrow_id = row(root_id, 6):id()
            key_badge(wrow_id, wep.key)

            spawn({
                Text      = { text = wep.label },
                TextFont  = { font_size = 11 },
                TextColor = { color = C.label },
                Node      = { min_width = { Px = 72 } },
            }):with_parent(wrow_id)

            hud.weapon_fills[wep.name] = make_bar(wrow_id, BAR_W - 100, BAR_H, 100, C.cd_ready)

            local wtext_e = spawn({
                Text      = { text = "Ready" },
                TextFont  = { font_size = 10 },
                TextColor = { color = C.cd_ready },
                Node      = { min_width = { Px = 36 } },
            }):with_parent(wrow_id)
            hud.weapon_texts[wep.name] = wtext_e:id()
        end

        print(string.format("[HUD/CLIENT] Built for player entity %d", entity:id()))
        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Per-frame HUD update: health, cooldowns, and death screen management
---------------------------------------------------------------------------
register_system("Update", function(world)
    if not hud.initialized or not hud.player_eid then return end

    local player = world:get_entity(hud.player_eid)
    if not player then return end

    -- ── Health bar ────────────────────────────────────────────────────────
    local ph = player:get("player_health")
    local hp     = ph and math.max(0, ph.hp     or 0) or 0
    local max_hp = ph and math.max(1, ph.max_hp or 100) or 100
    local hp_pct = (hp / max_hp) * 100

    if hud.hp_fill_id then
        local fill_color = hp_pct > 50 and C.hp_high or (hp_pct > 25 and C.hp_mid or C.hp_low)
        local fill_e = world:get_entity(hud.hp_fill_id)
        if fill_e then
            fill_e:patch({
                Node            = { width = { Percent = hp_pct } },
                BackgroundColor = { color = fill_color },
            })
        end
        local text_e = world:get_entity(hud.hp_text_id)
        if text_e then
            text_e:patch({ Text = { text = tostring(math.ceil(hp)) } })
        end
    end

    -- ── Death screen ──────────────────────────────────────────────────────
    if hp <= 0 and not hud.is_dead then
        hud.is_dead         = true
        hud.death_screen_id = spawn_death_screen()
    elseif hp > 0 and hud.is_dead then
        hud.is_dead = false
        if hud.death_screen_id then
            local ds = world:get_entity(hud.death_screen_id)
            if ds then despawn(ds) end
            hud.death_screen_id = nil
        end
    end

    -- ── Weapon cooldown bars ──────────────────────────────────────────────
    for _, wep in ipairs(WEAPONS) do
        local last      = cd.last_fired[wep.name] or -999
        local cooldown  = cd.cooldowns[wep.name]  or 0.5
        local remaining = math.max(0, cooldown - (cd.elapsed - last))
        local pct       = (1.0 - remaining / cooldown) * 100

        local fill_e = world:get_entity(hud.weapon_fills[wep.name])
        if fill_e then
            fill_e:patch({
                Node            = { width = { Percent = pct } },
                BackgroundColor = { color = remaining <= 0 and C.cd_ready or C.cd_cool },
            })
        end

        local text_e = world:get_entity(hud.weapon_texts[wep.name])
        if text_e then
            local label = remaining <= 0 and "Ready" or string.format("%.1fs", remaining)
            text_e:patch({
                Text      = { text  = label },
                TextColor = { color = remaining <= 0 and C.cd_ready or C.dim },
            })
        end
    end
end, { label = "HudUpdate", after = { "Input" } })
