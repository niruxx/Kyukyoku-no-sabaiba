-- modules/map/tiled/shared/init.lua
-- Shared Tiled map loader. Both server and client create the same map entity.

register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "map/tiled" } })) do
        local cfg = entity:get("map/tiled") or {}
        local tmx_path = cfg.tmx_path or "map.tmx"

        spawn({
            TiledMap = load_asset(tmx_path),
            Transform = {},
        }):with_parent(entity:id())

        print("[MAP/TILED] Spawned Tiled map: " .. tmx_path)
    end
    return true
end)
