---
trigger: model_decision
description: Net module API reference — filters, handlers, id_map, and shared tracking
---

# Net API Reference

## `modules/net/shared/net.lua`

```lua
local Net = require("modules/net/shared/net.lua")
```

### Constants

```lua
Net.CHANNEL_RELIABLE   -- 0
Net.CHANNEL_UNRELIABLE -- 1

Net.MSG.CLIENT_ID      -- "client_id"
Net.MSG.CLIENT_ID_ACK  -- "client_id_ack"
Net.MSG.SPAWN          -- "spawn"
Net.MSG.UPDATE         -- "update"
Net.MSG.DESPAWN        -- "despawn"
Net.MSG.SPAWN_REQUEST  -- "spawn_request"
Net.MSG.SPAWN_CONFIRM  -- "spawn_confirm"
Net.MSG.SPAWN_REJECT   -- "spawn_reject"
Net.MSG.DESPAWN_REQUEST -- "despawn_request"
```

### ID Map

```lua
local id_map = Net.create_id_map()  -- { net_to_entity = {}, entity_to_net = {} }
Net.map(id_map, net_id, entity_id)
Net.unmap(id_map, net_id, entity_id)
```

### Target Filters

```lua
-- Register a custom filter
Net.register_filter("team", function(client_id, entity, owner_id)
    return entity:get("team").id == get_team(client_id)
end)

-- Check if a message should be sent
Net.should_send_to(filter_name, client_id, entity, owner_id) -- → boolean
```

Built-in: `"all"`, `"owner"`, `"others"`

### Message Handlers

```lua
-- Register a custom message handler
Net.register_handler("chat", function(world, msg, sender_id)
    -- sender_id is client_id on server, nil on client
end)

-- Dispatch (called by inbound systems)
Net.dispatch(world, msg, sender_id) -- → boolean (true if handler ran)
```

## `modules/net/shared/tracking.lua`

```lua
local Tracking = require("modules/net/shared/tracking.lua")
```

### Sync Detection

```lua
-- Detect net_sync add/change/remove
local changes = Tracking.detect_sync_changes(world, net_entity_id)
-- → { added = {entity...}, changed = {entity...}, removed = {entity...} }

-- Detect reparenting (ChildOf changed on net_sync entities)
local entered, left = Tracking.detect_reparented(world, net_entity_id, id_map)

-- Detect ownership changes
local changed = Tracking.detect_ownership_changes(world, net_entity_id)
```

### Changed Component Queries

```lua
-- Rebuild cached synced component names (call when synced_dirty)
local all_synced = Tracking.rebuild_synced_names(tracked)

-- Query entities with ≥1 changed synced component (zero-cost when nothing changed)
local entities = Tracking.query_changed(world, net_entity_id, all_synced)

-- Collect changed components for a single entity
local changed = Tracking.collect_changed_components(entity, sync_config)
-- → { comp_name = data } for changed components only
```

### Pending Parent Queue

```lua
local pending = Tracking.create_pending_queue()
Tracking.queue_pending(pending, parent_key, payload)
local items = Tracking.flush_pending(pending, parent_key) -- → array or nil
```

### Hierarchy

```lua
-- Translate ChildOf entity_id → net_id
local parent_net_id = Tracking.translate_child_of(entity, id_map)
```
