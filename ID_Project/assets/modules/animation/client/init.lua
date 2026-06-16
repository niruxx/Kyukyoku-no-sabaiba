-- modules/animation/client/init.lua
-- Client-side animation: loads model + clips, builds AnimationGraph, plays animations.
-- AnimationGraphs are cached by model prefix so players sharing the same model reuse one graph.
-- Clips can be updated at runtime (e.g. ability grants new animation clips).
--
-- KEY DESIGN: The GLB scene spawner creates an AnimationPlayer on a child entity
-- (the armature root).  AnimationTarget components on bones reference THAT player.
-- We must attach our AnimationGraphHandle + AnimationTransitions to that
-- scene-spawned player entity, NOT to the SceneRoot entity.

local cache = define_resource("AnimationCache", {
    graphs = {},  -- model_prefix → { graph_handle, node_indices = { state → node_index } }
})

---------------------------------------------------------------------------
-- Init: load model + clips, build/reuse AnimationGraph, spawn model child
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "animation" } })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation")
        if not anim or not anim.model then
            print(string.format("[ANIMATION/CLIENT] WARNING: entity %d has no model", entity:id()))
            goto continue
        end

        local model_prefix = anim.model
        local clips = anim.clips or {}

        -- Build or reuse AnimationGraph
        local cached = cache.graphs[model_prefix]
        if not cached then
            -- Load idle clip first (base for AnimationGraph)
            local idle_suffix = clips.idle or "-Idle.glb#Animation0"
            local idle_handle = load_asset(model_prefix .. idle_suffix)

            -- Create AnimationGraph from idle clip.
            -- from_clip puts the root at node 0 and the clip at node 1.
            local graph_handle = create_asset("AnimationGraph", {
                clip = idle_handle,
            })
            local node_indices = {}
            node_indices["idle"] = 1

            -- Add remaining clips as children of the root (node 0).
            local node_idx = 2
            for state_name, suffix in pairs(clips) do
                if state_name ~= "idle" then
                    local clip_handle = load_asset(model_prefix .. suffix)
                    world:call_asset_method(graph_handle, "AnimationGraph", "add_clip", clip_handle, 1.0, 0)
                    node_indices[state_name] = node_idx
                    node_idx = node_idx + 1
                end
            end

            cached = {
                graph_handle = graph_handle,
                node_indices = node_indices,
            }
            cache.graphs[model_prefix] = cached
            print(string.format("[ANIMATION/CLIENT] Built AnimationGraph for '%s' (%d clips)",
                model_prefix, node_idx - 1))
        end

        -- Spawn model child entity with ONLY SceneRoot + Transform.
        -- Do NOT add AnimationPlayer/AnimationTransitions/AnimationGraphHandle here;
        -- the scene spawner will create a child entity with AnimationPlayer, and
        -- we need to attach our graph to THAT entity (see link system below).
        local scene_suffix = anim.scene or "-Idle.glb#Scene0"
        local scene_handle = load_asset(model_prefix .. scene_suffix)
        local model_entity = spawn({
            SceneRoot = scene_handle,
            Transform = {
                translation = { x = 0, y = -0.9, z = 0 },
            },
        }):with_parent(entity:id())

        -- Store model entity id; _player_entity_id will be set by the link system
        entity:patch({ animation = {
            model_entity_id = model_entity:id(),
            _player_entity_id = null,
            _last_state = null,
        }})

        print(string.format("[ANIMATION/CLIENT] Model spawned for entity %d (model=%s)",
            entity:id(), model_prefix))

        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Link: detect scene-spawned AnimationPlayer and attach graph + transitions
---------------------------------------------------------------------------
register_system("First", function(world)
    -- Find newly added AnimationPlayers (created by scene spawner)
    local players = world:query({ added = { "AnimationPlayer" }, with = { "ChildOf" } })
    for _, player_entity in ipairs(players) do
        -- Walk up the hierarchy to find the animation entity:
        --   bone → armature (AnimationPlayer) → model_entity (SceneRoot) → anim_entity (animation)
        local current_id = player_entity:get("ChildOf")
        local anim_entity = nil
        local depth = 0
        while current_id and depth < 5 do
            local parent = world:get_entity(current_id)
            if not parent then break end
            if parent:has("animation") then
                anim_entity = parent
                break
            end
            current_id = parent:get("ChildOf")
            depth = depth + 1
        end

        if not anim_entity then goto skip end

        local anim = anim_entity:get("animation")
        if not anim or not anim.model then goto skip end

        -- Skip if already linked
        if anim._player_entity_id then goto skip end

        local cached = cache.graphs[anim.model]
        if not cached then goto skip end

        -- Attach AnimationGraphHandle + AnimationTransitions to the scene-spawned player
        player_entity:set({
            AnimationGraphHandle = cached.graph_handle,
            AnimationTransitions = {},
        })

        -- Store the actual player entity ID for the playback system
        anim_entity:patch({ animation = {
            _player_entity_id = player_entity:id(),
        }})

        print(string.format("[ANIMATION/CLIENT] Linked AnimationPlayer %d to entity %d (model=%s)",
            player_entity:id(), anim_entity:id(), anim.model))

        ::skip::
    end
end)

---------------------------------------------------------------------------
-- Clip updates: when clips change at runtime, extend the AnimationGraph
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ changed = { "animation" } })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation")
        if not anim or not anim.model or not anim.clips then goto continue end

        local cached = cache.graphs[anim.model]
        if not cached then goto continue end

        -- Check for new clips not in the cached graph
        for state_name, suffix in pairs(anim.clips) do
            if not cached.node_indices[state_name] then
                local clip_handle = load_asset(anim.model .. suffix)
                world:call_asset_method(cached.graph_handle, "AnimationGraph", "add_clip", clip_handle, 1.0, 0)
                local next_idx = 1
                for _ in pairs(cached.node_indices) do next_idx = next_idx + 1 end
                cached.node_indices[state_name] = next_idx
                print(string.format("[ANIMATION/CLIENT] Added clip '%s' to graph '%s' (node=%d)",
                    state_name, anim.model, next_idx))
            end
        end

        ::continue::
    end
end)

---------------------------------------------------------------------------
-- Playback: when animation.state changes, transition to the new animation
---------------------------------------------------------------------------
register_system("Update", function(world)
    local entities = world:query({
        changed = { "animation" },
    })
    for _, entity in ipairs(entities) do
        local anim = entity:get("animation")
        if not anim or not anim.state or not anim.model then goto continue end

        -- Skip if state hasn't actually changed
        if anim._last_state == anim.state then goto continue end

        local cached = cache.graphs[anim.model]
        if not cached then goto continue end

        local node_index = cached.node_indices[anim.state]
        if not node_index then
            -- Fallback to idle
            node_index = cached.node_indices["idle"] or 0
        end

        -- Use the scene-spawned player entity (linked by the link system)
        local player_eid = anim._player_entity_id
        if not player_eid then goto continue end

        -- Transition to the new animation. AnimationTransitions::play drives the
        -- sibling AnimationPlayer; speed/repeat are applied via the options table.
        local speed = anim.speed or 1.0
        world:call_component_method(player_eid, "AnimationTransitions", "play",
            node_index, 0.2, { speed = speed, ["repeat"] = true })

        -- Track last state to avoid re-triggering
        entity:patch({ animation = { _last_state = anim.state } })

        ::continue::
    end
end, { label = "Animation", after = { "Movement" } })
