depends_on: [net_mod]
exposes: [input, input_group]

# input

Binding registry + hardware polling + sync group output. Consumer mods patch their bindings onto the `input` component. The input mod polls keyboard/mouse, writes pressed state, and auto-generates output components with centralized change detection.

## Components

- `input` — Binding registry + pressed state. Consumer mods patch nested groups (e.g. `input.movement.forward = { key = "KeyW", mode = "game" }`). Input mod writes `pressed`, `dx`, `dy` fields. **Not net-synced.**
- `input_<group>` — Auto-generated output components (e.g. `input_movement = { forward = true }`). Written by input mod with change detection. Net-synced by each consumer's server.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | Init: set default input_mode, confine cursor |
| Update | Input | Poll keyboard/mouse, process bindings, write sync group outputs |

## Binding Registration

```lua
-- Register key bindings in a sync group (output → input_movement)
entity:patch({ input = { movement = {
    forward = { key = "KeyW", mode = "game" },
}}})

-- Register mouse bindings (local only, no output component)
entity:patch({ input = { camera = {
    look = { type = "mouse_motion", mode = "game" },
}}})

-- Register top-level action (local only)
entity:patch({ input = { open_menu = { key = "Escape", mode = "always" } } })

-- De-register
entity:patch({ input = { movement = { forward = null } } })

-- Register with net_sync client authority
entity:patch({ input = { movement = { forward = { key = "KeyW", mode = "game" } } }, net_sync = { input_movement = { authority = "client" } } })
```

## Binding Types

Each action is a single binding table, or an array of binding tables (multi-binding),
so one action can expose keyboard/mouse + VR alternatives at once:

```lua
-- Single binding
forward = { key = "KeyW", mode = "game" }

-- Multi-binding (desktop + VR)
forward = { { key = "KeyW", mode = "game" }, { vr = "left_stick_up", mode = "game" } }
```

The `input_<group>` output value is shaped by the action's kind:

| Kind | Sources | Output |
|------|---------|--------|
| digital | keys, mouse buttons, VR buttons | **boolean** — use `if input.action then` |
| analog | VR sticks, VR `*_value` (trigger/grip pressure) | **number** `0.0`–`1.0` |
| delta | `mouse_motion`, `mouse_scroll` | `{ dx, dy }` table |

A multi-binding outputs a **number** if any of its bindings is analog (max value),
otherwise a **boolean** (any binding pressed). For edge detection, read the local
`input` component, which keeps per-action `{ pressed, just_pressed, value }`.

### Keyboard / mouse

| Binding | Example | Notes |
|---------|---------|-------|
| `key`   | `{ key = "KeyW" }`   | Bevy `KeyCode` name (`KeyW`, `Space`, `Escape`, …) |
| `mouse` | `{ mouse = "Left" }` | Mouse button: `Left`, `Right`, `Middle` |
| `type = "mouse_motion"` | `{ type = "mouse_motion" }` | Outputs `{ dx, dy }` delta (local only, no output component) |
| `type = "mouse_scroll"` | `{ type = "mouse_scroll" }` | Outputs `{ dx, dy }` scroll (local only, no output component) |

### VR (`vr = "<name>"`)

| Category | Names | Output |
|----------|-------|--------|
| Buttons (event-driven) | `a`, `b`, `x`, `y`, `right_trigger`, `left_trigger`, `right_grip`, `left_grip` | boolean (digital); `just_pressed` on local `input` |
| Stick directions (analog) | `left_stick_up` / `_down` / `_left` / `_right`, `right_stick_up` / `_down` / `_left` / `_right` | `0.0`–`1.0` per direction |
| Raw analog | `right_trigger_value`, `left_trigger_value`, `right_grip_value`, `left_grip_value` | `0.0`–`1.0` |

VR button state comes from `VrButtonInput` events; axis/analog state from the
`VrButtonState` resource. Both are absent on desktop, so VR bindings read as inactive
(`false` / `0.0`) there — letting an action carry both desktop and VR bindings with no
extra branching.

## Modes

- `mode = "game"` — active when `input_mode == "game"`, suppressed in UI mode
- `mode = "always"` — always active regardless of input_mode
- `mode = "ui"` — only active when `input_mode == "ui"`

## Conflict Detection

Warns when two actions bind the same key:
```
[INPUT] WARNING: Key 'KeyQ' bound to both 'abilities.fireball' and 'movement.forward'
```

## Notes

- `input` is client-only — never net-synced
- Each consumer's server sets `net_sync` authority for its output component
- Server registers the same bindings for validation
- Change detection is centralized — input mod only writes output when state actually changes
