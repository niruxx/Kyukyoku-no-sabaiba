---
depends_on: []
conflicts_with: []
exposes: [net_sync, net_owner, net_local, net_predict, net_sync_Transform, net_client, synced_state, observer, scope_key, net_peer_server, net_peer_connect, net_peer_share, net_peer_mirror, net_peer_switch, NetInfo, NetServerState, NetClientState, NetPeerState]
---

# net

Network transport module providing server/client synchronization, ownership routing, observer clients, client-side prediction, and server-to-server peer federation.

Loaded as an instanced module (`instanced = true`) to create isolated Lua state scopes for server, client, and observer clients. Manages entity lifecycle (spawn/update/despawn), authority-based delta synchronization, ownership propagation, reparenting detection, server-to-server mirrors, peer authority handoff, and the **predict → request → approve / reject** lifecycle for client-initiated spawns.

## Components

- `net_sync` — Per-component sync configuration (authority, target, reliable).
- `net_owner` — Entity ownership (`{ client_id = N }`).
- `net_local` — Auto-set marker on entities owned by *this* client. Mods query `{ with = { "net_local" } }` to find the local player or local predicted entities.
- `net_predict` — Marker for the prediction flow.
  - **Client:** auto-patched onto entities the client spawns locally with `net_sync` (i.e. `added { net_sync }` for entities not in the server's id_map). Mods typically don't write this themselves.
  - **Server:** auto-attached as `{ client_id, predicted_eid, requested = <client's component dict> }` when a `SPAWN_REQUEST` is materialized into a pending entity. **The client's components are NOT applied to the server entity** — they live as a read-only payload inside `net_predict.requested`. Mods react to `added { net_predict }`, inspect `requested`, validate, and `entity:set(...)` the components they vouch for, then `entity:remove("net_predict")` to approve (or `despawn(entity)` to reject).
- `net_sync_<component>` — Shadow components for intercept/interpolation.
- `net_client` — Server-side connection entity spawned after client id acknowledgement: `{ client_id, observer, synced_state? }`. Player spawners and scope systems consume this instead of reading raw transport state.
- `net_peer_server` — Starts the peer Renet server for this scope: `{ name, port, game_port, scope_key }`. Peer ports are separate from client game ports.
- `net_peer_connect` — Starts an outbound peer client connection: `{ name, port, server_addr?, scope_key }`.
- `net_peer_share` — Marks an entity as a peer-federated source entity: `{ stable_id }`. The peer layer sends initial spawn, changed synced components, and despawn messages for it.
- `net_peer_mirror` — Marks a local mirror of a source entity from another scope: `{ stable_id, source_peer, was_source? }`. Mirror entities do not keep `net_owner`; server gameplay systems should skip them when applying local authority.
- `net_peer_switch` — One-frame authority handoff request patched onto source entities, usually by portal crossing: `{ target_scope }`. `PeerAuthoritySwitch` sends the handoff and demotes the source into a mirror.

## Resources (instance-scoped)

- `NetInfo` — Side resolution (`{ side, net_entity_id, name, scope_key, observer? }`). `scope_key` is always set (e.g., `"lobby"` for the initial game, `"Hello-Rust2:portals"` for scoped games). Observer clients set `observer = true`; portal clients may also patch `primary_scope_key` while switching scopes.
- `NetServerState` — `{ next_net_id, id_map, tracked, clients, all_synced, synced_dirty, pending_spawns, pending_predicts, elapsed_time, ... }`. `clients[client_id]` includes `{ transport_id, ready, observer, owned_net_ids = {} }`; `pending_predicts` is keyed by server entity_id → `{ client_id, predicted_eid, parent_net_id, spawn_time }`.
- `NetClientState` — `{ id_map, tracked, pending_spawns, next_predicted, predicted, predicted_by_eid, elapsed_time, observer, ... }`. `predicted` is keyed by `predicted_eid → { entity_id, spawn_time }`; `predicted_by_eid` is the reverse map (defends against duplicate prediction).
- `NetPeerState` — Peer federation state: `{ server_name, scope_key, game_port, inbound_peers, outbound_peers, mirror_entities, source_entities, ... }`. `source_entities` is keyed by stable id; `mirror_entities` maps stable id → local mirror entity id.

## Client / Server Instancing

Spawn a `net` component to start a client or server instance:

```lua
spawn({ net = { name = "lobby_client", mode = "client", port = 5000, scope_key = "lobby" }, ScopeWorld = "All" })
spawn({ net = { name = "branch_observer", mode = "client", port = 5001, scope_key = "Hello-Rust2:branch", observer = true }, ScopeWorld = "All" })
```

- `scope_key` identifies the isolated game scope. Net copies it into `NetInfo.scope_key` on both server and client instances.
- `observer = true` creates a client connection that receives replicated entities but is marked as an observer in the server's `net_client` entity. Player spawners skip observers unless `synced_state` is present.
- `synced_state` is a field on `net_client`, not a standalone component. The peer layer sets it during authority handoff with the mirrored synced state; player spawners merge that state when creating the promoted local player.

## Events

| Direction | Event | Shape | Purpose |
|-----------|-------|-------|---------|
| Mod → net/client | `net:send` | `{ msg_type, payload }` | Forward a custom message to the server. Drained by `NetSend`. |
| Mod → net/server | `net:send_to_client` | `{ client_id, msg }` | Send a targeted message to a specific client. Drained by `NetServerSendToClient`. |
| net/server → mod | `net:receive` | `{ msg_type, payload, client_id }` | Generic event fired for every non-built-in inbound message (with sender's `client_id` injected). |
| net/server → mod | `net:<msg_type>` | message body | Typed alias for the same dispatch. |
| net/server → client | `SCOPE_SWITCH` | `{ target_scope_key, target_port }` | Sent when a player crosses a portal. Client handlers registered via `Net.register_handler`. |

## Peer Protocol

`modules/net/peer` runs an independent Renet server/client pair for server-to-server federation. It does not reuse the normal `net/server` transport.

| Message | Shape | Purpose |
|---------|-------|---------|
| `peer_hello` | `{ scope_key, game_port }` | Outbound peer introduces its scope. |
| `peer_welcome` | `{ scope_key, game_port }` | Inbound peer acknowledges the connection. |
| `entity_spawn` | `{ stable_id, source_scope_key, components }` | Source scope creates a mirror in peers. |
| `entity_update` | `{ stable_id, components }` | Source scope sends changed synced components. |
| `entity_despawn` | `{ stable_id }` | Source scope removes mirrors in peers. |
| `auth_switch` | `{ stable_id, client_id, source_scope_key }` | Old source tells a target scope to take authority. |
| `auth_ack` | `{ stable_id }` | Reserved acknowledgement message; currently only logged if received. |

Peer mirrors preserve `net_sync`, `net_mod`, and synced component state so the receiving server can replicate them to its own clients. Mirrors remove `net_owner` and add `net_peer_mirror`; if a mirrored physics entity has `RigidBody3d`, the peer layer makes it kinematic so remote Transform sync is authoritative.

## Registries

- `Net.register_filter(name, fn)` — Custom target filters (e.g. "team", "nearby").
- `Net.register_handler(msg_type, fn)` — Custom message handlers. If a handler is registered for a message type, `Net.dispatch` calls it directly instead of writing the `net:<msg_type>` event.

## Systems

### Server
| Schedule | Label | Purpose |
|----------|-------|---------|
| First | NetServerInit | Initialize renet on `added { "net" }`. |
| First | NetServerInbound | Receive client id acknowledgements, observer flags, custom messages, spawn/despawn requests; for SPAWN_REQUEST spawn a *pending* entity with `net_predict = { client_id, predicted_eid, requested }` and register it in `state.pending_predicts`. Fires `net:receive` + `net:<msg_type>` for custom messages. |
| First | NetSyncTrack | Track sync changes, reparenting, and ownership. Skips entities with `net_predict` (handled by NetPredictFinalize instead). |
| PreUpdate | NetServerTime | Tick `state.elapsed_time` (drives predict timeout). |
| PostUpdate | NetPredictFinalize | Sweep `state.pending_predicts`: entity gone → SPAWN_REJECT; `net_predict` removed → allocate net_id, install tracking, SPAWN_CONFIRM to predictor, broadcast SPAWN to others (predictor excluded); >5 s with marker → despawn. |
| PostUpdate | NetServerOutbound | Send delta updates. |
| PostUpdate | NetServerSendToClient | Drain `net:send_to_client` events — send targeted messages to specific clients. Used by portal crossing to deliver `SCOPE_SWITCH`. |

### Client
| Schedule | Label | Purpose |
|----------|-------|---------|
| First | NetClientInit | Initialize renet on `added { "net" }`. |
| First | NetClientInbound | Handle SPAWN / UPDATE / DESPAWN / SPAWN_CONFIRM / SPAWN_REJECT. On CONFIRM: map net_id → local entity, install `state.tracked`, remove `net_predict`. |
| First | NetLocalMarker | Patch/clear `net_local` on `added/changed { net_owner }`. |
| First | NetPredictTrack | Detect `added { net_sync }` for entities not in `id_map` → auto-patch `net_local` + `net_predict`, allocate `predicted_eid`, send SPAWN_REQUEST. |
| PreUpdate | NetClientTime | Tick `state.elapsed_time`. |
| Update | NetPredictTick | Buffer velocity history for replay. Only integrates velocity → position when **Rapier is disabled** (`RigidBodyDisabled3d`); when Rapier is active, it handles integration with collision. |
| Update | NetPredictReconcile | On new server snapshot: seed position on first snapshot, then replay buffered velocities from last ~RTT and blend toward result (`CORRECT_FACTOR = 0.5`). |
| PostUpdate | NetClientOutbound | Send client-authoritative updates. |
| PostUpdate | NetSend | Drain `net:send` events → forward to server. |
| Last | NetPredictTimeout | Despawn predicted entities older than 5 s; clear `state.predicted` / `state.predicted_by_eid`. |

### Peer
| Schedule | Label | Purpose |
|----------|-------|---------|
| First | PeerServerInit | Initialize a peer Renet server from `net_peer_server`. |
| First | PeerClientInit | Initialize outbound peer clients from `net_peer_connect`. |
| First | PeerServerInbound | Handle inbound peer connect/disconnect, hello/welcome, entity mirror messages, and authority switches. |
| First | PeerClientInbound | Handle outbound connection lifecycle and peer messages from servers this scope connected to. |
| PostUpdate | PeerOutbound | Track `net_peer_share` sources, send initial spawns when peers connect, send changed synced components, and broadcast despawns. |
| PostUpdate | PeerAuthoritySwitch | React to `added { "net_peer_switch" }`, send `auth_switch`, demote the local source into `net_peer_mirror`, and clear stale movement/velocity. |

## Peer Authority Flow

```
SOURCE SCOPE                                      TARGET SCOPE
──────────────────────────────────────────────    ─────────────────────────────────────────
player has net_owner + net_peer_share
portal patches net_peer_switch = { target_scope }
    │
    ├─ PeerAuthoritySwitch:
    │     send auth_switch(stable_id, client_id)
    │     remove net_owner
    │     remove net_peer_switch
    │     patch net_peer_mirror { was_source = true }
    │
    └────────────────────────────────────────▶    handle_authority_switch:
                                                   find mirror by stable_id
                                                   if mirror.was_source:
                                                     remove net_peer_mirror
                                                     patch net_owner
                                                   else:
                                                     snapshot synced mirror state
                                                     patch net_client.synced_state
                                                     despawn mirror
                                                     player spawner creates full player
```

Use `NetPeerState.is_connected_to(scope_key)` when a mod needs to know whether a peer connection for a scope is ready.

## Prediction Flow

```
CLIENT                                              SERVER
─────────────────────────────────────────────────   ───────────────────────────────────────────────
spawn({ ..., net_sync = {...} })                    (waits)
    │
    ├─ NetPredictTrack:
    │     net_local = true (patch)
    │     net_predict = {} (patch)
    │     predicted_eid = state.next_predicted--
    │     state.predicted[predicted_eid] = ...
    │     state.predicted_by_eid[eid] = predicted_eid
    │
    └─ SPAWN_REQUEST ──────────────────────────▶    NetServerInbound:
                                                      spawn(components + net_predict = {
                                                          client_id, predicted_eid })
                                                      pending_predicts[eid] = {...}
                                                          │
                                                          ▼
                                                    Game mods react to added {net_predict, …}:
                                                      • inspect / mutate the entity
                                                      • entity:remove("net_predict")   → APPROVE
                                                      • despawn(entity)                → REJECT
                                                          │
                                                          ▼
                                                    NetPredictFinalize (PostUpdate):
                                                      • approved → allocate net_id,
                                                        SPAWN_CONFIRM → predictor,
                                                        broadcast SPAWN → others
                                                      • despawned → SPAWN_REJECT
                                                      • >5 s with marker → despawn (next
                                                        tick rejects)
                                                          │
SPAWN_CONFIRM ◀───────────────────────────────────────────┤
    │                                                      │
    ├─ Net.map(net_id, entity_id)                          │
    ├─ state.tracked[net_id] = { sync_config = … }         │
    └─ entity:remove("net_predict")                        │
                                                           │
SPAWN_REJECT  ◀───────────────────────────────────────────┘
    └─ despawn(entity)
```

## Triggering Prediction

User mods don't manage prediction state. Just spawn locally with `net_sync` and the net module handles the rest:

```lua
spawn({
    Transform = ...,
    Mesh3d = ...,
    placement = {},  -- marker that placement/server reacts to
    net_sync = {
        Transform = { authority = "client", reliable = false },
    },
    net_mod = { placement = {} },
})
```

Approval is server-side. The request lives inside `net_predict.requested` — the mod selects which fields it trusts:

```lua
register_system("Update", function(world)
    local entities = world:query({ added = { "net_predict" } })
    for _, entity in ipairs(entities) do
        local pred = entity:get("net_predict") or {}
        local req = pred.requested or {}
        if not req.placement then goto continue end  -- not our request type

        entity:set({
            placement = {},
            net_sync = {                           -- server controls authority
                Transform = { authority = "client", reliable = false },
                placement = { authority = "client" },
            },
            Transform = req.Transform,             -- visual data: copy verbatim
            Mesh3d    = req.Mesh3d,
            net_mod   = req.net_mod,
        })
        entity:remove("net_predict")              -- approve
        ::continue::
    end
end)
```

## Tests

Run-as-script tests (`cargo run -p hello -- --script <path>`):

- [tests/test_both.lua](../tests/test_both.lua) — Shared module logic (id_map, filters, handlers, pending queue).
- [tests/test_authority.lua](../tests/test_authority.lua) — Authority / target / channel-split edge cases.
- [tests/test_target_filtering.lua](../tests/test_target_filtering.lua) — `net_mod` per-entry target filtering for spawn messages.
- [tests/test_prediction.lua](../tests/test_prediction.lua) — `Tracking.collect_predict_components` and client/server prediction state lifecycle (allocate, confirm, reject, timeout, exclude).

Peer behavior is currently covered by integration with scope/portal/player modules rather than a dedicated `net/tests/test_peer.lua` script.
