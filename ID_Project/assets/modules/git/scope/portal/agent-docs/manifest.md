---
depends_on: [git/scope, net_mod, net, net/transfer, collision_trigger]
conflicts_with: []
exposes: [git/scope/portal, ScopeStencil]
---

# git/scope/portal

Portal behavior via `net_mod`. Manages scope server lifecycle, client game connections, `ScopeStencil` rendering, collision-based crossing detection, and scope switching.

Loaded as a `net_mod` entry on portal entities. The server launches target scope game servers (via `ensure_scope_server`), patches the portal config with ports and IDs, adds `collision_trigger` for crossing detection, and initiates authority switch + `SCOPE_SWITCH` on crossing. The client waits for the server-patched config (with ports), spawns a client game connection, manages stencil camera activation, and handles `SCOPE_SWITCH` to swap primary scope.

## Architecture

- **Asymmetric scopes**: `scope_a` can be `nil` (portal placed from lobby). `scope_b` is always required.
- **Server-only launch**: `ensure_scope_server` only spawns `game { mode = "server" }`. Each client spawns its own game connection independently.
- **Port syncing**: The server patches `scope_a.port` and `scope_b.port` into the portal config, synced to clients via `net_sync`.
- **Lobby identity**: The initial game uses `scope_key = "lobby"`, registered in `PortAllocator` and `ScopeInstances`.
- **Collision trigger**: Added as `net_mod` on placement confirmed (not at spawn time). Uses `Sensor3d` for non-blocking overlap detection.
- **Scope switching**: Uses `SCOPE_SWITCH` message (via `Net.register_handler`) instead of `portal_observer`.

## Components

- `git/scope/portal` — Portal config: `{ scope_a = { name, id, port }, scope_b = { name, id, port } }`
  - `scope_a` can be `nil` (lobby/current game)
  - `scope_b` is always set (target scope)
  - Ports and IDs are patched by server after placement confirmation
- `ScopeStencil` — Client rendering state: `{ scope_a, scope_b, stencil_ref, active }`
- Uses `collision_trigger` — generic collision detection (enter/exit events)
- Uses `net_transfer` — non-owned relay for cross-scope mirroring
- Uses `net_peer_switch` — authority transfer on portal crossing

## Resources (inherited via lineage)

- `PortAllocator` — Centralized port allocation: `{ next_port, scope_ports, alloc(scope_key), free(scope_key) }`
- `ScopeInstances` — Scope registry: `scope_key → { scope_id, port }`
- `CameraRegistry` — Camera entity lookup by scope_key (for portal camera config)
- `ScopeRenderLayers` — Render layer allocation per scope

## Systems

### Server
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | PortalPlacementConfirmed | PortalInit | `removed { "placement" }`: launch target scope server, patch config with ports/IDs, add `collision_trigger` to net_mod, establish peer connection |
| Update | PortalCrossing | CollisionTrigger | React to `collision_trigger.entered` on players: initiate `net_peer_switch` + send `SCOPE_SWITCH` to client |

### Client
| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | PortalMeshInit | — | `added { "git/scope/portal", "placement" }`: spawn portal mesh |
| First | PortalInit | — | `removed { "placement" }` + port guard: spawn client game, create ScopeStencil |
| Update | PortalCameraConfig | PortalActivation | `changed { "ScopeStencil" }`: configure target camera with stencil |
| Update | PortalCameraActivation | PortalCameraConfig | `changed { "git/scope" }` on local player: reconfigure own camera on crossing |
| — | SCOPE_SWITCH handler | — | `Net.register_handler`: receive scope switch, update `NetInfo.primary_scope_key`, deactivate stencil |

## Portal Entity Spawn

Created by `git/scope/selector` when user clicks the portal button:

```lua
spawn({
    net_owner = owner,
    net_sync = { Transform = { authority = "client", reliable = false } },
    net_mod = {
        placement = {},
        ["git/scope/portal"] = {
            scope_a = { name = "lobby" },
            scope_b = { name = "Hello-Rust2:feature-xyz" },
        },
    },
})
```

Note: `collision_trigger` is NOT included at spawn time. It is added by `PortalPlacementConfirmed` after placement is confirmed.

## Lifecycle Flow

```
SELECTOR (client)                  SERVER                           CLIENT (all)
─────────────────                  ──────                           ────────────
User clicks portal button
  → patch selector with
    open_portal = {
      current_sk, target_sk
    }
                              ───▶ Selector server spawns portal
                                   entity with placement + portal
                                   config (no ports yet)
                              ───▶ Net sync → client receives entity

Client places portal (placement)
  → confirm → placement removed
                              ───▶ PortalPlacementConfirmed:
                                   • ensure_scope_server(scope_b)
                                   • patch config with ports, IDs
                                   • add collision_trigger to net_mod
                                   • add net_sync + net_transfer
                                   • establish peer connection
                              ───▶ Net sync update → client
                                                                    PortalInit (removed + port guard):
                                                                    • spawn client game for target port
                                                                    • create ScopeStencil

Player walks into portal sensor
                              ───▶ PortalCrossing:
                                   • collision_trigger.entered
                                   • net_peer_switch → authority transfer
                                   • SCOPE_SWITCH → client
                                                                    SCOPE_SWITCH handler:
                                                                    • update primary_scope_key
                                                                    • deactivate stencil
```

## Crossing Flow (Authority Transfer)

```
Server A (source)              Server B (target)              Client
─────────────                  ─────────────                   ──────
Player enters portal sensor
PortalCrossing fires
  │
  ├─ net_peer_switch patched
  │   → PeerAuthoritySwitch:
  │     demote player to mirror
  │     send AUTHORITY_SWITCH ──▶ handle_authority_switch:
  │                                promote mirror → source
  │                                spawner creates full player
  │
  └─ SCOPE_SWITCH ──────────────────────────────────────────▶ Net.register_handler:
                                                               primary_scope_key = target
                                                               input routes to Server B
```
