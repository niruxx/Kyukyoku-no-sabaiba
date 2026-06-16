-- modules/vr/grabbable/shared/bindings.lua
-- Grab binding: uses the pointer hand's grip button.
-- Registered as a sync group so the input mod produces input_grabbable.

return {
    grab = { { vr = "right_grip", mode = "always" } },
}
