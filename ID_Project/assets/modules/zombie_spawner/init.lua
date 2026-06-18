-- modules/zombie_spawner/init.lua
-- Horde spawner: periodically spawns waves of zombies around the map perimeter.
-- Loaded server-side via plain `mod` (not net_mod) — spawns entities that are
-- individually net_sync'd to clients through the zombie net_mod.

local MIN_INTERVAL   = 12.0   -- seconds between waves (minimum)
local MAX_INTERVAL   = 25.0   -- seconds between waves (maximum)
local BASE_HORDE     = 5      -- zombies in wave 1
local MAX_HORDE      = 30     -- cap per wave
local SPAWN_RING_MIN = 480    -- inner spawn ring radius (px)
local SPAWN_RING_MAX = 560    -- outer spawn ring radius (px)
local ZOMBIE_HP      = 3
local ZOMBIE_SPEED   = 55

local state = define_resource("ZombieSpawnerState", {
    elapsed    = 0,
    next_spawn = 8.0,  -- first horde arrives 8 s after game start
    wave       = 0,
})

---------------------------------------------------------------------------
-- Deterministic-ish seed using elapsed time bucket (no os.time dependency)
---------------------------------------------------------------------------
local seed_set = false

local function random_angle()
    return math.random() * 2 * math.pi
end

local function spawn_zombie(x, y)
    spawn({
        Transform      = { translation = { x = x, y = y, z = 0 } },
        RigidBody2d    = "KinematicVelocityBased",
        Collider2d     = { ball = { radius = 12.0 } },
        LockedAxes2d   = "ROTATION_LOCKED",
        Velocity2d     = { linvel = { x = 0, y = 0 }, angvel = 0 },
        GravityScale2d = 0.0,
        zombie         = { hp = ZOMBIE_HP, speed = ZOMBIE_SPEED, damage = 8 },
        net_sync       = {
            Transform  = { authority = "server", reliable = false },
            Velocity2d = { authority = "server", reliable = false },
            zombie     = { authority = "server" },
        },
        net_mod = { ["zombie"] = {} },
    })
end

---------------------------------------------------------------------------
-- Wave spawning loop
---------------------------------------------------------------------------
register_system("Update", function(world)
    local dt = world:delta_time()
    state.elapsed = state.elapsed + dt

    -- Seed math.random once we have a non-trivial elapsed time
    if not seed_set and state.elapsed > 0.1 then
        math.randomseed(math.floor(state.elapsed * 1000))
        seed_set = true
    end

    if state.elapsed < state.next_spawn then return end

    state.wave = state.wave + 1

    -- Horde size grows each wave, capped at MAX_HORDE
    local horde_size = math.min(BASE_HORDE + math.floor(state.wave * 1.8), MAX_HORDE)

    print(string.format("[ZOMBIE_SPAWNER] *** WAVE %d *** spawning %d zombies", state.wave, horde_size))

    for _ = 1, horde_size do
        local angle = random_angle()
        local r     = SPAWN_RING_MIN + math.random() * (SPAWN_RING_MAX - SPAWN_RING_MIN)
        local sx    = math.cos(angle) * r
        local sy    = math.sin(angle) * r
        spawn_zombie(sx, sy)
    end

    -- Schedule next wave (random interval, waves get slightly faster over time)
    local scale    = math.max(0.6, 1.0 - state.wave * 0.02)
    local interval = (MIN_INTERVAL + math.random() * (MAX_INTERVAL - MIN_INTERVAL)) * scale
    state.next_spawn = state.elapsed + interval

    print(string.format("[ZOMBIE_SPAWNER] Next wave in %.1f s", interval))
end)
