-- modules/map/default/shared/init.lua
-- Shared: both server and client spawn identical ground plane + lighting.
-- No replication needed since both sides create the same geometry.

register_system("First", function(world)
    local maps = world:query({ added = { "map/default" } })
    for _, entity in ipairs(maps) do
        -- Ground plane
        local mesh = create_asset("bevy_mesh::mesh::Mesh", {
            primitive = { Cuboid = { half_size = { x = 50, y = 0.1, z = 50 } } },
        })
        local mat = create_asset("bevy_pbr::pbr_material::StandardMaterial", {
            base_color = { r = 0.3, g = 0.5, b = 0.3, a = 1.0 },
            perceptual_roughness = 0.9,
        })
        spawn({
            Transform = { translation = { x = 0, y = 0, z = 0 } },
            Mesh3d = mesh,
            ["MeshMaterial3d<StandardMaterial>"] = mat,
            RigidBody3d = "Fixed",
            Collider3d = { cuboid = { hx = 50, hy = 0.1, hz = 50 } },
        }):with_parent(entity:id())

        -- Directional light (sun)
        spawn({
            DirectionalLight = { illuminance = 10000, shadows_enabled = true },
            Transform = { rotation = { x = -0.5, y = 0.5, z = 0, w = 0.7 } },
        }):with_parent(entity:id())

        -- Ambient light
        spawn({ AmbientLight = { brightness = 300 } })

        print("[MAP/DEFAULT] Ground plane + lighting spawned")
    end
    return true -- one-shot
end)
