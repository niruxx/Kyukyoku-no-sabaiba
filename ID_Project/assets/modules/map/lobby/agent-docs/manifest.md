---
depends_on: [net_mod, gltf_colliders]
conflicts_with: [map/default]
exposes: [map/lobby]
---

# map/lobby

A Blender-authored **lobby** hub map: a cozy building at the world origin opening through
four doorways to four themed outdoor areas — nature, underwater, fireplace, zen. Replaces
`map/default`.

Geometry is a single GLB (`assets/lobby.glb`). Collision is **mesh-derived** (trimesh) and
**opt-in**: only objects whose Blender name contains `_col` get a collider, so decorative
geometry stays collision-free. Concave-capable, so hollow rooms / doorways / stairs collide
correctly.

## Components

- `map/lobby` — Marker added by the mod loader (both sides).

## Sides

| Side | Responsibility |
|------|----------------|
| shared | Spawns `gltf_colliders` over `lobby.glb` (include `"_col"`) → static trimesh colliders. Loaded by **both** sides (the server for authority, the client for its local predicted player — otherwise the client-side player falls through). Reads the Gltf asset directly, so it also works on a headless dedicated server. |
| server | `require`s shared (colliders only). |
| client | `require`s shared (colliders) + loads `lobby.glb#Scene0` as a `SceneRoot` (visuals) + directional/ambient lighting. |

Colliders are local (not net-synced) and deterministic, so both sides build identical
geometry. Visuals are client-only.

## Authoring note

**Apply all object transforms in Blender before export** (location/rotation/scale). This
engine spawns GLB mesh primitives as entities that are *not* parented to their node entities,
so a node transform alone would leave every mesh at the world origin (all geometry overlapping
at the center). Applying transforms bakes positions into the vertices, which renders correctly
regardless and keeps the collider baker correct.

## Usage

```lua
spawn({ net_mod = { ["map/lobby"] = {} } }):with_parent(net_entity:id())
```

## Notes

- Swapped in for `map/default` in [game.lua](../../../Hello/scripts/server/game.lua) `game.init`.
- Player spawn points are a circle (radius ~3) at the origin, dropped from height 5, so the
  lobby interior is centered on the origin with a clear floor there.
- Re-exporting `lobby.glb` from Blender hot-reloads both visuals and colliders without
  touching Lua.
- See [gltf_colliders](../../gltf_colliders/agent-docs/manifest.md) for the collision pipeline.
