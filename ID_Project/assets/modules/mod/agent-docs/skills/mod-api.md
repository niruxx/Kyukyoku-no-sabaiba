---
trigger: model_decision
description: Mod loader API reference — ref counting, base chains, and component lifecycle
---

# Mod Loader API Reference

## Component: `mod`

The `mod` component is the only interface to the mod loader. Set it on an entity to load scripts.

### Shapes

```lua
-- Single mod (path: modules/my_mod/init.lua)
entity:set({ mod = { my_mod = { key = "value" } } })

-- Explicit script path
entity:set({ mod = { my_mod = {}, script = "custom/path.lua" } })

-- Multiple mods (array)
entity:set({ mod = {
    { controller = { camera = "camera/third_person" } },
    { animation = { clip = "Idle" } },
} })

-- Instanced (new Lua state_id, isolated resources)
entity:set({ mod = { net = {}, instanced = true, script = "modules/net/server/init.lua" } })
```

### Adding a mod to an existing entity

```lua
entity:patch({ mod = { new_mod = { config } } })
```

### Removing a mod

```lua
entity:patch({ mod = { old_mod = null } })
```

The mod loader detects the change, unloads the script (decrements ref count), and removes the mod-name component.

### Removing ALL mods

```lua
entity:remove("mod")
```

## Resource: `ModLoaderState`

```lua
local state = define_resource("ModLoaderState")

state.ref_counts   -- { script_path → { count = N } }
state.entity_mods  -- { entity_id → { mod_name → { path } } }
state.prev_mod     -- { entity_id → previous mod value (for diffing) }
```

## Lifecycle

1. **`added { "mod" }`** → Parse entries, resolve paths, `require_async` each, increment ref counts, patch mod-name components
2. **`changed { "mod" }`** → Diff old vs new, load new entries, unload removed entries
3. **`removed { "mod" }`** → Unload all, decrement refs, stop scripts at 0

## System Label

`"ModLoader"` — runs in `First` schedule. Use `before = { "ModLoader" }` to run systems that must prepare data before the mod loader processes it.
