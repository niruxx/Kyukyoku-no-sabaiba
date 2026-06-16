---
depends_on: [git/scope, net]
conflicts_with: []
exposes: []
---

# git/scope/net_filter

Network visibility filter for scope isolation.

Registers a `"git_scope"` target filter with the Net module's filter registry. When entities have `net_sync.target = "git_scope"`, their updates are only sent to clients in the same scope.

## How It Works

1. Watches entities with both `net_owner` and `git/scope` components
2. Builds a `client_id → scope_key` mapping in `GitScopeFilterState`
3. When Net's `should_send_to("git_scope", ...)` is called, compares client scopes

## Resources

- `GitScopeFilterState` — `{ client_scopes = { [client_id] = scope_key } }`

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | GitScopeFilterSync | Update client→scope mappings from net_owner + git/scope entities |

## Usage

```lua
-- On scoped entities, set target to "git_scope" so they're only
-- replicated to clients in the same scope:
entity:set({ net_sync = {
    Transform = { authority = "server", target = "git_scope" },
}})
```
