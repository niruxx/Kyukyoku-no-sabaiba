-- modules/player/client/init.lua
-- Client-side player: reacts to player entities for all players (nameplate, markers).
-- No manual ownership check — owner-specific behavior handled by input (authority=client)
-- and camera (target=owner) mods naturally.

register_system("First", function(world)
    local entities = world:query({ added = { "player" } })
    for _, entity in ipairs(entities) do
        local player = entity:get("player") or {}
        print(string.format("[PLAYER/CLIENT] Player entity %d added (client_id=%s)",
            entity:id(), tostring(player.client_id)))
    end
end)
