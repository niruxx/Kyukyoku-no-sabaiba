---
depends_on: []
conflicts_with: []
exposes: [movement/2d]
---

# movement/2d

Provides 2D Top-Down movement by translating input into a `Velocity2d` update on the server and `Transform` prediction on the client. Applies linear velocity mapped to WASD movement using `modules/movement/shared/movement.lua`.

## Components

- `movement/2d` — Movement configuration and state. Contains:
  - `speed` (float): Speed scalar.

## Systems

### Server
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "movement/2d" }`: Set `net_sync` for client authority over `input_movement`, register input bindings |
| Update | Movement | Input | Apply desired 2D linear velocity to `Velocity2d.linvel` based on `input_movement` |

### Client
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "movement/2d" }`: Register input bindings, duplicate `Transform` into `net_sync_Transform` |
| Update | Movement | Input | Client-side prediction: instantly adjust local `Transform` based on input |
| Update | MovementInterpolation | Movement | Lerp client prediction towards server-authoritative `net_sync_Transform` |
