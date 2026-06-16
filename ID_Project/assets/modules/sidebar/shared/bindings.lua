-- modules/sidebar/shared/bindings.lua
-- Shared binding definitions for sidebar.
-- Used by client for input registration.
-- Supports multi-binding: Escape key + VR B-button for menu toggle.

return {
    open_menu = {
        { key = "Escape", mode = "always" },
        { vr = "b",       mode = "always" },
    },
}
