---
depends_on: [net_mod]
conflicts_with: []
exposes: [map/default]
---

# map/default

Simple ground plane with directional lighting. Uses a shared script — both server and client spawn identical geometry, so no network replication is needed.

## Components

- `map/default` — Marker component added by mod loader.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | One-shot: spawn ground plane (cuboid collider) + directional light + ambient light |

## Usage

```lua
spawn({ net_mod = { ["map/default"] = {} } }):with_parent(net_entity:id())
```

## Notes

- Ground plane is a 100×100 cuboid at y=0 with a `RigidBody3d = "Fixed"` collider
- Swappable: replace with `map/arena` or any other map mod
