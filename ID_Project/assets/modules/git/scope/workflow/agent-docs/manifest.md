---
depends_on: [git, git/scope, sidebar, sidebar/button]
conflicts_with: []
exposes: [git/scope/workflow]
---

# git/scope/workflow

Git workflow sidebar panel for in-game version control operations.

Provides commit, push, pull, PR creation, status viewing, commit log, and branch creation — all from within the game UI. Operates on the player's active scope worktree.

## Components

- Uses `git/scope/workflow` — panel mod component (patched by sidebar/button)
- Reads `git/scope` + `net_local` — to determine active scope and worktree
- Reads `HttpProxyClientResponse` — for PR creation callbacks

## Resources

- `GitWorkflowState` — `{ current_scope_key, status_lines, recent_log, feedback, ... }`

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | `added { "git/scope/workflow" }`: build panel UI, initial data load |
| First | GitWorkflowCreateBranch | Handle `git/scope:create_branch` events |
| Update | — | Process HTTP responses, periodic refresh (5s), feedback expiry, UI updates |

## Actions

| Button | Operation |
|--------|-----------|
| **Commit** | `git add -A && git commit -m "..."` in current worktree |
| **Push ↑** | `git push origin <branch>` |
| **Pull ↓** | `git pull origin <branch>` |
| **PR** | `POST /repos/{owner}/{repo}/pulls` via GitHub API (requires auth) |
| **Create** | `git branch <name>` + switch scope |

## Sidebar Integration

```lua
spawn({
    mod = { sidebar = {
        buttons = {
            git_workflow = {
                icon_text = "⚙",
                title = "Git",
                panel_mod = "git/scope/workflow",
                order = 11,
            },
        },
    }},
})
```

## Events

- `git/scope:create_branch` — `{ name = "branch-name" }` triggers branch creation programmatically
