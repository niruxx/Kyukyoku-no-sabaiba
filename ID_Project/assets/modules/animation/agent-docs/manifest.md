---
depends_on: [net_mod, movement]
conflicts_with: []
exposes: [animation, AnimationCache]
---

# animation

Animation state machine + model loader. Server determines animation state from `Velocity3d`, clients load models and play animations. Supports per-player models, shared `AnimationGraph` caching, speed-adjusted playback, and runtime clip updates.

## Components

- `animation` — Config + state. `{ model, clips, state, speed, model_entity_id }`. Authority: server.
  - `model` — Model path prefix (e.g. `"Conflux/Placeholder-Character"`)
  - `clips` — State→suffix map (e.g. `{ idle = "-Idle.glb", walk = "-Walk.glb" }`)
  - `state` — Current animation state: `"idle"`, `"walk"`, `"jump"`, `"fall"`, or custom
  - `speed` — Playback speed multiplier (walk scales with movement speed)

## Resources

- `AnimationCache` — `{ graphs = {} }` keyed by model prefix. Players with the same model share one `AnimationGraph` asset.

## Systems

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | — | — | Init: load model, build/cache AnimationGraph, spawn SceneRoot child |
| First | — | — | Clip updates: extend graph when new clips are patched at runtime |
| Update | Animation | Movement | Server: state machine. Client: play animation + adjust speed |

## Runtime Clip Updates

```lua
-- Add a new animation clip (e.g. ability grants attack anim)
entity:patch({ animation = { clips = { attack = "-Attack.glb" } } })
```

The client detects the change and extends the AnimationGraph with the new clip.

## Animation Speed

Walk animation speed scales with movement speed: `speed = horiz_speed / BASE_WALK_SPEED` (clamped to [0.3, 2.0]).

## Notes

- Each player can have a different model (set at spawn time in animation config)
- AnimationGraph is cached by model prefix — multiple players with the same model share memory
- Fall uses the Jump clip (configurable via clips table: `fall = "-Jump.glb"`)
