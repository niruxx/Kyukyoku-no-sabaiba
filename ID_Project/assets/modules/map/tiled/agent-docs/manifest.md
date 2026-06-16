---
depends_on: []
conflicts_with: []
exposes: [map/tiled]
---

# map/tiled

Shared 2D map mod that loads a `.tmx` file through `bevy_ecs_tiled`. Both client and server spawn the Tiled map entity natively from the same asset path to ensure they have matching world state without needing network sync for the static map itself.

## Components

- `map/tiled` — Configuration for the tiled map. Contains:
  - `tmx_path` (string): Asset path to the `.tmx` file. Defaults to `"map.tmx"`.

## Systems

### Shared
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "map/tiled" }`: Spawn a child entity with a `TiledMap` component and a `Transform` |
