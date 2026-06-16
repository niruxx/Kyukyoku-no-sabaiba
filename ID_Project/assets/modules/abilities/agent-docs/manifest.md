---
depends_on: [net_mod, input]
conflicts_with: []
exposes: [abilities, AbilityRegistry]
---

# abilities

Extensible ability system. Abilities register into the unified `bindings` component. Clients drive every projectile spawn via `net_predict`; the server validates against a registered ability and approves (by removing `net_predict`) or rejects (by despawning the pending entity). Prediction lifecycle (request / confirm / reject / timeout) is handled centrally by the `net` module.

## Components

- `abilities` — Marker component on the player entity.
- `projectile` — `{ ability, owner_id, lifetime, spawn_time }`. `ability` is set by the client at spawn; the server fills in the rest on approval and auto-despawns after `lifetime`.

## Resources

- `AbilityRegistry` (server) — `{ abilities = { name → { key, cooldown, last_used } } }`

## Events

| Event | Direction | Shape |
|-------|-----------|-------|
| `ability:register` | Any → abilities mod | `{ name, key, cooldown? }` |
| `ability:unregister` | Any → abilities mod | `{ name }` |

## Systems

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | — | — | Init `abilities` entities: install bindings + default fireball |
| PreUpdate | — | — | Tick `AbilityRegistry.elapsed_time` |
| Update | — | — | Dynamic registration via `ability:register` / `ability:unregister` events |
| Update | Ability | Movement | Client: spawn predicted projectile on ability input (with `net_predict`). Server: react to `added { net_predict, projectile }` — validate cooldown / binding, then approve (remove `net_predict`) or reject (despawn) |
| Update | — | Ability | Server: despawn projectiles past `lifetime` |

## Default Abilities

| Name | Key | Cooldown | Effect |
|------|-----|----------|--------|
| `fireball` | Q | 1.0s | Spawn a ball projectile in player's forward direction (speed=20, gravity=0.3, lifetime=3s) |

## Dynamic Registration

```lua
-- Register a new ability at runtime (from any script)
world:write_event("ability:register", {
    name = "dash",
    key = "KeyE",
    cooldown = 2.0,
})

-- Remove an ability
world:write_event("ability:unregister", { name = "dash" })
```

## Prediction Flow

1. Client presses ability key → spawns projectile locally with `net_sync` + `projectile = { ability = "fireball" }`. No explicit `net_predict` is needed — the net module auto-detects locally-added `net_sync` entities.
2. `net/client` (NetPredictTrack) auto-patches `net_local = true` and `net_predict = {}` on the entity, allocates a `predicted_eid`, and sends `SPAWN_REQUEST` to the server with the entity's net_sync-tracked components.
3. Server `net/server` spawns the entity in a pending state (with `net_predict` still attached).
4. `abilities/server` reacts to `added { net_predict, projectile }`, looks up the ability + cooldown:
   - Pass → patches canonical `owner_id` / `lifetime` / `spawn_time`, then removes `net_predict` (approves).
   - Fail → `despawn(entity)` (rejects).
5. `NetPredictFinalize` (PostUpdate) finalizes: allocates `net_id`, sends `SPAWN_CONFIRM` to predictor and broadcasts `SPAWN` to others. On rejection, sends `SPAWN_REJECT` and the predicting client despawns its local copy.
6. If `net_predict` is never removed within 5 s the server timeout fires, the entity is despawned, and `SPAWN_REJECT` is sent.
