-- modules/net/peer/shared.lua
-- Shared constants and helpers for server-to-server peer connections.
-- Used by net/peer/init.lua (peer server), outbound.lua, inbound.lua.

local json = require("modules/dkjson.lua")

local Peer = {}

-- Peer protocol message types (server-to-server only).
-- Separate namespace from Net.MSG to avoid collisions.
Peer.MSG = {
    PEER_HELLO = "peer_hello",             -- initiator → acceptor: identify myself
    PEER_WELCOME = "peer_welcome",         -- acceptor → initiator: acknowledged
    ENTITY_SPAWN = "entity_spawn",         -- source → mirror: new shared entity
    ENTITY_UPDATE = "entity_update",       -- source → mirror: changed components
    ENTITY_DESPAWN = "entity_despawn",      -- source → mirror: entity removed
    AUTHORITY_SWITCH = "auth_switch",       -- old source → new source: hand off ownership
    AUTHORITY_ACK = "auth_ack",            -- new source → old source: ownership accepted
}

-- Channels (same indices as Net, reused on peer renet instances)
Peer.CHANNEL_RELIABLE = 0
Peer.CHANNEL_UNRELIABLE = 1

--- Encode a message to JSON for sending over renet.
--- @param msg table  Message table (must have msg_type)
--- @return string  JSON-encoded message
function Peer.encode(msg)
    return json.encode(msg)
end

--- Decode a JSON message from renet.
--- @param raw string  Raw JSON string
--- @return table|nil  Decoded message, or nil on error
function Peer.decode(raw)
    local ok, msg = pcall(json.decode, raw, 1, json.null)
    if ok and type(msg) == "table" then
        return msg
    end
    return nil
end

return Peer
