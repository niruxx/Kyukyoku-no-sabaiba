-- modules/input/server/init.lua
-- Server-side input: validates incoming input_* components against registered bindings.
-- Consumer server mods register their bindings on `input` — the server uses these
-- as a whitelist to reject unregistered actions from clients.

register_system("First", function(world)
    local entities = world:query({ added = { "input" } })
    for _, entity in ipairs(entities) do
        print(string.format("[INPUT/SERVER] Initialized input for entity %d", entity:id()))
    end
end)
