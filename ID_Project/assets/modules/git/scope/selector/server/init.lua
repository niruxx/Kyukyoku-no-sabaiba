-- modules/git/scope/selector/server/init.lua
-- Server-side selector logic:
--   1. Sets up net_sync for client-authoritative selector component (requests)
--   2. Sets up net_sync for server-authoritative response component (replies)
--   3. Handles "open_portal" requests (spawns portal entities)
--   4. Handles "switch_scope" requests (allocates port, launches server, responds with port)

register_system("First", function(world)
    for _, entity in ipairs(world:query({ added = { "git/scope/selector" } })) do
        entity:patch({
            net_sync = {
                ["git/scope/selector"] = { authority = "client" },
                ["git/scope/selector/response"] = { authority = "server" },
            }
        })
    end
end, { label = "GitScopeSelector" })

register_system("Update", function(world)
    local entities = world:query({ changed = { "git/scope/selector" }, with = { "net_owner" } })
    for _, entity in ipairs(entities) do
        local selector = entity:get("git/scope/selector")
        if not selector then goto continue end

        -- Handle portal placement request
        if selector.open_portal then
            -- The requesting player entity has net_owner — pass it to the
            -- portal so the client gets net_local (required by placement mod).
            local owner = entity:get("net_owner")
            if not owner then goto continue end

            spawn({
                net_owner = owner,
                net_sync = {
                    Transform = { authority = "client", reliable = false },
                },
                net_mod = {
                    placement = {},
                    ["git/scope/portal"] = {
                        scope_a = { name = selector.open_portal.current_sk },
                        scope_b = { name = selector.open_portal.target_sk },
                    },
                },
            })
        end

        -- Handle scope switch request
        if selector.switch_scope and type(selector.switch_scope) == "string" then
            local scope_key = selector.switch_scope
            local ports = define_resource("PortAllocator", { next_port = 5002, scope_ports = {} })

            local port, is_new = ports.alloc(scope_key)

            if is_new then
                print(string.format("[SELECTOR] Requesting game server for scope '%s' on port %d",
                    scope_key, port))

                -- Spawn game entity so root server/main.lua
                -- picks it up via its `added { "game" }` watcher.
                spawn({
                    game = { mode = "server", port = port, scope_key = scope_key },
                    ScopeWorld = "All",
                })
            else
                print(string.format("[SELECTOR] Reusing existing server for scope '%s' on port %d",
                    scope_key, port))
            end

            -- Clear the one-shot request on the client-auth component
            entity:patch({
                ["git/scope/selector"] = {
                    switch_scope = null,
                },
            })

            -- Respond to client via server-auth response component
            entity:patch({
                ["git/scope/selector/response"] = {
                    switch_port = port,
                    switch_scope_key = scope_key,
                },
            })
        end

        ::continue::
    end
end, { label = "GitScopeSelectorUpdate" })