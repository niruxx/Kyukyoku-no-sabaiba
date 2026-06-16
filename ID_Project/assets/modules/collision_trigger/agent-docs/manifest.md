---
depends_on: []
conflicts_with: []
exposes: [collision_trigger]
---

# collision_trigger

Generic collision trigger net_mod. Tracks enter/exit on sensor colliders.

No filtering — consumers query colliding entities themselves:

```lua
local ct = entity:get("collision_trigger")
local players = world:query({
    with = { "player" },
    entities = ct.inside,
})
```

## Component

- `collision_trigger`:
  - `entered` — Entity IDs that entered this frame (read-only)
  - `exited` — Entity IDs that exited this frame (read-only)
  - `inside` — Map of entity IDs currently overlapping (read-only)
  - `_inside` — Internal tracking state (do not read)

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| Update | CollisionTrigger | Computes enter/exit deltas from CollidingEntities3d |

## Usage

Add as net_mod on any entity with a sensor collider:

```lua
entity:patch({
    Sensor3d = {},
    Collider3d = { ball = { radius = 2.0 } },
    CollidingEntities3d = {},
    ActiveEvents3d = "COLLISION_EVENTS",
    net_mod = { collision_trigger = {} },
})
```

The entity must have:
- `RigidBody3d` (typically `"Fixed"` for triggers)
- `Collider3d` (shape of the trigger zone)
- `Sensor3d` (prevents physical blocking)
- `CollidingEntities3d` (engine fills with overlapping entity IDs)
- `ActiveEvents3d = "COLLISION_EVENTS"` (enables collision event generation)

React to enter/exit events:

```lua
register_system("Update", function(world)
    for _, e in ipairs(world:query({ changed = { "collision_trigger" } })) do
        local ct = e:get("collision_trigger")
        for _, entered_id in ipairs(ct.entered or {}) do
            local entered_entity = world:get_entity(entered_id)
            -- ... react to entity entering the trigger zone
        end
        for _, exited_id in ipairs(ct.exited or {}) do
            -- ... react to entity leaving the trigger zone
        end
    end
end, { after = { "CollisionTrigger" } })
```
