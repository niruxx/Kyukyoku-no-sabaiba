-- modules/camera/server/init.lua
-- Server-side camera base: overrides net_sync authority to client, targets owner only.

register_system("First", function(world)
    local entities = world:query({ added = { "camera" } })
    for _, entity in ipairs(entities) do
        -- Camera is client-authoritative, only sent to owning client
        entity:patch({
            net_sync = {
                camera = { authority = "client", targets = { "owner" } },
            },
        })
        print(string.format("[CAMERA/SERVER] Authority override for entity %d", entity:id()))
    end
end)
