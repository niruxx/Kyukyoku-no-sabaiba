---
depends_on: []
conflicts_with: []
exposes: [gltf_colliders]
---

# gltf_colliders

Bakes **trimesh colliders from a GLB's actual geometry** — opt-in by node-name marker. The
"proper" collision approach for maps: colliders match the authored shapes (concave-capable —
hollow rooms, doorways, stairs) rather than approximating with primitives.

## Architecture (pure Lua, one Rust primitive)

All orchestration lives in Lua (`init.lua`):
1. A one-shot `First` system spawns the GLB as a `SceneRoot` child of the config entity.
2. An `Update` system recursively walks the `ChildOf` hierarchy from the config entity.
3. For each entity whose `Name` contains `include` AND has a `Mesh3d` component:
   ```lua
   world:call_systemparam_method("Collider", "from_bevy_mesh", entity:id(), "TriMesh")
   ```
4. The Rust primitive resolves `Mesh3d` → `Handle<Mesh>` → `Assets<Mesh>`, calls
   `Collider::from_bevy_mesh(mesh, &ComputedColliderShape::TriMesh(...))`, and inserts
   the `Collider` component on the entity. Returns `true`/`false`/`nil` (not loaded yet).
5. The Lua system also sets `RigidBody3d = "Fixed"` on each collider entity.

## Component

- `gltf_colliders` — Config marker added by the mod loader:
  - `scene` — path to the GLB (e.g. `"modules/map/lobby/assets/lobby.glb"`).
  - `include` — node-name substring that marks collidable nodes (default `"_col"`).

## How collision is tagged

Collision is **opt-in**: in Blender, name the collidable objects with the marker (default a
`_col` substring). Only those meshes get a trimesh collider; decorative geometry, foliage,
water, etc. stay collision-free.

## Usage

```lua
spawn({
    Transform = {},
    mod = { ["gltf_colliders"] = {
        scene = "modules/map/lobby/assets/lobby.glb",
        include = "_col",
    } },
})
```

## Notes

- Trimesh cost scales with the **tagged** triangle count — keep collidable meshes reasonably
  low-poly. Build is one-time at load; Rapier's QBVH keeps per-frame queries cheap.
- The scene IS spawned (as a SceneRoot child), so it works on both client and server
  (with HeadlessSceneSupport on the server). The visual scene on the client is loaded
  separately.
- `Collider::from_bevy_mesh` is a general-purpose Lua primitive registered under the
  `"Collider"` type name. Any Lua code can call it on any entity with `Mesh3d`.
