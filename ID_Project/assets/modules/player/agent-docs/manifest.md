---
depends_on: [net_mod, input, camera, movement, animation, abilities]
conflicts_with: []
exposes: [player, player_spawner, spawn_point]
---

# player

Manages player lifecycle: spawn points, player entity creation on connect, cleanup on disconnect.

## Components

- `player` — Player marker. `{ client_id, spawn_index }`. Set by the spawner on the player entity.
- `spawn_point` — Spawn point marker. `{ occupied, index }`. Children of the spawner entity.
- `player_spawner` — Spawner marker. Loaded via `mod` (server-only).

## Resources

- `PlayerSpawnerState` — Spawn point tracking, player→entity mapping.

## Systems

### Spawner (server-only, loaded via `mod`)

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | Create spawn points in a circle |
| PreUpdate | — | Handle `net:client_connected` → spawn player |
| PreUpdate | — | Handle `net:client_disconnected` → free spawn, despawn player |

### Player mod (loaded via `net_mod`)

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | Server: log player additions. Client: log player additions (all players). |

## Spawn Point Layout

8 points in a circle, radius 3.0, height 1.0. Occupancy-tracked — each client gets a unique spawn.

## Player Entity Shape

```lua
{
    Transform, RigidBody3d = "Dynamic", Collider3d (capsule), LockedAxes3d, Velocity3d,
    net_owner = { client_id = N },
    net_sync = { Transform = { authority = "server", reliable = false } },
    net_sync_Transform = {},
    player = { client_id, spawn_index },
    net_mod = { input, camera/third_person, movement, animation, abilities },
}
```
