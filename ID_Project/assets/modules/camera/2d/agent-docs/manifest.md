---
depends_on: []
conflicts_with: []
exposes: [camera/2d]
---

# camera/2d

Client-side top-down 2D follow camera. Follows an entity in the XY plane and supports zooming via mouse scroll. 

## Components

- `camera/2d` — Camera configuration and state. Contains:
  - `zoom` (float): Current zoom level.
  - `min_zoom` (float): Minimum allowed zoom (default 0.25).
  - `max_zoom` (float): Maximum allowed zoom (default 4.0).
  - `z` (float): Z-index offset for the camera (default 1000.0).
  - `camera_entity` (int): Child entity ID holding the actual camera.

## Systems

### Server
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "camera/2d" }`: Set `net_sync` authority to `client` for the owner |

### Client
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "camera/2d" }`: Bind inputs, set default config, spawn child `Camera2d` entity |
| Update | Camera2dInput | Input | Adjust `zoom` state using mouse scroll input |
| Update | Camera2dPosition | MovementInterpolation, Movement2d | Follow the parent entity's `Transform` in the XY plane, apply zoom via scale |
