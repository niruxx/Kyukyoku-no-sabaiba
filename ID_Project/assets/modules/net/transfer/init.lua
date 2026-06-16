-- modules/net/transfer/init.lua
-- Per-scope transfer writer: detects changed synced components on entities
-- with net_transfer and patches net_transfer.data so the relay picks it up.
-- The relay (relay.lua at scope 0) handles cross-scope synchronization.

local Tracking = require("modules/net/shared/tracking.lua")

local json = require "modules/dkjson.lua"

register_system("PostUpdate", function(world)
    local ts = Tracking.state()
    if not next(ts.tracked) then return end  -- nothing tracked yet

    local changed_entities = Tracking.get_changed_entities(world)

    for _, entity in ipairs(changed_entities) do
        local full = world:get_entity(entity:id())
        if not full then goto continue end
        if not full:has("net_transfer") then goto continue end
        if full:has("_net_transfer_mirror") then goto continue end

        local sync = entity:get("net_sync")
        local changed = Tracking.collect_changed_components(entity, sync)
        if next(changed) then
            full:patch({ net_transfer = { data = changed } })
        end
        ::continue::
    end
end, { label = "NetTransferWrite", after = { "NetSyncTrack" } })
