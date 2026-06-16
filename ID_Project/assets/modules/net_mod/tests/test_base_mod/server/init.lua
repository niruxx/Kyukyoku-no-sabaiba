-- modules/net_mod/tests/test_base_mod/server/init.lua
-- Test fixture: base module for base-chain testing.
-- Patches { base_loaded = true } onto the test_base_mod component when added.

register_system("First", function(world)
    local entities = world:query({ added = { "net_mod/tests/test_base_mod" } })
    for _, entity in ipairs(entities) do
        entity:patch({ ["net_mod/tests/test_base_mod"] = { base_loaded = true } })
    end
end)
