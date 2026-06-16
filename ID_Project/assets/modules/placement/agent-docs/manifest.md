---
depends_on:
  - net
conflicts_with: []
exposes:
  components:
    - placement
  events: []
  systems:
    - Update
---

# Placement Mod

The `placement` mod provides a fully networked, cross-client synced entity placement system. It allows clients to spawn a "shadow entity" that automatically tracks the cursor via raycasting. Other connected clients will see the shadow entity moving in real-time. Once the user clicks to confirm, the entity seamlessly becomes a permanent server-authoritative entity without needing to despawn or replace it.

## How it works
1. **Spawn**: The client spawns a local entity with `placement = {}` and `net_sync = { Transform = { authority = "client" }, placement = { authority = "client" } }`. The net module detects the locally-added `net_sync` (entity not in the server-assigned id_map), auto-patches `net_predict = {}` and `net_local = true`, and sends SPAWN_REQUEST automatically.
2. **Server Approval**: The net server materializes the request as a *pending* entity (with `net_predict` and auto-stamped `net_owner = { client_id }` on it). The placement server reacts to `added { net_predict, placement }` and approves by removing `net_predict`. `NetPredictFinalize` then allocates the net_id and broadcasts the spawn to other clients.
3. **Raycast Sync**: The owner client's `Update` system queries `{ with = { "placement", "net_local", "Transform" } }`, uses `MeshRayCast` to update the entity's `Transform.translation`. On desktop the ray comes from the active camera's `forward` vector through the cursor; in VR it comes from the pointer-hand controller (`VrControllerState`). Because client owns the Transform during placement, this moves smoothly across the network for all observers.
4. **Confirmation**: On Left-Click (desktop) or the right trigger (VR), the owner client patches `placement = { confirmed = true }`. Because `placement` is client-auth, the standard `net_sync` UPDATE pipe carries the change to the server — no custom message.
5. **Finalization**: The server's `changed { placement }` system reads `.confirmed`, patches `placement = null` and `net_sync.placement = null`, and sets `net_sync.Transform.authority = "server"`. `NetSyncTrack` broadcasts the updated `net_sync`.
6. **Client Cleanup**: The client detects `changed { net_sync }` with `placement.confirmed` — if `net_sync.placement` is gone, removes the local `placement` component. All clients converge on the server-authoritative state.
7. **Cancellation**: On Right-Click / `Escape` (desktop) or the `B` button (VR), the owner client `despawn`s the placement entity. The existing client-initiated despawn flow sends `DESPAWN_REQUEST` to the server.

## Component: `placement`

State component for an entity in placement mode. Networked client-auth (only the owner can change it).

```lua
placement = {}                      -- placing (initial)
placement = { confirmed = true }    -- client requests finalize
```

## Setup & Trigger Example

To trigger a networked placement (such as drag-and-dropping a portal), just spawn locally with `net_sync` — the net module detects it's a fresh local entity and starts the prediction flow automatically:

```lua
spawn({
    -- 1. Base mesh and transform
    Mesh3d = "modules/git/scope/portal/assets/portal_frame.glb",
    Transform = { translation = { x = 0, y = 0, z = 0 } },

    -- 2. Marker for placement-mod approval
    placement = {},

    -- 3. Network authority: client owns the transform AND the placement state
    --    during placement. (Transform reverts to server-auth on confirm.)
    net_sync = {
        Transform = { authority = "client", reliable = false },
        placement = { authority = "client" },
    },

    -- 4. Attach the networked modules (placement-mod loads via net_mod)
    net_mod = {
        ["git/scope/portal"] = { ... },
        placement = {},
    },
})
```
