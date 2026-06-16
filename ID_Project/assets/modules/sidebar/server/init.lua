-- modules/sidebar/server/init.lua
-- Validates client panel open/close requests.
-- Panels requested via open_panels are added as net_mod entries on the
-- player entity, giving them server + client scripts with a synced component.

---------------------------------------------------------------------------
-- Cache original button config as server-only `sidebar_buttons` component
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "sidebar" } })) do
        entity:set({ sidebar_buttons = {} })
    end
end)

---------------------------------------------------------------------------
-- Process open_panels / close_panels / register_panels requests
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, entity in ipairs(world:query({ changed = { "sidebar" } })) do
        local cfg = entity:get("sidebar")
        if not cfg then goto continue end

        -- Client registers which panel_net_mods its buttons use.
        -- Server stores as sidebar_buttons (server-only, not in net_sync).
        if cfg.register_panels then
            local buttons = entity:get("sidebar_buttons") or {}
            for mod_name, allowed in pairs(cfg.register_panels) do
                buttons[mod_name] = allowed
            end
            entity:set({ sidebar_buttons = buttons })
            entity:patch({ sidebar = { register_panels = null } })
        end

        local valid = entity:get("sidebar_buttons") or {}

        if cfg.open_panels then
            for mod, config in pairs(cfg.open_panels) do
                if valid[mod] then
                    entity:patch({
                        net_mod = { [mod] = config },
                        net_sync = { [mod] = { authority = "client", target = "owner" } },
                    })
                    -- print(string.format("[SIDEBAR] Loaded panel: %s", mod))
                else
                    print(string.format("[SIDEBAR] Rejected: %s (not registered)", mod))
                end
            end
            -- NOTE: Don't clear open_panels here — sidebar has client authority,
            -- so server patches don't replicate. The client clears it.
        end

        if cfg.close_panels then
            for mod, _ in pairs(cfg.close_panels) do
                if valid[mod] then
                    entity:patch({ net_mod = { [mod] = null } })
                    -- print(string.format("[SIDEBAR] Unloaded panel: %s", mod))
                end
            end
            -- NOTE: Don't clear close_panels here — sidebar has client authority.
        end

        ::continue::
    end
end)
