---
depends_on: [net]
conflicts_with: []
exposes: [net_transfer, _net_transfer_mirror, NetTransferRelay]
uses: [NetTrackingState]
---

# net/transfer

Cross-scope entity synchronization. Enables entities to exist across multiple game scope instances.

Two parts:
- **init.lua** — Per-scope writer (loaded as a mod in each game scope). Detects changed synced components on entities with `net_transfer` and patches `net_transfer.data`.
- **relay.lua** — Top-level relay (required once in server/main.lua at scope 0). Spawns mirrors in other scopes and relays data between them.

## Components

- `net_transfer` — Marker + data payload. `{ id?, data? }`
  - `id` — Stable identity for owned entities (e.g., player transfer ID)
  - `data` — Component snapshot dict, patched by the per-scope writer
- `_net_transfer_mirror` — Internal marker on relay-spawned mirrors. `{ source = source_eid }`
  - Prevents mirrors from being treated as sources (writer skips these)

## Resources (scope 0)

- `NetTransferRelay` — `{ listeners, source_to_mirrors, owned_index, primary }`
  - `listeners`: `scope_id → spawn_fn(entity_data)` — registered via `register_scope()`
  - `source_to_mirrors`: `source_eid → { [scope_id] = mirror_eid }` — non-owned mirror tracking
  - `owned_index`: `transfer_id → { [scope_id] = eid }` — owned entity index (keyed by stable transfer.id, not scope-local client_id)
  - `primary`: `transfer_id → scope_id` — which scope is authoritative for each transfer identity

## Systems

### Per-scope writer (init.lua)
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| PostUpdate | NetTransferWrite | NetSyncTrack | Collect changed synced components → patch `net_transfer.data` |

### Top-level relay (relay.lua)
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| PostUpdate | NetTransferRelayNonOwned | — | Non-owned entities: added → spawn mirrors, changed → patch mirrors, removed → despawn mirrors |
| PostUpdate | NetTransferRelayOwned | NetTransferRelayNonOwned | Owned entities: added → index + claim primary, changed → relay from primary to others, removed → cleanup index |

## API

```lua
local relay = require("modules/net/transfer/relay.lua")

-- Register a scope so the relay spawns mirrors into it
relay.register_scope(__SCOPE_ID__)
```

## Entity Types

### Non-owned (e.g., portal)
Entities without `net_owner`. The relay snapshots the source entity and spawns a mirror in every other registered scope. Changes to `net_transfer.data` are forwarded to all mirrors.

### Owned (e.g., player)
Entities with `net_owner`. Indexed by `(client_id, transfer_id)`. The `primary` scope is the authoritative source — changes from primary are relayed to the same entity in other scopes. Used for player presence across portal boundaries.
