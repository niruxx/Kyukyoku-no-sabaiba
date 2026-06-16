---
depends_on: []
conflicts_with: []
exposes: []
---

# git

Git plumbing library. Pure Lua, no ECS components or systems.

Provides thin wrappers around `io.popen("git ...")` for worktree management, diffing, cloning, and scope key parsing. Used by `git/scope` and other git-related mods.

## API

| Function | Description |
|----------|-------------|
| `Git.exec(cmd)` | Execute a shell command, return `success, output` |
| `Git.scope_key(repo, branch)` | Build scope key string `"repo:branch"` |
| `Git.parse_scope(scope_key)` | Parse scope key into `repo, branch` |
| `Git.diff_files(repo_root, base, target)` | List changed files between branches |
| `Git.ensure_worktree(repo_root, branch, worktree_path)` | Create worktree if missing. Three-step fallback: attach existing branch → `--force` (stale entries) → create new branch via `-b` |
| `Git.remove_worktree(repo_root, worktree_path)` | Remove a worktree |
| `Git.commit(worktree_path, message)` | Stage all + commit |
| `Git.push(worktree_path, branch)` | Push to origin |
| `Git.pull(worktree_path, branch)` | Pull from origin |
| `Git.status(worktree_path)` | `git status --short` |
| `Git.diff_summary(worktree_path)` | `git diff --stat` |
| `Git.log(worktree_path, count)` | Commit log as `{ hash, message }` list |
| `Git.list_branches(repo_root)` | All branches as `{ name, is_remote, is_current }` list |
| `Git.create_branch(repo_root, name, base)` | Create branch without switching |
| `Git.fetch(repo_root)` | Fetch from origin |
| `Git.clone(remote_url, target_path)` | Clone a repo |
| `Git.file_exists(path)` | Check if file exists |
| `Git.dir_exists(path)` | Check if directory exists |

## `git/shared/auth.lua` — GitHub OAuth Device Flow

Manages the GitHub Device Flow authentication lifecycle via HTTP proxy.

| Function | Description |
|----------|-------------|
| `auth.start_device_flow()` | Begin sign-in (requests device code) |
| `auth.poll_for_token()` | Poll GitHub for access token |
| `auth.handle_response(response)` | Process `HttpProxyClientResponse` entities |
| `auth.is_authenticated()` | Returns `true` if signed in |
| `auth.is_pending()` | Returns `true` during device flow |
| `auth.get_user_code()` | The code the user enters at github.com/login/device |
| `auth.get_username()` | GitHub username after auth |
| `auth.get_access_token()` | OAuth access token |
| `auth.logout()` | Clear auth state |

## `git/shared/api.lua` — GitHub REST API Wrapper

Async REST API calls via `queue_http_proxy_request`. All methods take `(auth, ...)` and a callback.

| Function | Description |
|----------|-------------|
| `api.list_branches(auth, owner, repo, cb)` | List branches → `cb(branches, err)` |
| `api.get_commits(auth, owner, repo, branch, count, cb)` | Commit history → `cb(commits, err)` |
| `api.create_branch(auth, owner, repo, name, sha, cb)` | Create branch via API |
| `api.create_pull_request(auth, owner, repo, title, head, base, cb)` | Open a PR |
| `api.get_branch_sha(auth, owner, repo, branch, cb)` | Get branch HEAD SHA |
| `api.handle_response(response)` | Process `HttpProxyClientResponse` entities |
