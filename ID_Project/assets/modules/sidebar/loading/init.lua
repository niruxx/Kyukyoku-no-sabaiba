local Colors = require("modules/sidebar/shared/colors.lua")

register_system("Update", function(world)
    -- On Added
    local added = world:query({ added = { "sidebar/loading" } })
    for _, entity in ipairs(added) do
        local cfg = entity:get("sidebar/loading") or {}
        local container_id = entity:id()
        
        local loading_panel = spawn({
            Node = {
                width = { Px = 280 }, -- Match default panel width
                height = { Percent = 100 },
                flex_direction = "Column",
                justify_content = "Center",
                align_items = "Center",
                border = { left = { Px = 1 }, right = { Px = 1 } },
            },
            BackgroundColor = { color = Colors.bg },
            BorderColor = { left = Colors.border, right = Colors.border },
        }):with_parent(container_id)

        spawn({
            Text = { text = "Loading " .. (cfg.title or "Panel") .. "..." },
            TextFont = { font_size = 14 },
            TextColor = { color = Colors.text_dim },
        }):with_parent(loading_panel:id())

        entity:set({
            ["sidebar/loading"] = { loading_panel_id = loading_panel:id() },
        })
    end

    -- On Removed
    local removed = world:query({ removed = { "sidebar/loading" } })
    for _, entity in ipairs(removed) do
        local cfg = entity:get("sidebar/loading") or {}
        if cfg.loading_panel_id then
            despawn(cfg.loading_panel_id)
        end
    end
end)
