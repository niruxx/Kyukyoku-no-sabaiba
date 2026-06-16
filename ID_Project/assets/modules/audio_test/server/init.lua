-- modules/audio_test/server/init.lua
-- Server-side: Initialize the audio_test component on added entities.
-- Audio playback happens client-side only; this just ensures the component
-- exists and is properly initialized for net_sync replication.

register_system("First", function(world)
    local entities = world:query({ added = { "audio_test" } })
    for _, entity in ipairs(entities) do
        entity:patch({ audio_test = {
            status = "pending",   -- client will set to "playing"
        }})
        print(string.format("[AUDIO_TEST/SERVER] Initialized audio_test on entity %d", entity:id()))
    end
end)
