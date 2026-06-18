-- modules/weapons/shared/bindings.lua
-- Key bindings for all three zombie survival weapons.
-- Used by both client (key polling) and server (validation whitelist).

return {
    railgun    = { key = "KeyQ", mode = "game" },
    explosives = { key = "KeyE", mode = "game" },
    nova       = { key = "KeyR", mode = "game" },
}
