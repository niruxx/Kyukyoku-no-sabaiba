-- modules/git/scope/portal/client/init.lua
-- Portal client-side: activation, camera config, stencil rendering.
--
-- Uses the other scope's EXISTING camera (from CameraRegistry) instead of
-- spawning a separate portal camera. Configures stencil properties on it
-- when the portal is active.

local Portal = require("modules/git/scope/portal/shared/init.lua")
local Net = require("modules/net/shared/net.lua")

local state = define_resource("PortalState", {
    --- Each portal must have a unique ref so multiple portals don't conflict
    next_stencil_ref = 0,
    --- Track which portal entities have been initialized (prevents re-entry)
    initialized_portals = {},
})

function state.alloc_stencil()
    local s = state.next_stencil_ref
    state.next_stencil_ref = (s % 255) + 1
    return s
end

---------------------------------------------------------------------------
-- System: PortalMeshInit — spawn portal mesh when placed
---------------------------------------------------------------------------
register_system("First", function(world)
    local entities = world:query({ added = { "git/scope/portal", "placement" }})
    for _, entity in ipairs(entities) do
        entity:patch({
            Mesh3d = create_asset("bevy_mesh::mesh::Mesh", {
                primitive = { Sphere = { radius = 1.2 } },
            }),
            ["MeshMaterial3d<StandardMaterial>"] = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
                base_color = { r = 1.0, g = 0.3, b = 0.1, a = 1.0 },
                emissive = { r = 2.0, g = 0.5, b = 0.1, a = 1.0 },
            }),
        })
        print(string.format("[PORTAL] Placed portal mesh"))
    end

    local entities = world:query({
        added = { "git/scope/portal", "placement" },
        without = { "net_peer_mirror" },
    })
    for _, entity in ipairs(entities) do
        entity:patch({
            ["MeshMaterial3d<StandardMaterial>"] = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
                base_color = { r = 1.0, g = 0.3, b = 0.1, a = 1.0 },
                emissive = { r = 2.0, g = 0.5, b = 0.1, a = 1.0 },
            })
        })
        print(string.format("[PORTAL] Placed portal mesh"))
    end
end)

---------------------------------------------------------------------------
-- System: PortalInit — determine target scope from symmetric config
-- Fires when the SERVER patches the portal config (adding ports, ids).
-- The server does this on placement confirmed, then net_sync sends the
-- update to clients. State-level guard prevents re-entry.
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({
        changed = { "git/scope/portal" },
    })) do
        if not world:get_entity(entity:id()) then goto continue end
        -- State-level guard: only initialize each portal once
        if state.initialized_portals[entity:id()] then goto continue end

        local cfg = entity:get("git/scope/portal")
        if not cfg.scope_a or not cfg.scope_a.port or not cfg.scope_b or not cfg.scope_b.port then goto continue end -- Not ready yet

        local net_info = define_resource("NetInfo", {})
        local my_scope_key = net_info.scope_key

        -- Determine which side of the portal is the "other" side.
        local source_scope, target_scope
        if my_scope_key == cfg.scope_a.name then
            source_scope = cfg.scope_a
            target_scope = cfg.scope_b
        elseif my_scope_key == cfg.scope_b.name then
            source_scope = cfg.scope_b
            target_scope = cfg.scope_a
        else
            goto continue
        end

        if not source_scope or not target_scope then goto continue end

        -- Mark as initialized BEFORE spawning to prevent re-entry
        state.initialized_portals[entity:id()] = true

        -- Spawn client game for the target scope (each client connects independently).
        -- observer = true tells the target server not to spawn a player for us;
        -- our player will arrive via net_peer authority switch instead.
        spawn({
            game = {
                mode = "client",
                port = target_scope.port,
                scope_key = target_scope.name,
                observer = true,
            },
            ScopeWorld = "All",
        })
        print(string.format("[PORTAL/CLIENT] Spawning observer client for scope '%s' on port %d",
            target_scope.name, target_scope.port))

        local scope_layers = define_resource("ScopeRenderLayers", {})
        local target_layer = scope_layers.get_or_allocate and scope_layers.get_or_allocate(target_scope_id)

        local sr = state.alloc_stencil()

        -- Patch client-only rendering fields onto portal config.
        -- This triggers changed, but target_scope.name will now be set,
        -- so the guard above prevents re-entry.
        entity:patch({
            ScriptOwned = {
                instance_id = null,
            },
            ScopeStencil = {
                scope_a = cfg.scope_a_id or 0,
                scope_b = cfg.scope_b_id or 0,
                stencil_ref = sr,
                active = false, -- TODO: Make false by default
            },
            -- Store portal rendering metadata in the Lua component
            -- (target_scope_key and target_layer are Lua-only, not in ScopeStencil Rust struct)
            ["git/scope/portal"] = {
                target_scope_key = target_scope.name,
                target_scope_id = target_scope.id,
                target_layer = target_layer,
                stencil_ref = sr,
            },
            ScopeStencil = {
                scope_a = source_scope.id,
                scope_b = target_scope.id,
                stencil_ref = sr,
                active = false,
            },
        })

        print(string.format("[PORTAL/CLIENT] PortalInit: my_scope=%s, target=%s (port=%s, layer=%s, stencil_ref=%d)",
            tostring(my_scope_key), target_scope_key, tostring(target_port), tostring(target_layer), sr))

        ::continue::
    end
end, { label = "PortalInit" })

---------------------------------------------------------------------------
-- System: PortalCameraConfig — configure other scope's camera with stencil
-- When portal activates/deactivates, toggle stencil properties on the
-- target scope's existing camera (from CameraRegistry).
---------------------------------------------------------------------------
register_system("Update", function(world)
    for _, portal in ipairs(world:query({
        changed = { "ScopeStencil" },
        with = { "git/scope/portal" },
    })) do
        local stencil = portal:get("ScopeStencil")
        local cfg = portal:get("git/scope/portal")

        local camera_registry = define_resource("CameraRegistry", {})
        local net_info = define_resource("NetInfo", {})

        -- Our camera (for SharedDepthFrom reference)
        local my_cam_id = camera_registry[net_info.scope_key]
        -- The "portal camera" is the other scope's main camera
        local target_cam_id = camera_registry[cfg.target_scope_key]

        if not target_cam_id or not my_cam_id then goto continue end

        local target_cam = world:get_entity(target_cam_id)
        if not target_cam then goto continue end

        if stencil.active then
            local sr = stencil.stencil_ref or 1
            -- Configure target scope's camera as portal camera
            target_cam:patch({
                Camera = { is_active = true, order = 1 + sr, clear_color = "None" },
                StencilRef = sr,
                SharedDepthFrom = my_cam_id,
                DepthClearOnStencil = sr,
                SkipMainPass = {},
                RenderLayers = { layers = { cfg.target_layer } },
            })
            print(string.format("[PORTAL/CLIENT] Activated portal camera %d (stencil_ref=%d)",
                target_cam_id, sr))
        else
            -- Deactivate: hide the other camera
            target_cam:patch({
                Camera = { is_active = false },
            })
            -- Remove stencil components
            target_cam:remove("StencilRef")
            target_cam:remove("SharedDepthFrom")
            target_cam:remove("DepthClearOnStencil")
            target_cam:remove("SkipMainPass")
            print(string.format("[PORTAL/CLIENT] Deactivated portal camera %d", target_cam_id))
        end

        ::continue::
    end
end, { label = "PortalCameraConfig", after = { "PortalActivation" } })

---------------------------------------------------------------------------
-- System: PortalScopeCleanup — react to game (scope) death
---------------------------------------------------------------------------
register_system("First", function(world)
    for _, entity in ipairs(world:query({ removed = { "game" }, scoped = false })) do
        local cfg = entity:get("game")
        local scope_key = cfg.scope_key
        if not scope_key then goto continue end

        for portal_eid, target_key in pairs(state.portal_targets) do
            if target_key == scope_key then
                state.portal_targets[portal_eid] = nil
                local portal = world:get_entity(portal_eid)
                if portal then
                    portal:remove("stencil")
                end
                -- If not primary: PortalCameraConfig handles stencil setup
            end
        end

        local scope_camera = state.scope_cameras[scope_key]
        if scope_camera then
            local camera = world:get_entity(scope_camera.camera_id)
            if camera then despawn(camera) end
            state.scope_cameras[scope_key] = nil
            print(string.format("[PORTAL/CLIENT] Cleaned up camera for dead scope '%s'", scope_key))
        end

        ::continue::
    end
end, { label = "PortalCameraActivation", after = { "PortalCameraConfig" } })

---------------------------------------------------------------------------
-- SCOPE_SWITCH handler — registered via Net.register_handler
-- Receives SCOPE_SWITCH from the server when the local player crosses
-- a portal. Switches primary scope on the client side.
---------------------------------------------------------------------------
Net.register_handler(Net.MSG.SCOPE_SWITCH, function(world, msg, sender_id)
    local target_scope_key = msg.target_scope_key
    local target_port = msg.target_port

    print(string.format("[PORTAL/CLIENT] SCOPE_SWITCH received: target='%s' (port %s) __ASSET_ROOT__=%s",
        tostring(target_scope_key), tostring(target_port), tostring(__ASSET_ROOT__)))

    -- Signal to the client that primary scope has changed.
    -- The input system routes based on net_owner, which is already correct
    -- (authority switch demoted our player on ScopeA, promoted on ScopeB).
    -- The camera system needs to switch to ScopeB's camera as primary.

    local net_info = define_resource("NetInfo", {})
    net_info.primary_scope_key = target_scope_key
    net_info.primary_port = target_port

    -- Find all portals and deactivate stencil (we're now on the other side)
    for _, portal in ipairs(world:query({ with = { "ScopeStencil" } })) do
        local stencil = portal:get("ScopeStencil")
        if stencil and stencil.active then
            portal:patch({ ScopeStencil = { active = false } })
        end
    end
end)
