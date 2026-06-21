-- modules/movement/shared/bindings.lua
-- Shared binding definitions for movement.
-- Used by both client (key polling) and server (validation).
-- Supports multi-binding: each action has keyboard + VR alternatives.

return {
    forward  = { { key = "KeyW",     mode = "game" }, { vr = "left_stick_up",    mode = "game" } },
    backward = { { key = "KeyS",     mode = "game" }, { vr = "left_stick_down",  mode = "game" } },
    left     = { { key = "KeyA",     mode = "game" }, { vr = "left_stick_left",  mode = "game" } },
    right    = { { key = "KeyD",     mode = "game" }, { vr = "left_stick_right", mode = "game" } },
    jump     = { { key = "Space",    mode = "game" }, { vr = "a",                mode = "game" } },
    sprint   = { key = "ShiftLeft", mode = "game" },
}
