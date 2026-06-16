---
depends_on: [mod, net]
conflicts_with: []
exposes: [net_mod]
---

# net_mod

Network mod orchestrator. Translates `net_mod` component into `mod` + `net_sync` components with side-resolved script paths.

Reads `NetInfo.side` from the instance-chain scoped resource (set by the net server/client module) and builds:
- `mod` entries with `script = "modules/{name}/{side}/init.lua"`
- `net_sync` entries with default `{ authority = "server" }` (unless overridden)

## Components

- `net_mod` — Declares which mods to load and sync. Shape mirrors `mod` but adds networking.

## Systems

| Schedule | Label | Before | Purpose |
|----------|-------|--------|---------|
| First | NetModLoader | ModLoader | Translate net_mod → mod + net_sync |

## Usage

```lua
-- Simple: load "controller" mod with default server authority sync
entity:set({ net_mod = { ["controller"] = { camera = "camera/third_person" } } })

-- Disable sync for a specific mod
entity:set({ net_mod = {
    { ["controller"] = {} },
    { ["animation"] = {}, net_sync = false },
} })

-- Custom authority
entity:set({ net_mod = {
    { ["camera"] = {}, net_sync = { authority = "client", target = "owner" } },
} })
```
