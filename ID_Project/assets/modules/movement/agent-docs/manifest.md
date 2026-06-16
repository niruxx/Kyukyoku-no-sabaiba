---
depends_on: [net_mod, input]
conflicts_with: []
exposes: [movement]
---

# movement

Rapier physics movement running identical logic on both server and client. Reads
`input` component for raw key state and `camera.yaw`, computes world-space
direction via shared `movement.lua`, writes `Velocity3d`. Rapier handles gravity,
collision, and ground detection on both sides. Client-side reconciliation via the
net prediction layer (`predict = true` on `Transform`). Remote avatars interpolated
via `net_sync_Transform` shadow.

## Components

- `movement` — Config + state. `{ speed, jump_force, grounded, last_jump_time }`. Authority: server.

## Systems

### Server

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | (init) | — | Register input bindings, declare net_sync, ensure Velocity3d exists, init movement state |
| Update | Movement | CameraPosition | Compute velocity from input + camera_yaw, preserve Rapier gravity Y, raycast grounded check, jump, update grounded state |
| Update | (rotation) | Movement | VR: slerp toward camera yaw. Desktop: slerp toward velocity direction |

### Client

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | (init) | — | Register input bindings, init interpolation shadow + jump tracking. Rapier stays active (NOT disabled) |
| Update | Movement | Input | Mirror server logic: compute velocity, preserve Rapier gravity Y, raycast grounded check, jump, rotation |
| Update | MovementInterpolation | Movement | Remote avatars: lerp/slerp Transform toward net_sync_Transform shadow |

## Movement Pipeline

1. Read raw input: `forward`, `backward`, `left`, `right`, `jump`
2. Build input vector → `Vec3.normalize_or_zero`
3. Rotate by `camera_yaw` → `Quat.from_rotation_y` + `Quat.mul_vec3`
4. Read current `Velocity3d.linvel.y` (preserves Rapier gravity from previous frame)
5. Write `Velocity3d` with horizontal velocity + preserved Y
6. Ground detection: `ReadRapierContext3d:cast_ray` downward raycast (shared `is_grounded()`)
7. Jump: override `vel.y = jump_force` directly when grounded + jump pressed
8. Slerp rotation toward movement direction (or camera yaw in VR)

## Client Prediction Architecture

Both server and client run Rapier physics. The client does NOT set `RigidBodyDisabled3d`.
This gives the client real gravity, collision, and ground detection — same as the server.

```
Server:                              Client:
  Movement writes Velocity3d           Movement writes Velocity3d (same code)
  Rapier: gravity + collision          Rapier: gravity + collision (same)
  Rapier integrates → Transform        Rapier integrates → Transform (same)
                                       Predict layer: reconcile toward server snapshots
```

The predict layer (net/client/predict.lua) skips velocity→position integration when
Rapier is active (checks for absence of `RigidBodyDisabled3d`). It only buffers
velocity history and reconciles toward server snapshots.

## Shared Functions (`shared/movement.lua`)

- `compute_velocity(world, input, camera_yaw, speed)` → `{ x, y=0, z }`
- `compute_rotation(world, vx, vz)` → `Quat` or `nil`
- `is_grounded(world, entity, mv, world_time)` → `boolean` (raycast + jump cooldown)

## Notes

- Default speed: 6.0, jump force: 5.0
- Jump cooldown: 0.3s (prevents double-jump at launch)
- Ground ray distance: 1.0 (from entity origin downward)
- Grounded detection: `ReadRapierContext3d:cast_ray` (NOT velocity check)
- Uses `math.atan2` for computing target rotation angle
