---
depends_on: [net_mod]
conflicts_with: []
exposes: [camera]
---

# camera

Base camera contract. Provides `camera` component with yaw/pitch/distance/height/offset. Client-authoritative, owner-targeted. Specialized by subtypes like `camera/third_person`.

## Components

- `camera` — `{ yaw, pitch, distance, height, offset }`. Authority: client. Target: owner.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | Server: override net_sync authority to client/owner. Client: set defaults, add Camera3d |

## Camera Entity Pattern

The camera entity IS the Camera3d — both `camera` (state) and `Camera3d` + `Transform` live on the same entity. This follows the established snippet pattern.

## Subtype Query

```lua
-- Match ALL camera subtypes
world:query({ with = { "camera" } })

-- Match only third-person cameras
world:query({ with = { "camera", "camera/third_person" } })
```
