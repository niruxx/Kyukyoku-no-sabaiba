-- modules/gltf_colliders/init.lua
-- Bake trimesh colliders from a GLB's geometry, opt-in by node-name marker.
--
-- Loads the GLB as a scene (SceneRoot), then queries for ALL entities with
-- Mesh3d + Name whose name contains the `include` marker. For each match,
-- calls Collider::from_bevy_mesh to build a static trimesh collider.
--
-- All orchestration lives here in Lua. The only Rust primitive is:
--   world:call_systemparam_method("Collider", "from_bevy_mesh", entity_id, "TriMesh")
-- which resolves the Mesh3d handle, builds the collider, and inserts it on the entity.
--
-- Usage:
--   spawn({
--       Transform = {},
--       mod = { ["gltf_colliders"] = { scene = "path/to/map.glb", include = "_col" } },
--   })

-- ─── One-shot setup: load the scene and spawn it ───────────────────────────────
register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "gltf_colliders" } })) do
        local cfg = entity:get("gltf_colliders") or {}
        if not cfg.scene then
            print("[GLTF_COLLIDERS] WARNING: missing 'scene' path in config")
            goto continue
        end

        local include = cfg.include or "_col"
        local scene_asset = load_asset(cfg.scene .. "#Scene0")

        -- Spawn the scene as a child; Bevy will populate it with Mesh3d + Name entities
        spawn({
            SceneRoot = scene_asset,
            Transform = {},
        }):with_parent(entity:id())

        -- Store pending state as a Lua component
        entity:set({
            _gltf_collider_pending = {
                include = include,
                scene = cfg.scene,
                done = false,
            },
        })

        print(string.format(
            "[GLTF_COLLIDERS] Spawned scene '%s', will look for '%s' nodes",
            cfg.scene, include))

        ::continue::
    end
    return true -- one-shot
end)

-- ─── Polling: flat-query for matching mesh entities each frame ─────────────────
register_system("Update", function(world)
    local pending_entities = world:query({ with = { "_gltf_collider_pending" } })
    if #pending_entities == 0 then return end

    for _, entity in ipairs(pending_entities) do
        local cfg = entity:get("_gltf_collider_pending")
        if not cfg or cfg.done then goto skip end

        -- Flat query: find all entities with Mesh3d + ChildOf (mesh primitives in scene)
        local mesh_entities = world:query({ with = { "Mesh3d", "ChildOf" } })

        local built = 0
        local still_pending = false

        for _, mesh_ent in ipairs(mesh_entities) do
            -- In Bevy's GLTF scene hierarchy:
            --   Node entity (Name = "Floor_col")     ← has the _col name
            --     └─ Mesh primitive (Mesh3d = ...)    ← has the actual mesh
            -- So check the PARENT's Name for the include filter.
            local parent_id = mesh_ent:get("ChildOf")
            if parent_id then
                local parent = world:get_entity(parent_id)
                local name_comp = parent and parent:get("Name")
                local name = name_comp and name_comp.name

                if name and string.find(name, cfg.include, 1, true) then
                    -- Only process if we haven't already built a collider on it
                    if not mesh_ent:has("Collider3d") then
                        local result = world:call_systemparam_method(
                            "Collider", "from_bevy_mesh", mesh_ent:id(), "TriMesh"
                        )
                        if result == true then
                            mesh_ent:set({ RigidBody3d = "Fixed" })
                            built = built + 1
                        elseif result == nil then
                            still_pending = true
                        end
                    else
                        built = built + 1
                    end
                end
            end
        end

        if built > 0 and not still_pending then
            -- All done — remove the pending marker
            entity:remove("_gltf_collider_pending")
            print(string.format(
                "[GLTF_COLLIDERS] Built %d trimesh collider(s) from '%s' (include='%s')",
                built, cfg.scene, cfg.include))
        end
        -- If still_pending or built == 0, retry next frame (scene not fully loaded yet)

        ::skip::
    end
end)
