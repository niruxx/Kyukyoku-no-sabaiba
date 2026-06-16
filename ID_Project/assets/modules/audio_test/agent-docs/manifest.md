---
depends_on: []
conflicts_with: []
exposes: [audio_test]
---

# audio_test

Demonstration mod for the Bevy audio pipeline exposed through Lua. Tests three categories of audio: background music (global looping), one-shot sound effects (periodic auto-despawn), and spatial 3D audio (positioned sources orbiting a listener).

Client-only audio — the server init stub marks `status = "pending"` for net_sync replication; the client init performs all audio entity spawning.

## Prerequisites

WAV format support requires the `wav` feature on the `bevy` workspace dependency:

```toml
# Cargo.toml (workspace)
bevy = { version = "0.17", features = ["wav"] }
```

Without this, Bevy only supports OGG Vorbis via `lewton`. Enabling `wav` adds `rodio/wav` (hound-based decoder). Other available format features: `mp3`, `flac`, `symphonia-all`.

## Components

- `audio_test` — Config + status. `{ status, music_id, hum_id, drip_id, music_volume?, spatial_volume? }`. Authority: server.

## Bevy Audio Components Used

| Component | Type | Purpose |
|-----------|------|---------|
| `AudioPlayer` | `Handle<AudioSource>` newtype | Attaches an audio source to an entity for playback. Accepts asset ID from `load_asset()`. |
| `PlaybackSettings` | Struct | `{ mode, volume, spatial }`. `mode`: `"Loop"`, `"Despawn"`, `"Once"`, `"Remove"`. `volume`: `{ Linear = 0.5 }`. `spatial`: `true`/`false`. |
| `SpatialListener` | Marker | Designates an entity as the 3D audio listener (the "ear"). Typically co-located with `Camera3d`. |

## Audio Patterns

### Global Music (Looping)

```lua
local music = load_asset("path/to/music.wav")
spawn({
    AudioPlayer = music,
    PlaybackSettings = {
        mode   = "Loop",
        volume = { Linear = 0.5 },
    },
})
```

### One-Shot SFX (Auto-Despawn)

```lua
spawn({
    AudioPlayer = sfx_asset,
    PlaybackSettings = {
        mode   = "Despawn",
        volume = { Linear = 0.9 },
    },
})
```

The entity is automatically despawned when playback finishes.

### Spatial Audio (3D Positioned)

```lua
-- Listener (place on camera entity)
spawn({
    SpatialListener = {},
    Camera3d = {},
    Transform = { translation = { x = 0, y = 2, z = 0 } },
})

-- Sound source (positioned in world)
spawn({
    AudioPlayer = hum_asset,
    PlaybackSettings = {
        mode    = "Loop",
        volume  = { Linear = 0.9 },
        spatial = true,
    },
    Transform = {
        translation = { x = 8, y = 1, z = 0 },
    },
})
```

Move the `Transform` of spatial sources to pan audio left/right and adjust volume by distance.

## Systems

| Schedule | Label | Side | Purpose |
|----------|-------|------|---------|
| First | — | Server | Initialize `audio_test` component with `status = "pending"` on `added` entities |
| First | — | Client | On `added { "audio_test" }`: spawn music, spatial hum, spatial drip, preload SFX assets, store instance state |
| Update | AudioTest | Client | Orbit spatial sources via `Transform` patch; trigger one-shot SFX every 2s (cycles click → pickup → footstep) |
| PostUpdate | — | Client | Clean up instance state when `audio_test` component is removed |

## Build System: AudioPlayer Handler

`AudioPlayer` is a `Handle<AudioSource>` newtype component. The build script (`build.rs`) auto-generates a compile-time handler for it via the **prelude filter**:

1. `is_type_publicly_exported()` scans `bevy_audio`'s `lib.rs` in the cargo registry
2. Finds `pub mod prelude { ... AudioPlayer ... }` → type IS publicly exported
3. `is_type_in_crate_prelude()` confirms `AudioPlayer` appears in the prelude block
4. Build script generates `register_handle_component::<bevy::audio::AudioPlayer, bevy::audio::AudioSource, _>()`

This means Lua can pass an asset ID (from `load_asset()`) directly to `AudioPlayer` and the engine constructs a properly typed `Handle<AudioSource>`.

Types NOT in any crate prelude (e.g., `MeshletMesh3d`, `AnimationGraphHandle`) are correctly skipped, preventing compile errors from inaccessible types.

## File Structure

```
modules/audio_test/
├── agent-docs/
│   └── manifest.md          ← this file
├── client/
│   └── init.lua             ← audio entity spawning + update loop
├── server/
│   └── init.lua             ← stub: mark status for net_sync
└── tests/
    ├── test.lua              ← standalone test script
    └── audio/                ← generated WAV assets
        ├── music_ambient.wav
        ├── sfx_click.wav
        ├── sfx_pickup.wav
        ├── sfx_footstep.wav
        ├── spatial_hum.wav
        └── spatial_drip.wav
```

## Tests

Run standalone (no mod system dependency):

```sh
cargo run -p hello -- --script modules/audio_test/tests/test.lua
```

The test script spawns all audio entities directly in bootstrap, verifying the full audio pipeline:
- `SpatialListener` + `Camera3d` (the ear)
- Looping music entity
- Two spatial sources orbiting the listener
- Periodic one-shot SFX (click/pickup/footstep every 2s)

## Audio Asset Generation

Test WAV files are procedurally generated via Python (`generate_audio.py`). Files must use standard RIFF WAV format with:
- 16-bit PCM (`WAVE_FORMAT_PCM`, audio format = 1)
- 44100 Hz sample rate
- Mono channel
- Minimal 44-byte header (no extra chunks)

> [!WARNING]
> Python's `wave` module may produce non-standard headers on some versions. Use manual WAV header construction (raw `struct.pack`) for guaranteed compatibility with rodio's WAV decoder.

## Notes

- `AudioPlayer` requires a compile-time handler (not runtime `load_untyped`). The build script generates this automatically via prelude scanning.
- Volume uses `{ Linear = N }` syntax (0.0–1.0 range). Bevy also supports `{ Decibels = N }`.
- `PlaybackSettings.spatial = true` requires a `SpatialListener` entity somewhere in the world, and the audio source needs a `Transform`.
- One-shot SFX with `mode = "Despawn"` auto-clean — no manual despawn needed.
- Orbiting spatial sources demonstrates real-time panning by patching `Transform.translation` each frame.
