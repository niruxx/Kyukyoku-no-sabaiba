---
depends_on: [git]
conflicts_with: []
exposes: [git/scope, GitScopeState]
---

# git/scope

Scope lifecycle orchestrator. Server-only.

Watches `game` entities (Rust-spawned, reflected) and manages git worktree creation/teardown, changed-file diffing, and asset path resolver registration. When a scope becomes active, this mod ensures a worktree exists, diffs the branch against base to determine which files differ, and registers a resolver that redirects those changed files to the worktree path.

## Components

- `git/scope` — `{ scope_key, scope_id }`. Patched onto player entities by the scoped server instance.

## Resources (instance-scoped)

- `GitScopeState` — Tracks all scope lifecycle data:
  - `worktrees`: scope_key → `{ path, repo, branch, changed_files, last_diff_time }`
  - `entity_to_scope`: entity bits → scope_key (for removed lookups)
  - `resolver_registered`: boolean

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | GitScopeInit | `added { "game" }`: ensure worktree, diff changed files, cache entity→scope |
| First | GitScopeChanged | `changed { "game" }`: re-diff changed_files (throttled 10s) |
| First | GitScopeRemoved | `removed { "game" }`: remove worktree via entity_to_scope cache |

## Resolver

Registers `add_asset_path_resolver("git/scope", 0, fn)` on first load. The resolver maps `(scope_id, path)` → worktree path for files that differ between the scope's branch and the base branch. Unchanged files fall through to `assets/`.
