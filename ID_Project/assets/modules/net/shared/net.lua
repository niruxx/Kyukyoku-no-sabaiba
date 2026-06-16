-- modules/net/shared/net.lua
-- Shared networking constants, id-map helpers, target filters, message handlers, and NetInfo resource.
-- Both server and client `require` this module from their instanced scope.

local Net = {}

local net_info = define_resource("NetInfo", {})

Net.CHANNEL_RELIABLE = 0
Net.CHANNEL_UNRELIABLE = 1

-- Built-in message type constants (infrastructure only).
-- Game mods add custom types at runtime via register_handler().
Net.MSG = {
    CLIENT_ID = "client_id",
    CLIENT_ID_ACK = "client_id_ack",
    SPAWN = "spawn",
    UPDATE = "update",
    DESPAWN = "despawn",
    SPAWN_REQUEST = "spawn_request",
    SPAWN_CONFIRM = "spawn_confirm",
    SPAWN_REJECT = "spawn_reject",
    DESPAWN_REQUEST = "despawn_request",
    SCOPE_SWITCH = "scope_switch",
    RTT_PING = "rtt_ping", -- Round-trip-time probe for client-side prediction
    RTT_PONG = "rtt_pong",
}

---------------------------------------------------------------------------
-- ID map helpers: net_id ↔ entity_id mapping (used by both server and client)
---------------------------------------------------------------------------

function Net.create_id_map()
    return { net_to_entity = {}, entity_to_net = {} }
end

function Net.map(id_map, net_id, entity_id)
    id_map.net_to_entity[net_id] = entity_id
    id_map.entity_to_net[entity_id] = net_id
end

function Net.unmap(id_map, net_id, entity_id)
    id_map.net_to_entity[net_id] = nil
    if entity_id then id_map.entity_to_net[entity_id] = nil end
end

---------------------------------------------------------------------------
-- Extensible target filter registry
-- Built-in: "all", "owner", "others"
-- Game mods register custom filters at runtime (e.g., "team", "nearby")
---------------------------------------------------------------------------
local filters = {}

function Net.register_filter(name, fn)
    filters[name] = fn
end

--- Check if a message should be sent to a specific client.
--- @param filter_name string|nil  Name of the registered filter (nil defaults to "all")
--- @param client_id number        The client being checked
--- @param entity userdata         The entity snapshot
--- @param owner_id number|nil     The owning client_id (from net_owner)
--- @return boolean
function Net.should_send_to(target, client_id, entity, owner_id)
    if not client_id or not entity then return false end
    
    local t_type = type(target)
    if t_type == "nil" then
        target = "all"
    elseif t_type == "table" then
        -- Array of targets: if any match, return true
        for _, t in ipairs(target) do
            if Net.should_send_to(t, client_id, entity, owner_id) then
                return true
            end
        end
        return false
    elseif t_type == "number" then
        -- Direct client_id match
        return target == client_id
    end

    local fn = filters[target]
    if not fn then return true end
    local net_owner = entity:get("net_owner")
    return fn(client_id, net_owner and net_owner.client_id, owner_id)
end

Net.register_filter("all", function() return true end)
Net.register_filter("owner", function(cid, _, oid) return cid == oid end)
Net.register_filter("others", function(cid, _, oid) return cid ~= oid end)

---------------------------------------------------------------------------
-- Extensible message handler registry
-- Game mods register handlers; server/client inbound dispatches to them.
-- handler(world, msg, sender_id)
--   sender_id is client_id on server, nil on client.
-- If no handler is registered, falls back to firing a net:{msg_type} event.
---------------------------------------------------------------------------
local handlers = {}

function Net.register_handler(msg_type, fn)
    handlers[msg_type] = handlers[msg_type] or {}
    handlers[msg_type][#handlers[msg_type] + 1] = fn
end

--- Dispatch a message to registered handlers.
--- @param world userdata     The world object
--- @param msg table          The decoded message (must have msg_type)
--- @param sender_id number|nil  The sender (client_id on server, nil on client)
--- @return boolean  true if at least one handler ran
function Net.dispatch(world, msg, sender_id)
    local fns = handlers[msg.msg_type]
    if not fns or #fns == 0 then return false end
    for _, fn in ipairs(fns) do
        fn(world, msg, sender_id)
    end
    return true
end

return Net 
