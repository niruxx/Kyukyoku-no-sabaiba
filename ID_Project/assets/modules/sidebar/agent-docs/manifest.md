---
depends_on: [input]
conflicts_with: []
exposes: [sidebar]
---

# sidebar

Persistent left-edge UI container with an icon bar and a panel area. Spawned as a client-side mod on a single entity. Manages button reconciliation, Escape-key toggle, and input mode switching.

## Components

- `sidebar` — Config + runtime state. Authority: client only.
  - Config fields:
    - `buttons` — optional map of `sidebar/button` configs keyed by name. Each entry is spawned as a child `sidebar/button` entity. Sorted by `order` field (ascending), falling back to key name.
  - Set after init (do not write manually):
    - `icon_bar_id` — entity ID of the absolutely-positioned icon bar `Node`
    - `container_id` — entity ID of the outer container `Node` (same as the sidebar entity itself)

## Resources

- `SidebarState` — `{ visible, container_id, icon_bar_id, sidebar_entity_id, last_escape_time, sidebars_by_id }`. Persists hot-reload.

## Systems

| Schedule | Label | After | Purpose |
|----------|-------|-------|---------|
| First | — | — | `added { "sidebar" }`: spawn icon bar, patch container Node, register Escape binding, reconcile buttons |
| First | — | — | `changed { "sidebar" }`: diff `buttons` map and spawn/despawn/patch child button entities |
| Update | SidebarEscape | Input | Read `input_sidebar.open_menu`; close most-recent panel, or toggle sidebar visibility |

## Architecture

**Hierarchy-based discovery**: Button mods are child entities of the sidebar entity. They read the parent's `sidebar` component to find `icon_bar_id`, then self-manage their icon and panel lifecycle.

The sidebar entity doubles as the outer container. The icon bar is pinned via `position_type = "Absolute"` so sibling order in the Children list cannot displace it. Panels spawned by buttons are direct children of the sidebar entity (siblings to the icon bar), inset via `padding.left = ICON_BAR_WIDTH`.

Each button mod patches `sidebar/button` on itself with `{ icon_entity_id, panel_entity_id, opened_at }` so the sidebar can track open panels for Escape handling.

```
sidebar entity  (mod = { sidebar = { buttons = { ... } } })
├── icon_bar   (Absolute, left=0)
├── button child entity  (mod = { ["sidebar/button"] = { panel_mod = "sidebar/profiler/panel" } })
├── button child entity  (mod = { ["sidebar/button"] = { panel_mod = "sidebar/file_browser/panel" } })
└── [on click] panel entity  (mod = { ["sidebar/profiler/panel"] = {} })
```

## Input Integration

Registers `sidebar.open_menu = { key = "Escape", mode = "always" }` on the sidebar entity via the `input` mod. The input mod writes `input_sidebar` output component; the sidebar reads `changed { "input_sidebar" }` in its Update system.

## Usage

```lua
-- Preferred: declare buttons inline (reconciler spawns sidebar/button children).
spawn({
    mod = { sidebar = {
        buttons = {
            profiler    = { icon_text = "⏱", title = "Profiler",      panel_mod = "sidebar/profiler/panel",      order = 1 },
            file_browser = { icon_text = "📁", title = "Files",        panel_mod = "sidebar/file_browser/panel",  order = 2 },
        },
    } },
})

-- Lower-level escape hatch: spawn buttons manually as children.
local sidebar_entity = spawn({ mod = { sidebar = {} } })
spawn({ mod = { ["sidebar/button"] = { icon_text = "⏱", title = "Profiler", panel_mod = "sidebar/profiler/panel" } } })
    :with_parent(sidebar_entity:id())
```

## Live Config Updates

Patching `buttons` on the `sidebar` component triggers `changed` detection. The reconciler diffs against `SidebarState.sidebars_by_id[eid].last_buttons` (JSON-encoded) and only acts when the map actually changes, preventing loops from its own self-patches (`icon_bar_id` / `container_id`).
