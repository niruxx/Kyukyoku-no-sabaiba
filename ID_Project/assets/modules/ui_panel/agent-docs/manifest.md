# ui_panel

Reusable RTT (Render-To-Texture) mod. Converts a UI Node hierarchy into a 3D
mesh via a Camera2d rendering to an Image target.

## Component: `ui_panel`

Config fields:
- `node_id` — (optional) explicit Node entity to RTT. Defaults to the entity's own Node or its sidebar container.
- `pixels_to_meters` — (optional) scale factor, default 0.0008
- `distance` — (optional) spawn distance from camera, default 0.6

After init, stores:
- `camera_id` — RTT Camera2d entity
- `mesh_id` — 3D mesh entity
- `rtt_image` — Image asset handle
- `texture_width`, `texture_height` — RTT dimensions

## Dependencies
None (optional: reads `sidebar` component if present to find container Node)

## Architecture

When placed on an entity, the mod:
1. Finds the target UI Node (own Node, or sidebar's container_id)
2. Creates an RTT Image asset at the Node's computed size
3. Spawns a Camera2d targeting the RTT Image
4. Sets UiTargetCamera on the Node to redirect rendering
5. Spawns a Mesh3d + StandardMaterial (unlit, double-sided) displaying the RTT Image
6. Watches ComputedNode changes to rebuild on resize
7. Watches ChildOf changes to handle re-parenting

```lua
-- Usage: RTT the sidebar
spawn({
    mod = { sidebar = {}, ui_panel = {} },
})

-- Usage: RTT any UI entity
spawn({
    mod = { ui_panel = {} },
    Node = { ... },
})
```
