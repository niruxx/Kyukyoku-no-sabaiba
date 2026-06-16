---
depends_on: [sidebar]
conflicts_with: []
exposes: [sidebar/button]
---

# sidebar/button

Reusable sidebar button mod. Spawns an icon button inside the parent sidebar's icon bar, handles hover/click effects, and manages panel spawn/despawn lifecycle. Tracks its open panel via the `sidebar/button` component so the sidebar can handle Escape-key panel closing.

## Components

- `sidebar/button` — Config + runtime state. Set by spawner; updated on click and hot-reload.
  - Config fields (set at spawn time):
    - `icon_text` — short text label for the icon (e.g. `"⏱"`, `"📁"`)
    - `icon_asset` — asset path for an image icon (e.g. `"icons/profiler.png"`). Takes precedence over `icon_text`. Loaded async; stale results from A→B→A edits are discarded.
    - `title` — button tooltip / label (used in log output)
    - `panel_mod` — mod name to spawn as panel (client-only, via `mod`)
    - `panel_net_mod` — mod name to spawn as panel (networked, via `net_mod`) — alternative to `panel_mod`
    - `panel_config` — optional extra config table forwarded to the panel mod
    - `order` — optional sort key used by the sidebar reconciler (ascending, ties break alphabetically by key name)
  - Set at runtime (do not write manually):
    - `icon_entity_id` — entity ID of the icon `Button` node spawned in the icon bar
    - `panel_entity_id` — entity ID of the currently open panel, or `nil`
    - `opened_at` — `os.clock()` timestamp when the panel was opened, or `nil`

## Resources

- `SidebarButtonInstances` — `{ by_id = { [eid] = { icon_btn_id, icon_child_id, last_config } } }`. Persists hot-reload. Used for live icon swapping on config edits.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | `added { "sidebar/button" }`: walk to parent sidebar, spawn icon button in icon bar, register hover/click observers |
| First | — | `changed { "sidebar/button" }`: swap icon child if `icon_asset` or `icon_text` changed; sync icon background color with panel state |

## Hot-Reload Panel Recovery

On `added`, the button queries the sidebar entity's children for a sibling with the matching `panel_mod` component. If found, it re-adopts the surviving panel entity as its `panel_entity_id` so it can be closed correctly after a hot-reload.

## Architecture

```
sidebar entity
├── icon_bar
│   └── icon button (Button, Node, observers: Over/Out/Click)
│       └── icon child (ImageNode or Text)
└── [on click] panel entity  (mod = { [panel_mod] = panel_config })
```

The button entity is a **child of the sidebar entity** (not of the icon bar). Its icon button node is parented to the icon bar via the `icon_bar_id` stored in the parent's `sidebar` component.

Click behaviour:
- **Panel open** → despawn panel entity, clear `panel_entity_id` / `opened_at`, reset icon background.
- **Panel closed** → spawn panel entity as child of the sidebar entity, set `panel_entity_id` / `opened_at`, highlight icon.

## Usage

```lua
-- Preferred: declare via sidebar's `buttons` config map (reconciler spawns children automatically).
spawn({
    mod = { sidebar = {
        buttons = {
            profiler = { icon_text = "⏱", title = "Profiler", panel_mod = "sidebar/profiler/panel", order = 1 },
        },
    } },
})

-- Manual: spawn as a direct child of the sidebar entity.
local sidebar_entity = spawn({ mod = { sidebar = {} } })
spawn({
    mod = { ["sidebar/button"] = {
        icon_text  = "⏱",
        title      = "Profiler",
        panel_mod  = "sidebar/profiler/panel",
    }},
}):with_parent(sidebar_entity:id())
```
