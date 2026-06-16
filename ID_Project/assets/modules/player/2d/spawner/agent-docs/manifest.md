---
depends_on: []
conflicts_with: []
exposes: [player/2d/spawner]
---

# player/2d/spawner

Server-only player spawner for 2D. Manages spawn points and handles player entity lifecycle across client connections and disconnections. Reacts to `net_client` additions to spawn player entities with full physics, camera, input, animation, and networking configurations.

## Components

- `player/2d/spawner` — Spawner marker component.

## Resources

- `PlayerSpawnerState` — Tracks `spawn_points` (entities, occupancy, associated client), `player_entities` (client_id -> entity_id), and `spawner_entity_id`.

## Systems

### Server
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "player/2d/spawner" }`: Create a ring of `NUM_SPAWNS` empty spawn point entities as children |
| PreUpdate | - | - | `added { "net_client" }`: Find a free spawn point (or use `net_transfer` data for cross-scope), claim it, and spawn a new player entity loaded with `player`, `input`, `camera/2d`, `movement/2d`, and `animation/sprite` |
| PreUpdate | - | NetServerInbound | Detect removed `net_client` entities, free the associated spawn point, and despawn the player entity |
