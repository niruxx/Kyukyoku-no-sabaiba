---
depends_on: [camera]
conflicts_with: [camera/first_person]
exposes: [camera/third_person]
---

# camera/third_person

Third-person orbit camera. Extends camera base with mouse look and orbit positioning. Uses `math.cos`/`math.sin` for orbit calculation (established project pattern).

## Components

- `camera/third_person` — Marker component (added by mod loader). Used in queries to identify this camera subtype.
- `camera` — Inherited from base. `{ yaw, pitch, distance, height, offset }`.

## Systems

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| Update | Camera | Input | Mouse delta → yaw/pitch, scroll → distance |
| Update | CameraPosition | Camera | Compute orbit position, set Transform via `with_translation` + `looking_at` |

## Notes

- Pitch is clamped to [-1.2, 0.2] to prevent camera flipping
- Distance is clamped to [2.0, 20.0]
- Mouse sensitivity: 0.003 radians per pixel
- Scroll sensitivity: 0.5 units per scroll tick
