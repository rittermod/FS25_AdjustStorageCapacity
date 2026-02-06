-- RmSettingsSyncEvent - Multiplayer sync event for mod settings
-- Author: Ritter
--
-- Bidirectional event:
-- - Client → Server: request setting change (validated for master user)
-- - Server → Clients: broadcast current settings state

local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmSettingsSyncEvent = {}

local RmSettingsSyncEvent_mt = Class(RmSettingsSyncEvent, Event)
InitEventClass(RmSettingsSyncEvent, "RmSettingsSyncEvent")

function RmSettingsSyncEvent.emptyNew()
    return Event.new(RmSettingsSyncEvent_mt)
end

function RmSettingsSyncEvent.new()
    return RmSettingsSyncEvent.emptyNew()
end

--- Deserialize and apply settings
---@param streamId number Network stream
---@param connection table Source connection
function RmSettingsSyncEvent:readStream(streamId, connection)
    local showTriggerShortcut = streamReadInt32(streamId)
    local autoScaleMass = streamReadInt32(streamId)
    local autoScaleSpeed = streamReadInt32(streamId)

    -- Accept from server, or from master user (admin) on client-to-server
    if connection:getIsServer()
        or g_currentMission.userManager:getIsConnectionMasterUser(connection) then

        RmAscSettings.updateShowTriggerShortcut(showTriggerShortcut, true)
        RmAscSettings.updateAutoScaleMass(autoScaleMass, true)
        RmAscSettings.updateAutoScaleSpeed(autoScaleSpeed, true)

        -- If received from client, re-broadcast to all other clients
        if not connection:getIsServer() then
            g_server:broadcastEvent(self, false, connection)
        end
    else
        Log:warning("RmSettingsSyncEvent: Rejected - not server or master user")
    end
end

--- Serialize current settings state
---@param streamId number Network stream
---@param connection table Connection (unused)
function RmSettingsSyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, RmAscSettings.showTriggerShortcutState)
    streamWriteInt32(streamId, RmAscSettings.autoScaleMassState)
    streamWriteInt32(streamId, RmAscSettings.autoScaleSpeedState)
end

--- Send settings sync event
---@param noEventSend boolean|nil If true, skip sending
function RmSettingsSyncEvent.sendEvent(noEventSend)
    if noEventSend == true then
        return
    end

    if g_currentMission:getIsServer() then
        g_server:broadcastEvent(RmSettingsSyncEvent.new(), false)
    else
        g_client:getServerConnection():sendEvent(RmSettingsSyncEvent.new())
    end
end
