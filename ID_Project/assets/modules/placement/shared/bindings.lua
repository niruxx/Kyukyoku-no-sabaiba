-- modules/placement/shared/bindings.lua
-- Input bindings for placement mode.
-- Used by placement/client to poll confirm/cancel actions.
-- Multi-binding: each action has desktop (mouse/keyboard) + VR alternatives.
--   confirm → left mouse / right trigger
--   cancel  → right mouse / Escape / B button

return {
    confirm = {
        { mouse = "Left",          mode = "always" },
        { vr    = "right_trigger", mode = "always" },
    },
    cancel = {
        { mouse = "Right",  mode = "always" },
        { key   = "Escape", mode = "always" },
        { vr    = "b",      mode = "always" },
    },
}
