-- modules/net/client/predict.lua
-- Generic client-side prediction + replay reconciliation (required by net/client/init.lua,
-- runs in the client net scope).
--
-- Opt-in is declarative and decoupled — no callbacks, no per-consumer code here:
--   net_sync = { Transform = { authority = "server", reliable = false, predict = true } }
-- An entity whose net_sync flags a component with `predict = true` is predicted on the
-- OWNER (net_local) only. The velocity source is conventional: Velocity3d (else Velocity2d).
--
-- Each frame the predicted component's translation is integrated forward from that velocity
-- (instant local response) and the velocity is buffered. When a fresh server snapshot lands
-- (net_sync_<State>), the translation is snapped to it and the un-acknowledged velocities
-- (the last ~RTT seconds) are replayed on top. The consumer (e.g. movement) only writes the
-- velocity component; it never references this file.

local Net = require("modules/net/shared/net.lua")

local HISTORY_SECONDS = 0.6     -- velocity history retained (> RTT_MAX so the window is covered)
local MAX_REPLAY_TIME = 0.5     -- cap replay integration per reconcile
local CORRECT_FACTOR  = 0.5     -- how strongly a snapshot re-anchors the predicted position
local RTT_MIN, RTT_MAX = 0.0, 0.5
local RTT_DEFAULT     = 0.1
local RTT_SMOOTH      = 0.1     -- EMA weight for new RTT samples
local PING_INTERVAL   = 0.25    -- seconds between RTT pings (~4 Hz)

local pstate = define_resource("NetPredictState", {
    clock = 0.0,
    rtt = RTT_DEFAULT,
    last_ping = -1.0,
    hist = {},      -- eid -> array of { t, vx, vy, vz, dt }
    seeded = {},    -- eid -> true once the first snapshot has been adopted
})

-- RTT_PONG echoes the timestamp we sent; sample = now - that timestamp (full round trip).
Net.register_handler(Net.MSG.RTT_PONG, function(world, msg)
    local t = msg and msg.t
    if type(t) ~= "number" then return end
    local sample = pstate.clock - t
    if sample < RTT_MIN then sample = RTT_MIN end
    if sample > RTT_MAX then sample = RTT_MAX end
    pstate.rtt = pstate.rtt + RTT_SMOOTH * (sample - pstate.rtt)
end)

--- Which net_sync component (if any) is flagged for prediction. Returns its name or nil.
local function predicted_state_comp(entity)
    local ns = entity:get("net_sync")
    if type(ns) ~= "table" then return nil end
    for comp_name, cfg in pairs(ns) do
        if type(cfg) == "table" and cfg.predict then
            return comp_name
        end
    end
    return nil
end

--- Conventional velocity vector for an entity: Velocity3d, else Velocity2d.
local function get_linvel(entity)
    local v = entity:get("Velocity3d")
    if v and v.linvel then return v.linvel end
    local v2 = entity:get("Velocity2d")
    if v2 and v2.linvel then return v2.linvel end
    return nil
end

local function trim_history(h, now)
    local cutoff = now - HISTORY_SECONDS
    while #h > 0 and h[1].t < cutoff do
        table.remove(h, 1)
    end
end

---------------------------------------------------------------------------
-- NetPredictTick: forward-integrate predicted translation from velocity,
-- buffer the per-frame velocity, and probe RTT periodically.
-- Runs after the consumer writes its velocity (e.g. movement's "Movement").
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    pstate.clock = pstate.clock + dt

    -- Periodic RTT ping (net:send → NetSend forwards to the server, which echoes RTT_PONG).
    if pstate.clock - pstate.last_ping >= PING_INTERVAL then
        pstate.last_ping = pstate.clock
        world:write_event("net:send", { msg_type = Net.MSG.RTT_PING, t = pstate.clock })
    end

    for _, entity in ipairs(world:query({
        with = { "net_local", "net_sync", "Transform" },
        optional = { "Velocity3d", "Velocity2d" },
    })) do
        local state_comp = predicted_state_comp(entity)
        if not state_comp then goto continue end

        local linvel = get_linvel(entity)
        if not linvel then goto continue end

        local cur = entity:get(state_comp)
        if not cur or not cur.translation then goto continue end

        local vx, vy, vz = linvel.x or 0, linvel.y or 0, linvel.z or 0

        -- Only integrate velocity into Transform when Rapier is disabled.
        -- When Rapier is active (no RigidBodyDisabled3d), it handles
        -- velocity → position integration with proper collision detection.
        if entity:get("RigidBodyDisabled3d") then
            entity:patch({ [state_comp] = { translation = {
                x = cur.translation.x + vx * dt,
                y = cur.translation.y + vy * dt,
                z = cur.translation.z + vz * dt,
            } } })
        end

        -- Always buffer velocity history (needed for reconciliation replay)
        local eid = entity:id()
        local h = pstate.hist[eid]
        if not h then h = {}; pstate.hist[eid] = h end
        h[#h + 1] = { t = pstate.clock, vx = vx, vy = vy, vz = vz, dt = dt }
        trim_history(h, pstate.clock)

        ::continue::
    end
end, { label = "NetPredictTick", after = { "Movement", "Input" } })

---------------------------------------------------------------------------
-- NetPredictReconcile: on a fresh server snapshot, snap to it and replay the
-- un-acknowledged velocities (last ~RTT seconds) so prediction stays ahead.
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, entity in ipairs(world:query({
        with = { "net_local", "net_sync", "Transform" },
        optional = { "net_sync_Transform" },
    })) do
        local state_comp = predicted_state_comp(entity)
        if not state_comp then goto continue end

        local shadow_name = "net_sync_" .. state_comp
        local shadow = entity:get(shadow_name)
        if not shadow or not shadow.translation then goto continue end

        local cur = entity:get(state_comp)
        if not cur or not cur.translation then goto continue end

        local eid = entity:id()

        -- Seed on the first snapshot: adopt the server position, no replay.
        if not pstate.seeded[eid] then
            entity:patch({ [state_comp] = { translation = {
                x = shadow.translation.x, y = shadow.translation.y, z = shadow.translation.z,
            } } })
            pstate.hist[eid] = {}
            pstate.seeded[eid] = true
            goto continue
        end

        -- Re-anchor only when a new snapshot actually arrived this frame.
        if not entity:is_changed(shadow_name) then goto continue end

        -- Replay the un-acked velocity window from the authoritative base.
        local window_start = pstate.clock - pstate.rtt
        local px, py, pz = shadow.translation.x, shadow.translation.y, shadow.translation.z
        local replayed = 0.0
        local h = pstate.hist[eid] or {}
        for i = 1, #h do
            local e = h[i]
            if e.t >= window_start and replayed < MAX_REPLAY_TIME then
                px = px + e.vx * e.dt
                py = py + e.vy * e.dt
                pz = pz + e.vz * e.dt
                replayed = replayed + e.dt
            end
        end

        -- Blend the predicted translation toward the replayed target (smooth correction).
        local f = CORRECT_FACTOR
        entity:patch({ [state_comp] = { translation = {
            x = cur.translation.x + (px - cur.translation.x) * f,
            y = cur.translation.y + (py - cur.translation.y) * f,
            z = cur.translation.z + (pz - cur.translation.z) * f,
        } } })

        ::continue::
    end
end, { label = "NetPredictReconcile", after = { "NetPredictTick" } })
