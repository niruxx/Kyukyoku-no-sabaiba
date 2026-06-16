-- modules/net_mod/tests/test_sub_mod/server/init.lua
-- Test fixture: subtype that declares a base dependency.
-- When loaded, the mod loader sees { base = "net_mod/tests/test_base_mod" }
-- and loads the base too.

return { base = "net_mod/tests/test_base_mod" }
