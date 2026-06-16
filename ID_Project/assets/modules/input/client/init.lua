-- modules/input/client/init.lua
-- Client-side input: binding registry + hardware polling + sync group output.
--
-- Consumer mods patch their bindings onto the `input` component:
--   entity:patch({ input = { movement = { forward = { key = "KeyW", mode = "game" } } } })
--
-- Grouped actions (nested tables) produce auto-prefixed output components:
--   input.movement → input_movement = { forward = true, backward = false, ... }
--
-- Top-level actions (e.g. open_menu) are local-only (no output component).
--
-- input_mode: "game" (default) or "ui"
--   "game" → all "game" + "always" actions active, cursor confined+hidden
--   "ui"   → only "always" actions active, cursor visible+free
--
-- Multi-binding support:
--   An action can be a single binding or an array of bindings:
--     forward = { key = "KeyW", mode = "game" }                              -- single
--     forward = { { key = "KeyW", mode = "game" }, { vr = "left_stick_up" } } -- multi
--   For multi-bindings, the max value across all bindings is used.
--
-- VR binding types:
--   { vr = "a", mode = "game" }             -- button (event-driven)
--   { vr = "left_stick_up", mode = "game" } -- axis direction (0.0-1.0)
--   { vr = "right_trigger_value" }          -- raw analog (0.0-1.0)
--
-- Output values by action kind:
--   digital (key / mouse / VR button) → boolean (so `if input.x then` works)
--   analog (VR stick / *_value pressure) → number 0.0-1.0
--   mouse_motion / mouse_scroll → { dx, dy } table
-- A multi-binding is numeric if any of its bindings is analog, else boolean.
-- The local `input` component keeps per-action { pressed, just_pressed, value }
-- for consumers that need edge detection.

local input_state = define_resource("InputState", {
    pressed = {}, -- key -> boolean (true if pressed)
    mouse_pressed = {}, -- mouse button -> boolean (true if pressed)
    vr_pressed = {}, -- vr button name -> boolean (true if pressed)
    prev_pressed = {}, -- key -> boolean (last frame, for just_pressed)
    prev_mouse_pressed = {}, -- mouse button -> boolean (last frame)
    prev_vr_pressed = {}, -- vr button -> boolean (last frame)
    prev_output = {}, -- for change detection
    last_mode = {}, -- for cursor toggling
    warned_conflicts = {} -- for spam prevention
})

---------------------------------------------------------------------------
-- VR axis mapping: vr name → { resource_field, sign }
-- Maps named directions to VrButtonState resource fields
---------------------------------------------------------------------------

local VR_BUTTON_NAMES = {
    a = true, b = true, x = true, y = true,
    right_trigger = true, left_trigger = true,
    right_grip = true, left_grip = true,
}

local VR_AXIS_MAP = {
    left_stick_up     = { field = "left_thumbstick_y",  sign =  1 },
    left_stick_down   = { field = "left_thumbstick_y",  sign = -1 },
    left_stick_left   = { field = "left_thumbstick_x",  sign = -1 },
    left_stick_right  = { field = "left_thumbstick_x",  sign =  1 },
    right_stick_up    = { field = "right_thumbstick_y",  sign =  1 },
    right_stick_down  = { field = "right_thumbstick_y",  sign = -1 },
    right_stick_left  = { field = "right_thumbstick_x",  sign = -1 },
    right_stick_right = { field = "right_thumbstick_x", sign =  1 },
}

local VR_ANALOG_MAP = {
    right_trigger_value = "right_trigger",
    left_trigger_value  = "left_trigger",
    right_grip_value    = "right_grip",
    left_grip_value     = "left_grip",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Check if a value looks like a single action definition
local function is_single_action(v)
    if type(v) ~= "table" then return false end
    return v.key ~= nil or v.mouse ~= nil or v.type ~= nil or v.vr ~= nil or next(v) == nil
end

--- Check if a value is an array of action definitions (multi-binding)
local function is_multi_binding(v)
    if type(v) ~= "table" then return false end
    -- Check if first element is a table with binding keys
    local first = v[1]
    if first == nil then return false end
    return type(first) == "table" and is_single_action(first)
end

--- Check if a value is an action (single or multi-binding)
local function is_action(v)
    if type(v) ~= "table" then return false end
    return is_single_action(v) or is_multi_binding(v)
end

--- Check if a value is a sync group (table of actions)
local function is_sync_group(v)
    if type(v) ~= "table" then return false end
    for _, sub in pairs(v) do
        if is_action(sub) then return true end
    end
    return false
end

--- Shallow equality check for flat output tables
local function shallow_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if type(v) == "table" then
            -- For nested values (mouse delta), compare fields
            if type(b[k]) ~= "table" then return false end
            for k2, v2 in pairs(v) do
                if b[k][k2] ~= v2 then return false end
            end
            for k2, _ in pairs(b[k]) do
                if v[k2] == nil then return false end
            end
        else
            if b[k] ~= v then return false end
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Update: poll hardware, process bindings, write sync group outputs
---------------------------------------------------------------------------
register_system("Update", function(world)
    -- 0. Snapshot previous frame's pressed state for just_pressed detection
    local prev_keys = {}
    for k, v in pairs(input_state.pressed) do prev_keys[k] = v end
    input_state.prev_pressed = prev_keys
    local prev_mouse = {}
    for k, v in pairs(input_state.mouse_pressed) do prev_mouse[k] = v end
    input_state.prev_mouse_pressed = prev_mouse
    local prev_vr = {}
    for k, v in pairs(input_state.vr_pressed) do prev_vr[k] = v end
    input_state.prev_vr_pressed = prev_vr

    -- 1. Update held-key set from this frame's keyboard events
    local pressed_keys = input_state.pressed
    for _, evt in ipairs(world:read_events("KeyboardInput") or {}) do
        local key = evt.key_code
        if evt.state == "Pressed" then
            pressed_keys[key] = true
        elseif evt.state == "Released" then
            pressed_keys[key] = nil
        end
    end

    -- 1b. Update mouse button held state
    local pressed_mouse = input_state.mouse_pressed
    for _, evt in ipairs(world:read_events("MouseButtonInput") or {}) do
        local btn = evt.button
        if evt.state == "Pressed" then
            pressed_mouse[btn] = true
        elseif evt.state == "Released" then
            pressed_mouse[btn] = nil
        end
    end

    -- 1c. Update VR button held state (event-driven, like keyboard)
    local vr_pressed = input_state.vr_pressed
    for _, evt in ipairs(world:read_events("VrButtonInput") or {}) do
        local btn = evt.button
        if evt.state == "Pressed" then
            vr_pressed[btn] = true
        elseif evt.state == "Released" then
            vr_pressed[btn] = nil
        end
    end

    -- 1d. Read VR analog state from resource (for thumbsticks/trigger values)
    local vr_state = world:get_resource("VrButtonState")

    -- 2. Accumulate mouse motion for this frame
    local mouse_dx, mouse_dy = 0, 0
    for _, evt in ipairs(world:read_events("MouseMotion") or {}) do
        mouse_dx = mouse_dx + (evt.delta and evt.delta.x or 0)
        mouse_dy = mouse_dy + (evt.delta and evt.delta.y or 0)
    end

    -- 3. Accumulate mouse scroll for this frame
    local scroll_x, scroll_y = 0, 0
    for _, evt in ipairs(world:read_events("MouseWheel") or {}) do
        scroll_x = scroll_x + (evt.x or 0)
        scroll_y = scroll_y + (evt.y or 0)
    end

    -- 4. Process each entity with input
    local entities = world:query({ with = { "input", "net_local" } })
    for _, entity in ipairs(entities) do
        local input = entity:get("input")
        local input_mode = input.input_mode or "game"

        -- Detect input_mode changes → toggle CursorOptions
        local last_mode = input_state.last_mode[entity:id()]
        if last_mode ~= input_mode then
            input_state.last_mode[entity:id()] = input_mode
            local windows = world:query({ with = { "Window", "CursorOptions" } })
            if #windows > 0 then
                if input_mode == "ui" then
                    windows[1]:set({ CursorOptions = {
                        visible = true,
                        grab_mode = "None",
                    }})
                else
                    windows[1]:set({ CursorOptions = {
                        visible = false,
                        grab_mode = { Confined = true },
                    }})
                end
            end
        end

        -- Conflict detection: collect all keys across all groups + top-level
        local key_owners = {} -- key → "group.action" or "action"
        local function check_conflict(key, label)
            if key and key_owners[key] then
                local conflict_key = key .. ":" .. key_owners[key] .. ":" .. label
                if not input_state.warned_conflicts[conflict_key] then
                    print(string.format(
                        "[INPUT] WARNING: Key '%s' bound to both '%s' and '%s'",
                        key, key_owners[key], label))
                    input_state.warned_conflicts[conflict_key] = true
                end
            end
            if key then key_owners[key] = label end
        end

        -- Build new input state and sync group outputs
        local new_input = { input_mode = input_mode }

        -- Process a single action definition.
        -- Returns new_def, output_value, and kind:
        --   "digital" → button-like (key/mouse/VR button); output is boolean
        --   "analog"  → VR stick/trigger pressure; output is numeric 0.0-1.0
        --   "delta"   → mouse motion/scroll; output is a { dx, dy } table
        --   "unknown" → unrecognized/empty; output is nil (skipped)
        local function process_single_action(action, def, group_label)
            local action_mode = def.mode or "game"
            local active = (action_mode == "always") or (action_mode == input_mode)

            if def.key then
                -- Key binding
                check_conflict(def.key, group_label or action)
                local pressed = active and (pressed_keys[def.key] or false) or false
                local was_pressed = input_state.prev_pressed[def.key] or false
                local just = pressed and not was_pressed
                local value = pressed and 1.0 or 0.0
                return {
                    key = def.key,
                    mode = def.mode,
                    pressed = pressed,
                    just_pressed = just,
                    value = value,
                }, value, "digital"

            elseif def.mouse then
                -- Mouse button binding
                local btn = def.mouse
                check_conflict("Mouse:" .. btn, group_label or action)
                local pressed = active and (pressed_mouse[btn] or false) or false
                local was_pressed = input_state.prev_mouse_pressed[btn] or false
                local just = pressed and not was_pressed
                local value = pressed and 1.0 or 0.0
                return {
                    mouse = btn,
                    mode = def.mode,
                    pressed = pressed,
                    just_pressed = just,
                    value = value,
                }, value, "digital"

            elseif def.vr then
                -- VR binding
                local vr_name = def.vr
                check_conflict("VR:" .. vr_name, group_label or action)

                if VR_BUTTON_NAMES[vr_name] then
                    -- Event-driven button
                    local pressed = active and (vr_pressed[vr_name] or false) or false
                    local was_pressed = input_state.prev_vr_pressed[vr_name] or false
                    local just = pressed and not was_pressed
                    local value = pressed and 1.0 or 0.0
                    return {
                        vr = vr_name,
                        mode = def.mode,
                        pressed = pressed,
                        just_pressed = just,
                        value = value,
                    }, value, "digital"

                elseif VR_AXIS_MAP[vr_name] then
                    -- Axis direction (resource-polled)
                    local axis = VR_AXIS_MAP[vr_name]
                    local raw = 0
                    if active and vr_state then
                        raw = vr_state[axis.field] or 0
                    end
                    -- Apply sign: e.g. "left_stick_up" uses positive Y, clamp to 0-1
                    local value = math.max(0, raw * axis.sign)
                    return {
                        vr = vr_name,
                        mode = def.mode,
                        value = value,
                        pressed = value > 0.1, -- deadzone for "pressed" state
                        just_pressed = false,   -- axes don't have edges
                    }, value, "analog"

                elseif VR_ANALOG_MAP[vr_name] then
                    -- Raw analog value (resource-polled)
                    local field = VR_ANALOG_MAP[vr_name]
                    local value = 0
                    if active and vr_state then
                        value = vr_state[field] or 0
                    end
                    return {
                        vr = vr_name,
                        mode = def.mode,
                        value = value,
                        pressed = value > 0.1,
                        just_pressed = false,
                    }, value, "analog"

                else
                    -- Unknown VR binding
                    return def, 0, "digital"
                end

            elseif def.type == "mouse_motion" then
                -- Mouse motion
                local dx = active and mouse_dx or 0
                local dy = active and mouse_dy or 0
                local delta = { dx = dx, dy = dy }
                return {
                    type = "mouse_motion",
                    mode = def.mode,
                    dx = dx,
                    dy = dy,
                }, delta, "delta"

            elseif def.type == "mouse_scroll" then
                -- Mouse scroll
                local dx = active and scroll_x or 0
                local dy = active and scroll_y or 0
                local delta = { dx = dx, dy = dy }
                return {
                    type = "mouse_scroll",
                    mode = def.mode,
                    dx = dx,
                    dy = dy,
                }, delta, "delta"

            else
                -- Unknown/empty action definition, pass through
                return def, nil, "unknown"
            end
        end

        -- Process an action (single or multi-binding).
        -- Returns new_def (or array of defs) and the output value:
        --   digital actions → boolean, analog actions → number, deltas → { dx, dy }.
        local function process_action(action, def, group_label)
            if is_multi_binding(def) then
                -- Multi-binding: take max numeric value across bindings; the output is
                -- numeric if any bound source is analog, else boolean (any pressed).
                local best_value = 0
                local best_def = nil
                local all_defs = {}
                local any_just_pressed = false
                local any_pressed = false
                local any_analog = false

                for _, sub_def in ipairs(def) do
                    local new_def, out_val, kind = process_single_action(action, sub_def, group_label)
                    all_defs[#all_defs + 1] = new_def

                    -- Track aggregate state
                    if kind == "analog" then any_analog = true end
                    if new_def.just_pressed then any_just_pressed = true end
                    if new_def.pressed then any_pressed = true end

                    -- For numeric values, take max
                    local num_val = 0
                    if type(out_val) == "number" then
                        num_val = out_val
                    elseif type(out_val) == "boolean" then
                        num_val = out_val and 1.0 or 0.0
                    end
                    if num_val > best_value then
                        best_value = num_val
                        best_def = new_def
                    end
                end

                -- Merge aggregate pressed/just_pressed into the best def (for input component)
                if best_def then
                    best_def.pressed = any_pressed
                    best_def.just_pressed = any_just_pressed
                    best_def.value = best_value
                end

                if any_analog then
                    return all_defs, best_value   -- numeric (proportional)
                else
                    return all_defs, any_pressed  -- boolean
                end
            else
                -- Single binding
                local new_def, out_val, kind = process_single_action(action, def, group_label)
                if out_val == nil then
                    return new_def, nil
                elseif kind == "delta" then
                    return new_def, out_val                 -- { dx, dy } table
                elseif kind == "analog" then
                    return new_def, (type(out_val) == "number" and out_val) or 0.0
                else
                    -- digital → boolean
                    if type(out_val) == "boolean" then return new_def, out_val end
                    return new_def, (type(out_val) == "number" and out_val > 0) or false
                end
            end
        end

        -- Walk top-level keys
        for name, entry in pairs(input) do
            if name == "input_mode" then
                -- Already handled
            elseif is_sync_group(entry) then
                -- Sync group: process each action inside
                local new_group = {}
                local output = {}
                local has_output = false

                for action, def in pairs(entry) do
                    if is_action(def) then
                        local new_def, out_val = process_action(
                            action, def, name .. "." .. action)
                        new_group[action] = new_def
                        if out_val ~= nil then
                            output[action] = out_val
                            has_output = true
                        end
                    end
                end

                new_input[name] = new_group

                -- Write output component (auto-prefixed with input_)
                if has_output then
                    local comp_name = "input_" .. name
                    local eid = entity:id()
                    input_state.prev_output[eid] = input_state.prev_output[eid] or {}

                    if not shallow_equal(output, input_state.prev_output[eid][name]) then
                        entity:set({ [comp_name] = output })
                        input_state.prev_output[eid][name] = output
                    end
                end

            elseif is_action(entry) then
                -- Top-level action (local only, no output component)
                local new_def, _ = process_action(name, entry, nil)
                new_input[name] = new_def
            else
                -- Unknown entry, preserve
                new_input[name] = entry
            end
        end

        -- Write updated input component
        entity:patch({ input = new_input })
    end
end, { label = "Input" })
