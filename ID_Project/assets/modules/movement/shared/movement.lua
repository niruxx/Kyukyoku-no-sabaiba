-- modules/movement/shared/movement.lua
-- Shared movement computation used by both client (prediction) and server (authoritative).
-- Returns the desired world-space velocity vector from input_movement + camera yaw.

local M = {}

M.MOVE_SPEED = 6.0
M.JUMP_FORCE = 5.0
M.ROT_SPEED = 10.0

-- Minimum time between jumps (prevents double-jump at launch)
M.JUMP_COOLDOWN = 0.3

-- Ground detection: raycast distance below entity origin.
-- Must be >= distance from entity origin to bottom of collider + skin margin.
-- Player capsule: half_height=0.5 + radius=0.4 = 0.9 from origin to feet.
M.GROUND_RAY_DISTANCE = 1.0

--- Normalize an input value to a number (0.0-1.0).
--- Handles both boolean (old) and numeric (new) input formats.
local function input_value(v)
    if v == true then return 1.0 end
    if type(v) == "number" then return v end
    return 0.0
end

--- Compute desired world-space horizontal velocity from input_movement and camera yaw.
--- @param world  ECS world (for static method calls)
--- @param input  input_movement table { forward, backward, left, right } (values are 0.0-1.0 or boolean)
--- @param camera_yaw  camera yaw angle in radians
--- @param speed  movement speed
--- @return table { x, y, z } desired velocity direction (normalized) * speed
function M.compute_velocity(world, input, camera_yaw, speed)
    -- Build raw input vector from input values (supports analog 0.0-1.0)
    local raw_x = input_value(input.right) - input_value(input.left)
    local raw_z = input_value(input.backward) - input_value(input.forward)

    -- Normalize input
    local input_vec = world:call_static_method("Vec3", "normalize_or_zero",
        { x = raw_x, y = 0, z = raw_z })

    -- Scale by max input magnitude for analog proportional speed
    local mag = math.sqrt(raw_x * raw_x + raw_z * raw_z)
    if mag > 1.0 then mag = 1.0 end -- Clamp diagonal

    -- Rotate by camera yaw
    local yaw_quat = world:call_static_method("Quat", "from_rotation_y", camera_yaw)
    local dir = world:call_static_method("Quat", "mul_vec3", yaw_quat, input_vec)

    return {
        x = dir.x * speed * mag,
        y = 0,
        z = dir.z * speed * mag,
    }
end

--- Compute desired top-down 2D velocity from input_movement.
--- @param input  input_movement table { forward, backward, left, right }
--- @param speed  movement speed
--- @return table { x, y } desired velocity direction (normalized) * speed
function M.compute_velocity2d(input, speed)
    local raw_x = input_value(input.right) - input_value(input.left)
    local raw_y = input_value(input.forward) - input_value(input.backward)

    local len = math.sqrt(raw_x * raw_x + raw_y * raw_y)
    local mag = len
    if mag > 1.0 then mag = 1.0 end
    if len > 0 then
        raw_x = raw_x / len
        raw_y = raw_y / len
    end

    return {
        x = raw_x * speed * mag,
        y = raw_y * speed * mag,
    }
end

--- Compute target rotation quaternion from horizontal velocity.
--- Returns nil if velocity is too small.
--- @param world  ECS world (for static method calls)
--- @param vx  horizontal velocity X
--- @param vz  horizontal velocity Z
--- @return table|nil  target rotation quaternion, or nil if stationary
function M.compute_rotation(world, vx, vz)
    if math.abs(vx) + math.abs(vz) <= 0.01 then return nil end
    return world:call_static_method("Quat", "from_rotation_y", math.atan2(vx, vz))
end

--- Compute target rotation quaternion for a 2D sprite/body facing velocity.
--- Returns nil if velocity is too small.
function M.compute_rotation2d(world, vx, vy)
    if math.abs(vx) + math.abs(vy) <= 0.01 then return nil end
    return world:call_static_method("Quat", "from_rotation_z", math.atan2(vy, vx) - (math.pi * 0.5))
end

--- Check if the entity is grounded using a Rapier downward raycast.
--- Casts a short ray downward from the entity's position to detect ground.
--- @param world  ECS world (for call_systemparam_method)
--- @param entity  the entity to check (used to get position and exclude from raycast)
--- @param mv  movement component data (contains last_jump_time)
--- @param world_time  current world time
--- @return boolean  true if the entity is considered grounded
function M.is_grounded(world, entity, mv, world_time)
    -- Must have waited long enough since last jump (prevents grounding at launch)
    local last_jump = mv.last_jump_time or 0
    if (world_time - last_jump) < M.JUMP_COOLDOWN then
        return false
    end

    -- Get entity position for ray origin
    local transform = entity:get("Transform")
    if not transform or not transform.translation then
        return false
    end
    local pos = transform.translation

    -- Cast a short ray downward from the entity's feet
    local ray_origin = { x = pos.x, y = pos.y, z = pos.z }
    local ray_dir = { x = 0, y = -1, z = 0 }

    local ok, hit = pcall(
        world.call_systemparam_method, world,
        "ReadRapierContext3d", "cast_ray",
        ray_origin,  -- origin (Vect/Vec3)
        ray_dir,     -- direction (Vect/Vec3)
        M.GROUND_RAY_DISTANCE, -- max_toi (Real/f32)
        true         -- solid
        -- QueryFilter defaults (no filter = hit anything)
    )

    if not ok then
        -- Raycast failed (e.g., rapier not ready) — fall back to false
        return false
    end

    -- hit is Option<(Entity, f32)> — nil if nothing hit, {entity, toi} if ground found
    return hit ~= nil
end

return M
