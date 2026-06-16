---
depends_on: [sidebar/button]
conflicts_with: []
exposes: [sidebar/profiler/panel]
---

# sidebar/profiler/panel

Profiler panel mod. Patches a full-height panel UI onto its own entity (which the sidebar button spawns as a child of the sidebar entity). Displays Lua system timing, FPS, memory usage, and coroutine-based global table scanning.

## Components

- `sidebar/profiler/panel` — Marker component. No config fields. Presence triggers the `First` system to build the panel UI.

## Resources

- `ProfilerState` — All profiler data and UI scroll state. Persists hot-reload.
  - `enabled` — whether the profiler collects data
  - `systems` — `{ [system_name] = { count, total_ms, max_ms, avg_ms, last_ms, state_id, queries } }`
  - `queries` — global query timing map
  - `frame_times` — ring buffer of recent frame times (ms), max 120 entries
  - `current_fps`, `lua_memory_kb` — cached display values
  - `scan_enabled`, `scan_interval_frames`, `scan_max_depth`, `scan_size_threshold` — table scan config
  - `scan_snapshots`, `scan_growth_alerts`, `scan_results` — table scan state
  - `scan_coroutine`, `pending_scan_results` — coroutine-based incremental scan
  - `parallel_enabled`, `state_count` — Rust-side system scheduler info
  - `scroll_offset`, `systems_scroll_offset` — persisted scroll positions
  - `update_counter`, `expanded_system` — UI update throttle and expanded row

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | `added { "sidebar/profiler/panel" }`: patch panel `Node`/`BackgroundColor`/`BorderColor` onto entity; spawn fixed header container and scrollable content area |
| Update | — | Collect `world:profiler_stats()`, update frame times / FPS / memory, advance table-scan coroutine, re-render UI every 30 frames or on click |

## UI Layout

```
panel entity  (Node: width=320, height=100%, flex_direction=Column)
├── header_container  (height=36, Row)
│   └── [rendered each update] header row: "[Profiler]" | FPS | Memory KB
└── scroll_container  (flex_grow=1, overflow=Scroll)
    ├── Systems section header + state count
    ├── Total Lua time row
    ├── systems_scroll  (height=200, overflow.y=Scroll)
    │   └── per-system rows  (click to expand: path, max/last/count, per-system queries)
    ├── [if growth alerts] "! Table Growth" section
    └── [if scan results] "Largest Tables" section
```

Content is rebuilt every 30 frames by despawning `ui.content_entities` and re-spawning. Transient `ui` table (panel/header/scroll entity IDs) resets on hot-reload; `ProfilerState` persists.

## Table Scanner

A coroutine walks `_G` up to `scan_max_depth` (default 5), yielding every `depth < 2` step. Resumed 10 iterations per frame. Tables larger than `scan_size_threshold` (default 50 entries) are recorded. Growth > 20% or > 100 entries since last scan triggers an alert entry in `scan_growth_alerts`.

## Data Source

`world:profiler_stats()` returns Rust-side system timing:
```lua
{
    parallel_enabled = bool,
    systems = {
        ["schedule:path/to/script.lua:label"] = {
            count, total_ms, max_ms, avg_ms, last_ms, state_id,
            queries = { ["sig"] = { count, avg_ms, last_result_count } },
        },
    },
    queries = { ... },
}
```

## Usage

```lua
-- Spawned automatically by sidebar/button on click. No manual config needed.
-- The button stores panel_mod = "sidebar/profiler/panel".

-- Manual spawn (e.g. for testing):
local sidebar_entity = -- ... existing sidebar entity
spawn({
    mod = { ["sidebar/profiler/panel"] = {} },
}):with_parent(sidebar_entity:id())
```
