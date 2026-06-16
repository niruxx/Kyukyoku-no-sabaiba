---
depends_on: []
conflicts_with: []
exposes: [animation/sprite]
---

# animation/sprite

2D sprite animation component. Handles 2D spritesheet animation by dynamically adjusting a child entity's `Sprite.rect` property to advance through frames defined in `clips`.

## Components

- `animation/sprite` — Animation configuration and state. Contains:
  - `image` (string): Path to the spritesheet.
  - `tile_size` (table): `{x, y}` size of each frame in pixels.
  - `columns` / `rows` (int): Spritesheet grid dimensions.
  - `clips` (table): Map of states (e.g. `idle_down`) to `{frames, fps}`.
  - `state` (string): Current animation state.
  - `speed` (float): Speed multiplier.
  - `facing` (string): Derived direction (up/down/left/right).

## Systems

### Shared
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "animation/sprite" }`: Configure default `state`, `facing`, and `net_sync` |
| Update | SpriteAnimationState | Movement2d | Derive state (e.g., `walk_down` vs `idle_right`) from `Velocity2d.linvel` |

### Client
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | - | - | `added { "animation/sprite" }`: Spawn child entity with `Sprite` mesh and initial rect |
| Update | SpriteAnimation | Animation | Advance frame index using dt and `fps`, update child `Sprite.rect` |
