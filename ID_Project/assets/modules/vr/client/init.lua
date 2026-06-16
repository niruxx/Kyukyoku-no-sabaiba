-- modules/vr/client/init.lua
-- VR Orchestrator: detects VR mode, selects camera sub-mod,
-- and loads VR-specific mods (pointer, ui_panels) on the player entity.
-- On desktop: patches camera/third_person (default).
-- On VR: patches camera/vr + vr/pointer + vr/ui_panels.
-- Also defines VrSettings resource.

---------------------------------------------------------------------------
-- VrSettings: global VR preferences.
-- Defined here so it's available before any VR mod reads it.
---------------------------------------------------------------------------
define_resource("VrSettings", {
    -- Movement direction reference frame:
    --   "head" = forward is HMD look direction (default, most natural)
    --   "body" = forward is stick rotation only (no head influence)
    --   "hand" = forward is left controller forward direction
    movement_direction = "head",

    -- Which hand holds the pointer/laser
    pointer_hand = "right",

    -- Rotation style
    snap_turn = false,
    snap_turn_angle = 45,

    -- Comfort
    comfort_vignette = false,
})

---------------------------------------------------------------------------
-- Detect VR mode by checking for VrButtonState resource.
---------------------------------------------------------------------------
local function is_vr_mode(world)
    local vr = world:get_resource("VrButtonState")
    return vr ~= nil
end

---------------------------------------------------------------------------
-- Init: on added { "vr" }, select camera sub-mod and load VR mods
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "vr" } })) do
        local vr = is_vr_mode(world)

        if vr then
            -- VR mode: use camera/vr (finds XR Camera3d) + pointer + ui_panels + grabbable
            entity:patch({ mod = {
                ["camera/vr"]      = {},
                ["vr/pointer"]     = {},
                ["vr/ui_panels"]   = {},
                ["vr/grabbable"]   = {},
            }})
            print(string.format(
                "[VR/CLIENT] VR mode: loaded camera/vr + pointer + ui_panels + grabbable for entity %d",
                entity:id()))
        else
            -- Desktop mode: use camera/third_person (spawns Camera3d, orbit)
            entity:patch({ mod = { ["camera/third_person"] = {} } })
            print(string.format(
                "[VR/CLIENT] Desktop mode: loaded camera/third_person for entity %d",
                entity:id()))
        end
    end
end, { label = "VrInit", before = { "CameraInit" } })
