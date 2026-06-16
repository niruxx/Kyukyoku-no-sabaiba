-- modules/player/server/init.lua
-- Server-side player: reacts to player entity being added for server-side tracking.

register_system("First", function(world)
    local entities = world:query({ added = { "player" }, with = { "Transform" } })
    for _, entity in ipairs(entities) do
        local player = entity:get("player") or {}
        print(string.format("[PLAYER/SERVER] Player entity %d added (client_id=%s, spawn=%s)",
            entity:id(),
            tostring(player.client_id),
            tostring(player.spawn_index)))
    end
end)
