-- modules/scope/render/init.lua
-- Lua-side render layer allocation for scopes.
-- Replaces Rust ScopeRenderLayerRegistry + sync systems.
-- HierarchyPropagatePlugin<RenderLayers> (Bevy 0.17) handles child propagation.

local MAX_SCOPE_LAYERS = 15

local state = define_resource("ScopeRenderLayers", {
    next_layer = 1,
    scope_to_layer = {},
    freed = {},
})

function state.get_or_allocate(scope_id)
    if state.scope_to_layer[scope_id] then
        return state.scope_to_layer[scope_id]
    end
    local layer
    if #state.freed > 0 then
        layer = table.remove(state.freed)
    elseif state.next_layer <= MAX_SCOPE_LAYERS then
        layer = state.next_layer
        state.next_layer = state.next_layer + 1
    else
        print("[SCOPE_RENDER] WARNING: All 15 scope layers exhausted")
        return 0
    end
    state.scope_to_layer[scope_id] = layer
    return layer
end

function state.get_layer(scope_id)
    return state.scope_to_layer[scope_id]
end

function state.release(scope_id)
    local layer = state.scope_to_layer[scope_id]
    if layer then
        state.scope_to_layer[scope_id] = nil
        table.insert(state.freed, layer)
    end
end

-- Set RenderLayers on entities when ScopeWorld is added.
-- HierarchyPropagatePlugin<RenderLayers> handles children automatically.
register_system("PostUpdate", function(world)
    for _, entity in ipairs(world:query({ added = { "ScopeWorld" } })) do
        local sw = entity:get("ScopeWorld")
        if not sw then goto continue end

        local layer
        if sw == "All" or (type(sw) == "table" and sw.All) then
            layer = 0
        elseif type(sw) == "table" and sw.Scope then
            layer = state.get_or_allocate(sw.Scope)
        elseif type(sw) == "number" then
            layer = state.get_or_allocate(sw)
        else
            goto continue
        end

        entity:patch({
            RenderLayers = { layers = { layer } },
            ["Propagate<RenderLayers>"] = { layers = { layer } },
        })

        ::continue::
    end
end, { label = "ScopeRenderLayerSync" })
