---
depends_on: []
conflicts_with: []
exposes: [mod, ModLoaderState]
---

# mod

Ref-counted mod loader. Watches for `mod` component on entities, loads/unloads Lua scripts, and manages lifecycle via ref counting.

## Components

- `mod` — Declares which mods to load on an entity. Supports single-mod, multi-mod (array), and explicit script paths.

## Resources

- `ModLoaderState` — Ref counts, entity-to-mod tracking, previous mod state for diffing.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | ModLoader | Parse mod entries, load/unload scripts, manage ref counts |

## API

The mod loader is infrastructure — game mods don't call it directly. They interact by setting the `mod` component:

```lua
-- Load a mod
entity:set({ mod = { my_mod = { config } } })

-- Unload a mod
entity:patch({ mod = { my_mod = null } })
```
