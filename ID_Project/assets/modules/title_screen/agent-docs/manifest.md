---
depends_on: []
conflicts_with: []
exposes: [title_screen]
---

# title_screen

Pixel-art start menu displayed before the networked game launches.  Plays a
looping chiptune (`title_screen.wav`), animates a rainbow-shimmer title and a
twinkling star field, and presents three menu choices: **Start Game**, **Options**,
and **Exit**.

The module runs in the root client Lua scope (same scope as `Hello/scripts/main.lua`)
and uses `input_mode = "ui"` implicitly — no player entity or `input` component is
present at this stage, so the cursor is visible and all mouse events reach the UI.

## Usage

```lua
-- Hello/scripts/main.lua (replace the last spawn line with):
require("modules/title_screen/client/init.lua")
```

The title screen then calls `spawn({ game = { ... } })` on "Start Game" click,
which is detected by `main.lua`'s existing `PreUpdate` watcher.

## Components

None exposed externally.  All entities are owned by the title screen root node
and are despawned as a unit when the player clicks **Start Game**.

## Audio

| File | Path |
|------|------|
| Title chiptune | `modules/title_screen/audio/title_screen.wav` |

16-bit PCM, 44 100 Hz, mono, 4-second loop.  Square-wave melody (C-major
pentatonic arpeggio) with sub-octave bass layer.  Loaded via `load_asset()`.

## Systems

| Schedule | Label | Purpose |
|----------|-------|---------|
| First | — | Build the full UI hierarchy (runs once, guarded by `initialized` flag) |
| Update | TitleScreenAnim | Animate title colour, star alphas, press-start blink |

## UI Layout

```
root (Absolute, full-screen, z=200, dark background)
├── [80×] star pixel  (Absolute, random positions)
├── [12×] scanline bar (Absolute, decorative)
└── col  (Column, centred)
    ├── pixel_rule (accent bar)
    ├── title text  "H E L L O"        ← rainbow shimmer each frame
    ├── subtitle    "G A M E  E N G I N E"
    ├── version tag
    ├── pixel_rule
    ├── menu card (panel background)
    │   ├── Button "START GAME"
    │   ├── Button "OPTIONS"
    │   └── Button "EXIT"
    └── press-start hint               ← blinks every 0.55 s
```

### Options overlay (z=210, hidden until Options clicked)

```
opts_overlay (Absolute, full-screen, dark semi-transparent)
└── opts_card
    ├── "OPTIONS" header
    ├── Section: SCREEN RESOLUTION
    │   └── [◀]  "1920 × 1080 (FHD)"  [▶]
    ├── Section: AUDIO VOLUME
    │   └── [−]  " 70%"                [+]
    └── Button "CLOSE"
```

Resolution choices: 1280×720 (HD), 1920×1080 (FHD), 2560×1440 (QHD).  
Volume range: 0–100 % in 10 % steps; applied via `GlobalVolume` resource and
`PlaybackSettings` patch on the music entity.

## Animations

| Effect | Technique | Update rate |
|--------|-----------|-------------|
| Title rainbow shimmer | `TextColor` patch with HSL→RGB cycle | Every frame |
| Star-field twinkling | `BackgroundColor` alpha sine wave | Every 4th frame |
| "Press Start" blink | `TextColor` alpha toggle | Every 0.55 s |
| Button hover glow | `observe("Pointer<Over/Out>")` | Event-driven |

## File Structure

```
modules/title_screen/
├── agent-docs/
│   └── manifest.md        ← this file
├── audio/
│   └── title_screen.wav   ← looping chiptune (generated)
└── client/
    └── init.lua           ← full title screen implementation
```
