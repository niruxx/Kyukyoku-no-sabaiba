-- modules/camera/2d/server/init.lua
-- Server-side camera/2d authority setup.

register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "camera/2d" } })) do
        entity:patch({
            net_sync = {
                ["camera/2d"] = { authority = "client", targets = { "owner" } },
            },
        })
        print(string.format("[CAMERA2D/SERVER] Authority override for entity %d", entity:id()))
    end
end)
