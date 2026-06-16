---
depends_on: [git, git/scope, sidebar, sidebar/button]
conflicts_with: []
exposes: [git/scope/selector]
---

# git/scope/selector

Sidebar panel for branch selection with GitHub OAuth authentication.

Manages the full lifecycle: sign-in → device code → branch listing from GitHub API → scope switching / portal placement.

## Components

- Uses `git/scope/selector` — panel mod component (patched by sidebar/button)
- Reads `ScopeInstance` — to display active scopes with client counts
- Reads `git/scope` + `net_local` — to determine local player's current scope
- Reads `HttpProxyClientResponse` — for auth and API response processing

## Resources

- `GitScopeSelectorState` — `{ current_scope_key, remote_branches, remote_commits, ... }`
  - `current_scope_key` is derived from `NetInfo.scope_key` (e.g., `"lobby"` for initial game)
- Also uses `GitHubAuthState` (from `git/shared/auth.lua`) and `GitHubApiState` (from `git/shared/api.lua`)

## Portal Placement

When user clicks the portal button for a branch:
- `current_sk` = `state.current_scope_key` or `NetInfo.scope_key` (always non-nil; `"lobby"` for initial game)
- `target_sk` = the selected branch's scope_key (e.g., `"Hello-Rust2:portals"`)
- Patches `git/scope/selector` with `open_portal = { current_sk, target_sk }`
- Server creates portal entity with `git/scope/portal = { scope_a = current_sk, scope_b = target_sk }`

## Systems

### Client
| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | `added { "git/scope/selector" }`: build panel UI, register HTTP allowlist, fetch branches |
| Update | — | Process HTTP responses, poll auth token, reactivity-based re-render |

### Server
| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | `changed { "git/scope/selector" }`: handle `open_portal` (spawn portal entity) and `switch_scope` (launch game server) |

## Auth Flow

1. User clicks "Sign in with GitHub"
2. Device flow starts → user code displayed (e.g., `ABCD-1234`)
3. User enters code at `github.com/login/device`
4. Panel polls for token every 5 seconds
5. On success: fetches branches from GitHub API, displays list

## Sidebar Integration

```lua
spawn({
    mod = { sidebar = {
        buttons = {
            github = {
                icon_asset = "icons/github.png",
                title = "GitHub",
                panel_mod = "git/scope/selector",
                order = 3,
            },
        },
    }},
})
```
