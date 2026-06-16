-- modules/camera/third_person/shared/bindings.lua
-- Shared binding definitions for third-person camera.
-- Mouse motion/scroll are local-only (no sync group output).

return {
    look = { type = "mouse_motion", mode = "game" },
    zoom = { type = "mouse_scroll", mode = "game" },
}
