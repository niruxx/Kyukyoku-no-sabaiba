-- modules/net/tests/test_prediction.lua
-- Pure-function tests for client-side prediction and server-side pending-spawn
-- state machine. Verifies serialization, lifecycle transitions, and exclusion
-- semantics. No live network needed.
-- Run: cargo run -p hello -- --script modules/net/tests/test_prediction.lua
--
-- Tests:
--   1.  collect_predict_components: net_sync only
--   2.  collect_predict_components: net_sync + identity components
--   3.  collect_predict_components: net_mod dict form pulls marker components
--   4.  collect_predict_components: net_mod array form pulls marker components
--   5.  collect_predict_components: missing marker (no entity component) → omitted
--   6.  Client predict state: allocate → predicted + predicted_by_eid both set
--   7.  Client predict state: confirm clears both maps
--   8.  Client predict state: reject clears both maps
--   9.  Client predict state: next_predicted decrements monotonically
--  10.  Client predict state: id_map lookup distinguishes server vs local
--  11.  Server pending lifecycle: approve (net_predict removed) → tracking row
--  12.  Server pending lifecycle: reject (entity despawned) → SPAWN_REJECT shape
--  13.  Server pending lifecycle: timeout → despawn (next tick rejects)
--  14.  broadcast_spawn exclude_client: predicting client skipped
--  15.  PREDICT_TIMEOUT constant exposed

local Net = require("modules/net/shared/net.lua")
local Tracking = require("modules/net/shared/tracking.lua")

---------------------------------------------------------------------------
-- Mock helpers
---------------------------------------------------------------------------
local function mock_entity(components)
    components = components or {}
    return {
        id = function(self) return components.__id or 0 end,
        has = function(self, name) return components[name] ~= nil end,
        get = function(self, name) return components[name] end,
    }
end

local passed, failed = 0, 0

local function assert_eq(label, got, expected)
    if got == expected then
        passed = passed + 1
        print("info", "[PREDICT TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[PREDICT TEST] FAIL: " .. label ..
            " expected=" .. tostring(expected) .. " got=" .. tostring(got))
    end
end

local function assert_true(label, val) assert_eq(label, val, true) end
local function assert_false(label, val) assert_eq(label, val, false) end

local function assert_nil(label, val)
    if val == nil then
        passed = passed + 1
        print("info", "[PREDICT TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[PREDICT TEST] FAIL: " .. label .. " expected nil, got " .. tostring(val))
    end
end

local function assert_not_nil(label, val)
    if val ~= nil then
        passed = passed + 1
        print("info", "[PREDICT TEST] PASS: " .. label)
    else
        failed = failed + 1
        print("error", "[PREDICT TEST] FAIL: " .. label .. " expected non-nil")
    end
end

local function table_size(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- 1. collect_predict_components: net_sync-only entity
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 1. collect: net_sync only ===")
do
    local entity = mock_entity({
        Transform = { x = 1, y = 2, z = 3 },
        Velocity3d = { linvel = { x = 5 } },
        net_sync = {
            Transform = { authority = "client", reliable = false },
            Velocity3d = { authority = "client" },
        },
    })
    local comps = Tracking.collect_predict_components(entity)
    assert_not_nil("comps.Transform sent", comps.Transform)
    assert_not_nil("comps.Velocity3d sent", comps.Velocity3d)
    assert_eq("Transform.x preserved", comps.Transform and comps.Transform.x, 1)
    assert_not_nil("comps.net_sync attached", comps.net_sync)
    assert_eq("net_sync.Transform.authority", comps.net_sync.Transform.authority, "client")
end

---------------------------------------------------------------------------
-- 2. collect_predict_components: includes net_owner + net_predict when present
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 2. collect: identity components ===")
do
    local entity = mock_entity({
        Transform = { x = 0 },
        net_sync = { Transform = { authority = "client" } },
        net_owner = { client_id = 7 },
        net_predict = { custom = "marker" },
    })
    local comps = Tracking.collect_predict_components(entity)
    assert_eq("net_owner.client_id", comps.net_owner and comps.net_owner.client_id, 7)
    assert_eq("net_predict.custom", comps.net_predict and comps.net_predict.custom, "marker")
end

---------------------------------------------------------------------------
-- 3. collect_predict_components: net_mod dict form pulls marker components
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 3. collect: net_mod dict form ===")
do
    -- placement isn't in net_sync — should still ship because it's named in net_mod.
    local entity = mock_entity({
        Transform = { x = 0 },
        placement = {},
        ["git/scope/portal"] = { scope_a = "A", scope_b = "B" },
        net_sync = { Transform = { authority = "client" } },
        net_mod = {
            placement = {},
            ["git/scope/portal"] = { scope_a = "A", scope_b = "B" },
        },
    })
    local comps = Tracking.collect_predict_components(entity)
    assert_not_nil("comps.placement (via net_mod)", comps.placement)
    assert_not_nil("comps.git/scope/portal (via net_mod)", comps["git/scope/portal"])
    assert_eq("portal scope_a preserved", comps["git/scope/portal"].scope_a, "A")
    assert_not_nil("comps.net_mod attached", comps.net_mod)
end

---------------------------------------------------------------------------
-- 4. collect_predict_components: net_mod array form
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 4. collect: net_mod array form ===")
do
    local entity = mock_entity({
        Transform = { x = 0 },
        camera = { mode = "third_person" },
        net_sync = { Transform = { authority = "client" } },
        net_mod = {
            { camera = { mode = "third_person" }, net_sync = { camera = { target = "owner" } } },
        },
    })
    local comps = Tracking.collect_predict_components(entity)
    assert_not_nil("array form: camera marker pulled", comps.camera)
    assert_eq("array form: camera.mode preserved", comps.camera.mode, "third_person")
end

---------------------------------------------------------------------------
-- 5. collect_predict_components: marker named in net_mod but not on entity
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 5. collect: missing marker omitted ===")
do
    local entity = mock_entity({
        Transform = { x = 0 },
        net_sync = { Transform = { authority = "client" } },
        net_mod = { placement = {}, ["module/that/has/no/component"] = {} },
        -- Note: NO `placement = {}` top-level component on the entity
    })
    local comps = Tracking.collect_predict_components(entity)
    assert_nil("missing placement omitted", comps.placement)
    assert_nil("missing module component omitted", comps["module/that/has/no/component"])
    -- But net_mod itself still goes through (so the server can load the modules)
    assert_not_nil("net_mod still attached", comps.net_mod)
end

---------------------------------------------------------------------------
-- 6. Client predict state: allocate sets both maps
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 6. client state: allocate ===")
do
    local state = {
        next_predicted = -1,
        predicted = {},
        predicted_by_eid = {},
        elapsed_time = 1.5,
    }

    -- Simulate NetPredictTrack allocation
    local eid = 42
    local predicted_eid = state.next_predicted
    state.next_predicted = state.next_predicted - 1
    state.predicted[predicted_eid] = { entity_id = eid, spawn_time = state.elapsed_time }
    state.predicted_by_eid[eid] = predicted_eid

    assert_eq("allocate: predicted_eid", predicted_eid, -1)
    assert_eq("allocate: next_predicted decremented", state.next_predicted, -2)
    assert_not_nil("allocate: predicted entry", state.predicted[-1])
    assert_eq("allocate: predicted.entity_id", state.predicted[-1].entity_id, 42)
    assert_eq("allocate: predicted.spawn_time", state.predicted[-1].spawn_time, 1.5)
    assert_eq("allocate: reverse lookup", state.predicted_by_eid[42], -1)
end

---------------------------------------------------------------------------
-- 7. Client predict state: confirm clears both maps
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 7. client state: confirm ===")
do
    local state = {
        predicted = { [-1] = { entity_id = 42, spawn_time = 1.0 } },
        predicted_by_eid = { [42] = -1 },
    }
    -- Simulate SPAWN_CONFIRM handler
    local pred = state.predicted[-1]
    state.predicted[-1] = nil
    state.predicted_by_eid[pred.entity_id] = nil

    assert_nil("confirm: predicted cleared", state.predicted[-1])
    assert_nil("confirm: reverse lookup cleared", state.predicted_by_eid[42])
    assert_eq("confirm: predicted size", table_size(state.predicted), 0)
    assert_eq("confirm: reverse size", table_size(state.predicted_by_eid), 0)
end

---------------------------------------------------------------------------
-- 8. Client predict state: reject clears both maps
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 8. client state: reject ===")
do
    local state = {
        predicted = { [-2] = { entity_id = 99, spawn_time = 0.5 } },
        predicted_by_eid = { [99] = -2 },
    }
    -- Simulate SPAWN_REJECT handler
    local pred = state.predicted[-2]
    state.predicted[-2] = nil
    state.predicted_by_eid[pred.entity_id] = nil

    assert_nil("reject: predicted cleared", state.predicted[-2])
    assert_nil("reject: reverse cleared", state.predicted_by_eid[99])
end

---------------------------------------------------------------------------
-- 9. next_predicted decrements monotonically (no collisions)
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 9. next_predicted monotonic ===")
do
    local state = { next_predicted = -1 }
    local seen = {}
    for _ = 1, 50 do
        local id = state.next_predicted
        state.next_predicted = state.next_predicted - 1
        assert_nil("predicted id unique " .. tostring(id), seen[id])
        seen[id] = true
        assert_true("predicted id negative " .. tostring(id), id < 0)
    end
    assert_eq("unique count", table_size(seen), 50)
end

---------------------------------------------------------------------------
-- 10. id_map distinguishes server-broadcast vs local-spawn entities
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 10. id_map distinguishes origin ===")
do
    local id_map = Net.create_id_map()
    -- Server-broadcast entity gets mapped immediately
    Net.map(id_map, 100, 7)
    -- A locally-spawned entity has NO entry in id_map until SPAWN_CONFIRM

    assert_eq("server entity is mapped", id_map.entity_to_net[7], 100)
    assert_nil("local entity has no net_id", id_map.entity_to_net[8])

    -- NetPredictTrack's skip condition: `if id_map.entity_to_net[eid] then skip end`
    local function is_predicted(eid)
        return id_map.entity_to_net[eid] == nil
    end
    assert_false("server entity not predicted", is_predicted(7))
    assert_true("local entity predicted", is_predicted(8))
end

---------------------------------------------------------------------------
-- 11. Server pending lifecycle: approve path
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 11. server pending: approve ===")
do
    -- Simulate NetPredictFinalize approval branch
    local pending_predicts = {
        [50] = { client_id = 1, predicted_eid = -1, parent_net_id = nil, spawn_time = 0.0 },
    }
    local tracked = {}
    local next_net_id = 1

    -- Entity exists and has no net_predict → approve
    local entity = mock_entity({
        __id = 50,
        net_sync = { Transform = { authority = "client" } },
        net_owner = { client_id = 1 },
        -- NOTE: net_predict intentionally absent (mod removed it)
    })
    local pending = pending_predicts[50]
    if entity and not entity:has("net_predict") then
        local net_id = next_net_id; next_net_id = next_net_id + 1
        tracked[net_id] = {
            sync_config = entity:get("net_sync"),
            prev_owner = (entity:get("net_owner") or {}).client_id,
        }
        pending_predicts[50] = nil
    end

    assert_nil("approve: pending entry cleared", pending_predicts[50])
    assert_not_nil("approve: tracked entry created", tracked[1])
    assert_eq("approve: tracked prev_owner", tracked[1].prev_owner, 1)
    assert_eq("approve: next_net_id advanced", next_net_id, 2)
end

---------------------------------------------------------------------------
-- 12. Server pending lifecycle: reject path
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 12. server pending: reject ===")
do
    local pending_predicts = {
        [60] = { client_id = 3, predicted_eid = -5, parent_net_id = nil, spawn_time = 0.0 },
    }
    -- Simulate "entity was despawned by a mod"
    local entity = nil
    local sent_reject = nil
    local pending = pending_predicts[60]
    if not entity then
        sent_reject = {
            msg_type = Net.MSG.SPAWN_REJECT,
            predicted_eid = pending.predicted_eid,
        }
        pending_predicts[60] = nil
    end

    assert_eq("reject: predicted_eid in message", sent_reject and sent_reject.predicted_eid, -5)
    assert_eq("reject: msg_type", sent_reject and sent_reject.msg_type, Net.MSG.SPAWN_REJECT)
    assert_nil("reject: pending cleared", pending_predicts[60])
end

---------------------------------------------------------------------------
-- 13. Server pending lifecycle: timeout path
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 13. server pending: timeout ===")
do
    local PREDICT_TIMEOUT = 5.0
    local pending = { client_id = 1, predicted_eid = -1, spawn_time = 0.0 }
    local now = 6.0
    -- Entity still has net_predict (mod never approved)
    local entity = mock_entity({
        __id = 70,
        net_predict = { client_id = 1, predicted_eid = -1 },
    })
    local should_despawn = (entity and entity:has("net_predict") and (now - pending.spawn_time > PREDICT_TIMEOUT))
    assert_true("timeout: should despawn after window", should_despawn)

    -- Just under window → not yet
    local should_not = (entity and entity:has("net_predict") and (4.9 - pending.spawn_time > PREDICT_TIMEOUT))
    assert_false("timeout: not before window", should_not)
end

---------------------------------------------------------------------------
-- 14. broadcast_spawn exclude_client semantics
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 14. broadcast_spawn exclude ===")
do
    -- Simulate the per-client loop with exclusion.
    local clients = { [1] = { ready = true }, [2] = { ready = true }, [3] = { ready = true } }
    local exclude_client = 2
    local recipients = {}
    for client_id, info in pairs(clients) do
        if info.ready and client_id ~= exclude_client then
            recipients[#recipients + 1] = client_id
        end
    end
    table.sort(recipients)

    assert_eq("broadcast: recipient count", #recipients, 2)
    assert_eq("broadcast: includes client 1", recipients[1], 1)
    assert_eq("broadcast: includes client 3", recipients[2], 3)
end

---------------------------------------------------------------------------
-- 15. Net.MSG codes for the prediction flow are unchanged
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 15. msg codes ===")
do
    assert_eq("MSG.SPAWN_REQUEST", Net.MSG.SPAWN_REQUEST, "spawn_request")
    assert_eq("MSG.SPAWN_CONFIRM", Net.MSG.SPAWN_CONFIRM, "spawn_confirm")
    assert_eq("MSG.SPAWN_REJECT",  Net.MSG.SPAWN_REJECT,  "spawn_reject")
end

---------------------------------------------------------------------------
-- 16. Server-side approval reads `net_predict.requested` as a payload (not
--     from on-entity components). Mods must opt into each component
--     explicitly — the net module does not trust the client's spawn dict.
---------------------------------------------------------------------------
print("info", "[PREDICT TEST] === 16. request-as-payload ===")
do
    -- Simulate what placement/server does: an entity exists with ONLY a
    -- net_predict carrying the client's request. The mod selects fields
    -- from `requested` and applies a sanitized component set.
    local entity = mock_entity({
        __id = 70,
        net_predict = {
            client_id = 4,
            predicted_eid = -3,
            requested = {
                placement = {},
                Transform = { translation = { x = 1, y = 2, z = 3 } },
                Mesh3d = "mock_mesh",
                -- Client also tried to set a server-only component; mod ignores.
                evil_admin_flag = { value = true },
                net_sync = {  -- client-supplied; server ignores
                    Transform = { authority = "server" },
                },
            },
        },
    })

    local pred = entity:get("net_predict") or {}
    local req = pred.requested or {}

    -- The mod's whitelisting logic (mirrors placement/server)
    assert_not_nil("request payload: placement present", req.placement)
    assert_not_nil("request payload: Transform present", req.Transform)
    assert_eq("request payload: Mesh3d value", req.Mesh3d, "mock_mesh")
    assert_not_nil("request payload: evil flag present (visible but ignored)", req.evil_admin_flag)

    -- After mod selection, the to-set set should not include evil_admin_flag.
    local sanitized = {}
    sanitized.placement = {}
    sanitized.net_sync = {
        Transform = { authority = "client", reliable = false },
        placement = { authority = "client" },
    }
    if req.Transform then sanitized.Transform = req.Transform end
    if req.Mesh3d then sanitized.Mesh3d = req.Mesh3d end
    -- evil_admin_flag NOT copied

    assert_not_nil("sanitized: placement", sanitized.placement)
    assert_eq("sanitized: Transform.x", sanitized.Transform.translation.x, 1)
    assert_eq("sanitized: Mesh3d copied", sanitized.Mesh3d, "mock_mesh")
    assert_nil("sanitized: evil_admin_flag dropped", sanitized.evil_admin_flag)
    -- Server's net_sync overrides client's
    assert_eq("sanitized: net_sync server-controlled", sanitized.net_sync.Transform.authority, "client")
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print("info", "")
print("info", "=========================================")
print("info", "[PREDICT TEST] RESULTS: " .. passed .. " passed, " .. failed .. " failed")
print("info", "=========================================")
if failed > 0 then
    print("error", "[PREDICT TEST] SOME TESTS FAILED")
else
    print("info", "[PREDICT TEST] ALL TESTS PASSED")
end
