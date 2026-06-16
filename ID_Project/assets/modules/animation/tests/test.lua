-- modules/animation/tests/test.lua
-- Stage-based test for animation mod.
-- Run: cargo run -p hello -- --script modules/animation/tests/test.lua

require("modules/mod/init.lua")
require("modules/net_mod/init.lua")

local net_info = define_resource("NetInfo", { side = nil })
net_info.side = "server"

local state = define_resource("AnimTestState", {
    phase = 0, frames = 0, passed = 0, failed = 0,
    anim_eid = nil,
})
state.phase = 0; state.frames = 0; state.passed = 0; state.failed = 0

local function assert_eq(label, got, expected)
    if got == expected then state.passed = state.passed + 1; print("[ANIM TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[ANIM TEST] FAIL: " .. label ..
        " expected=" .. tostring(expected) .. " got=" .. tostring(got)) end
end
local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_not_nil(label, val)
    if val ~= nil then state.passed = state.passed + 1; print("[ANIM TEST] PASS: " .. label)
    else state.failed = state.failed + 1; print("[ANIM TEST] FAIL: " .. label .. " expected non-nil") end
end

register_system("Update", function(world)
    state.frames = state.frames + 1

    if state.phase == 0 then
        print("[ANIM TEST] === Phase 1: Spawn animation mod ===")
        state.anim_eid = spawn({
            net_mod = { animation = {
                model = "Placeholder-Character/Model",
                clips = {
                    idle = "-Idle.glb",
                    walk = "-Walk.glb",
                    jump = "-Jump.glb",
                    fall = "-Jump.glb",
                },
            }},
        }):id()
        state.phase = 1
        state.frames = 0
        return
    end

    if state.phase == 1 then
        if state.frames < 15 then return end
        local e = world:get_entity(state.anim_eid)
        assert_not_nil("P1: animation entity exists", e)
        if e then
            assert_true("P1: has animation component", e:has("animation"))

            local anim = e:get("animation")
            assert_not_nil("P1: animation has data", anim)
            if anim then
                assert_eq("P1: model is Placeholder-Character/Model",
                    anim.model, "Placeholder-Character/Model")
                assert_eq("P1: initial state is idle", anim.state, "idle")
                assert_not_nil("P1: has clips table", anim.clips)
            end

            -- Verify net_sync authority
            local ns = e:get("net_sync")
            assert_not_nil("P1: has net_sync", ns)
            if ns and ns.animation then
                assert_eq("P1: animation authority is server", ns.animation.authority, "server")
            end
        end

        -- Phase 2: test runtime clip update
        print("[ANIM TEST] === Phase 2: Add clip at runtime ===")
        if e then
            e:patch({ animation = { clips = { attack = "-Attack.glb" } } })
        end
        state.phase = 2
        state.frames = 0
        return
    end

    if state.phase == 2 then
        if state.frames < 3 then return end
        local e = world:get_entity(state.anim_eid)
        if e then
            local anim = e:get("animation")
            if anim and anim.clips then
                assert_eq("P2: attack clip added", anim.clips.attack, "-Attack.glb")
                assert_eq("P2: idle clip preserved", anim.clips.idle, "-Idle.glb")
            end
        end

        if e then despawn(e) end
        state.phase = 3
        state.frames = 0
        return
    end

    if state.phase == 3 then
        print("")
        print("=========================================")
        print("[ANIM TEST] RESULTS: " .. state.passed .. " passed, " .. state.failed .. " failed")
        print("=========================================")
        if state.failed > 0 then print("[ANIM TEST] SOME TESTS FAILED")
        else print("[ANIM TEST] ALL TESTS PASSED") end
        state.phase = 99
    end
end)
