-- RmStorageCapacitySyncEvent - Multiplayer sync event for AdjustStorageCapacity
-- Author: Ritter
--
-- Description: Synchronizes storage capacity changes between server and clients
-- Supports both Storage class fill types and HusbandryFood special capacity (fillType -1)

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmStorageCapacitySyncEvent = {}

-- Action types
RmStorageCapacitySyncEvent.ACTION_SET_CAPACITY = 0
RmStorageCapacitySyncEvent.ACTION_RESET_CAPACITY = 1

-- Result codes
RmStorageCapacitySyncEvent.RESULT_OK = 0
RmStorageCapacitySyncEvent.ERROR_NOT_FOUND = 1
RmStorageCapacitySyncEvent.ERROR_NOT_OWNER = 2
RmStorageCapacitySyncEvent.ERROR_NOT_MANAGER = 3
RmStorageCapacitySyncEvent.ERROR_INVALID_CAPACITY = 4
RmStorageCapacitySyncEvent.ERROR_NOT_MODIFIABLE = 5
RmStorageCapacitySyncEvent.ERROR_UNKNOWN = 255

local RmStorageCapacitySyncEvent_mt = Class(RmStorageCapacitySyncEvent, Event)
InitEventClass(RmStorageCapacitySyncEvent, "RmStorageCapacitySyncEvent")

--- Create empty event instance
function RmStorageCapacitySyncEvent.emptyNew()
    return Event.new(RmStorageCapacitySyncEvent_mt)
end

--- Create new event for client -> server request
---@param placeable table The storage placeable object
---@param fillTypeIndex number Fill type index (-1 for HusbandryFood)
---@param newCapacity number New capacity value
---@param actionType number ACTION_SET_CAPACITY or ACTION_RESET_CAPACITY
function RmStorageCapacitySyncEvent.new(placeable, fillTypeIndex, newCapacity, actionType)
    local self = RmStorageCapacitySyncEvent.emptyNew()

    self.placeable = placeable
    self.fillTypeIndex = fillTypeIndex or 0
    self.newCapacity = newCapacity or 0
    self.actionType = actionType or RmStorageCapacitySyncEvent.ACTION_SET_CAPACITY

    return self
end

--- Create event for server -> client response/broadcast
---@param errorCode number Error code (0 = success)
---@param placeable table The storage placeable object
---@param fillTypeIndex number Fill type index (-1 for HusbandryFood)
---@param appliedCapacity number The capacity that was applied
function RmStorageCapacitySyncEvent.newServerToClient(errorCode, placeable, fillTypeIndex, appliedCapacity)
    local self = RmStorageCapacitySyncEvent.emptyNew()

    self.errorCode = errorCode or RmStorageCapacitySyncEvent.ERROR_UNKNOWN
    self.placeable = placeable
    self.fillTypeIndex = fillTypeIndex or 0
    self.appliedCapacity = appliedCapacity or 0
    self.isResponse = true

    return self
end

--- Read event data from network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmStorageCapacitySyncEvent:readStream(streamId, connection)
    if not connection:getIsServer() then
        -- SERVER receiving from CLIENT (request)
        self.placeable = NetworkUtil.readNodeObject(streamId)
        self.fillTypeIndex = streamReadInt32(streamId)
        self.newCapacity = streamReadInt32(streamId)
        self.actionType = streamReadUIntN(streamId, 2)
        self.isResponse = false
    else
        -- CLIENT receiving from SERVER (response/broadcast)
        self.errorCode = streamReadUIntN(streamId, 8)
        self.placeable = NetworkUtil.readNodeObject(streamId)
        self.fillTypeIndex = streamReadInt32(streamId)
        self.appliedCapacity = streamReadInt32(streamId)
        self.isResponse = true
    end

    self:run(connection)
end

--- Write event data to network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmStorageCapacitySyncEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        -- CLIENT sending to SERVER (request)
        NetworkUtil.writeNodeObject(streamId, self.placeable)
        streamWriteInt32(streamId, self.fillTypeIndex or 0)
        streamWriteInt32(streamId, self.newCapacity or 0)
        streamWriteUIntN(streamId, self.actionType or 0, 2)
    else
        -- SERVER sending to CLIENT (response/broadcast)
        streamWriteUIntN(streamId, self.errorCode or RmStorageCapacitySyncEvent.ERROR_UNKNOWN, 8)
        NetworkUtil.writeNodeObject(streamId, self.placeable)
        streamWriteInt32(streamId, self.fillTypeIndex or 0)
        streamWriteInt32(streamId, self.appliedCapacity or 0)
    end
end

--- Execute the event
---@param connection table Network connection
function RmStorageCapacitySyncEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER processing CLIENT request
        self:runOnServer(connection)
    else
        -- CLIENT processing SERVER response
        self:runOnClient()
    end
end

--- Server-side processing of capacity change request
---@param connection table Network connection from requesting client
function RmStorageCapacitySyncEvent:runOnServer(connection)
    local actionName = self.actionType == RmStorageCapacitySyncEvent.ACTION_RESET_CAPACITY and "RESET" or "SET"

    local errorCode = RmStorageCapacitySyncEvent.ERROR_UNKNOWN
    local appliedCapacity = 0

    local placeable = self.placeable

    if placeable == nil then
        errorCode = RmStorageCapacitySyncEvent.ERROR_NOT_FOUND
        Log:warning("Server received %s request but placeable is nil", actionName)
    else
        Log:debug("Server received %s request for %s (fillType=%d, newCapacity=%d)",
            actionName, placeable:getName(), self.fillTypeIndex, self.newCapacity)

        -- Get the requesting user
        local user = g_currentMission.userManager:getUserByConnection(connection)
        local player = g_currentMission:getPlayerByConnection(connection)

        if user == nil then
            Log:warning("Could not find user for connection")
            errorCode = RmStorageCapacitySyncEvent.ERROR_UNKNOWN
        elseif player == nil then
            Log:warning("Could not find player for connection")
            errorCode = RmStorageCapacitySyncEvent.ERROR_UNKNOWN
        else
            local userId = user.userId or user:getId()
            local playerName = user:getNickname() or user.nickname or "Unknown"
            local playerFarmId = player.farmId

            Log:debug("User: %s (farm %s)", playerName, tostring(playerFarmId))

            if playerFarmId == nil or playerFarmId == FarmManager.SPECTATOR_FARM_ID then
                Log:warning("Player %s has no farm or is spectator", playerName)
                errorCode = RmStorageCapacitySyncEvent.ERROR_NOT_OWNER
            else
                local ownerFarmId = placeable:getOwnerFarmId()
                local hasPermission = false

                -- Block modification of unowned/spectator assets (even admins)
                if ownerFarmId == 0 or ownerFarmId == FarmManager.SPECTATOR_FARM_ID then
                    errorCode = RmStorageCapacitySyncEvent.ERROR_NOT_MODIFIABLE
                    Log:warning("Cannot modify asset owned by farm %d", ownerFarmId)
                end

                -- Check admin first (only if not already blocked)
                if errorCode == RmStorageCapacitySyncEvent.ERROR_UNKNOWN and user:getIsMasterUser() then
                    hasPermission = true
                    Log:debug("Player %s is admin", playerName)
                end

                -- Non-admin: check ownership
                if not hasPermission then
                    if ownerFarmId ~= playerFarmId then
                        errorCode = RmStorageCapacitySyncEvent.ERROR_NOT_OWNER
                        Log:warning("Player %s (farm %d) tried to modify storage owned by farm %d",
                            playerName, playerFarmId, ownerFarmId)
                    else
                        -- Check if player is farm manager
                        local farm = g_farmManager:getFarmById(playerFarmId)
                        if farm ~= nil and farm:isUserFarmManager(userId) then
                            hasPermission = true
                            Log:debug("Player %s is farm manager", playerName)
                        end
                    end
                end

                if not hasPermission and errorCode == RmStorageCapacitySyncEvent.ERROR_UNKNOWN then
                    errorCode = RmStorageCapacitySyncEvent.ERROR_NOT_MANAGER
                    Log:warning("Player %s is not admin or farm manager", playerName)
                end

                -- Permission granted, process the action
                if hasPermission then
                    if self.actionType == RmStorageCapacitySyncEvent.ACTION_RESET_CAPACITY then
                        -- Reset capacity
                        local success, err = RmAdjustStorageCapacity:resetCapacity(placeable, self.fillTypeIndex)
                        if success then
                            appliedCapacity = 0 -- Original capacity
                            errorCode = RmStorageCapacitySyncEvent.RESULT_OK
                            Log:info("MP: Reset capacity for %s fillType=%d (by %s)",
                                placeable:getName(), self.fillTypeIndex, playerName)
                        else
                            errorCode = RmStorageCapacitySyncEvent.ERROR_UNKNOWN
                            Log:warning("Failed to reset capacity: %s", err or "unknown")
                        end
                    else
                        -- Set new capacity
                        if self.newCapacity < 0 then
                            errorCode = RmStorageCapacitySyncEvent.ERROR_INVALID_CAPACITY
                            Log:warning("Invalid capacity %d", self.newCapacity)
                        else
                            local success, err = RmAdjustStorageCapacity:setCapacity(
                                placeable, self.fillTypeIndex, self.newCapacity)
                            if success then
                                appliedCapacity = self.newCapacity
                                errorCode = RmStorageCapacitySyncEvent.RESULT_OK
                                Log:info("MP: Set capacity for %s fillType=%d to %d (by %s)",
                                    placeable:getName(), self.fillTypeIndex, self.newCapacity, playerName)
                            else
                                errorCode = RmStorageCapacitySyncEvent.ERROR_UNKNOWN
                                Log:warning("Failed to set capacity: %s", err or "unknown")
                            end
                        end
                    end
                end
            end
        end
    end

    -- Send response back to requesting client
    Log:debug("Server sending response: errorCode=%d, appliedCapacity=%d", errorCode, appliedCapacity)
    connection:sendEvent(RmStorageCapacitySyncEvent.newServerToClient(
        errorCode, placeable, self.fillTypeIndex, appliedCapacity))

    -- If successful, broadcast to all OTHER clients
    if errorCode == RmStorageCapacitySyncEvent.RESULT_OK then
        Log:debug("Broadcasting success to other clients")
        g_server:broadcastEvent(RmStorageCapacitySyncEvent.newServerToClient(
            errorCode, placeable, self.fillTypeIndex, appliedCapacity), false, connection)
    end
end

--- Client-side processing of server response
function RmStorageCapacitySyncEvent:runOnClient()
    local placeable = self.placeable
    local placeableName = placeable and placeable:getName() or "Unknown"

    Log:debug("Client received response: errorCode=%d, placeable=%s, fillType=%d, appliedCapacity=%d",
        self.errorCode, placeableName, self.fillTypeIndex, self.appliedCapacity)

    if self.errorCode == RmStorageCapacitySyncEvent.RESULT_OK then
        -- Update local state
        if placeable ~= nil then
            local uniqueId = placeable.uniqueId

            if uniqueId == nil then
                Log:warning("Client: Placeable %s has nil uniqueId", placeableName)
                return
            end

            -- Apply the capacity locally
            if self.appliedCapacity > 0 then
                if RmAdjustStorageCapacity.customCapacities[uniqueId] == nil then
                    RmAdjustStorageCapacity.customCapacities[uniqueId] = {
                        fillTypes = {},
                        husbandryFood = nil
                    }
                end

                -- Handle special cases: -1 = HusbandryFood, 0 = shared capacity
                if self.fillTypeIndex == -1 then
                    RmAdjustStorageCapacity.customCapacities[uniqueId].husbandryFood = self.appliedCapacity
                    local customCapacity = {husbandryFood = self.appliedCapacity}
                    RmAdjustStorageCapacity:applyCapacitiesToPlaceable(placeable, customCapacity)
                elseif self.fillTypeIndex == 0 then
                    -- Shared capacity (fillType 0 is sentinel for shared)
                    RmAdjustStorageCapacity.customCapacities[uniqueId].sharedCapacity = self.appliedCapacity
                    local customCapacity = {sharedCapacity = self.appliedCapacity}
                    RmAdjustStorageCapacity:applyCapacitiesToPlaceable(placeable, customCapacity)
                else
                    -- Per-fillType capacity
                    if RmAdjustStorageCapacity.customCapacities[uniqueId].fillTypes == nil then
                        RmAdjustStorageCapacity.customCapacities[uniqueId].fillTypes = {}
                    end
                    RmAdjustStorageCapacity.customCapacities[uniqueId].fillTypes[self.fillTypeIndex] = self.appliedCapacity
                    local customCapacity = {fillTypes = {[self.fillTypeIndex] = self.appliedCapacity}}
                    RmAdjustStorageCapacity:applyCapacitiesToPlaceable(placeable, customCapacity)
                end
            end

            Log:debug("MP: Updated local capacity for %s fillType=%d to %d",
                placeableName, self.fillTypeIndex, self.appliedCapacity)

            -- Show success message
            local fillTypeName
            if self.fillTypeIndex == -1 then
                fillTypeName = g_i18n:getText("rm_asc_husbandryFood") or "Animal Food"
            else
                local fillType = g_fillTypeManager:getFillTypeByIndex(self.fillTypeIndex)
                fillTypeName = fillType and fillType.title or "Unknown"
            end
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("rm_asc_mp_success"), placeableName, fillTypeName, self.appliedCapacity))
        else
            Log:warning("Client: Placeable not found in response")
        end
    else
        -- Show error message
        local errorKey = self:getErrorMessageKey()
        Log:warning("Client received error: %s (code=%d)", errorKey, self.errorCode)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey))
    end
end

--- Get localization key for error message
---@return string errorKey Localization key
function RmStorageCapacitySyncEvent:getErrorMessageKey()
    if self.errorCode == RmStorageCapacitySyncEvent.ERROR_NOT_FOUND then
        return "rm_asc_error_notFound"
    elseif self.errorCode == RmStorageCapacitySyncEvent.ERROR_NOT_OWNER then
        return "rm_asc_error_notOwner"
    elseif self.errorCode == RmStorageCapacitySyncEvent.ERROR_NOT_MANAGER then
        return "rm_asc_error_notManager"
    elseif self.errorCode == RmStorageCapacitySyncEvent.ERROR_INVALID_CAPACITY then
        return "rm_asc_error_invalidCapacity"
    elseif self.errorCode == RmStorageCapacitySyncEvent.ERROR_NOT_MODIFIABLE then
        return "rm_asc_error_notModifiable"
    else
        return "rm_asc_error_unknown"
    end
end

--- Send a capacity change request (called from client or server)
---@param placeable table The storage placeable object
---@param fillTypeIndex number Fill type index (-1 for HusbandryFood)
---@param newCapacity number New capacity value
---@param wasClampedByDialog boolean|nil Optional flag if clamping was done by dialog
function RmStorageCapacitySyncEvent.sendSetCapacity(placeable, fillTypeIndex, newCapacity, wasClampedByDialog)
    if placeable == nil then
        Log:warning("sendSetCapacity: placeable is nil")
        return
    end

    Log:debug("sendSetCapacity: placeable=%s, fillType=%d, capacity=%d",
        placeable:getName(), fillTypeIndex, newCapacity)

    -- Determine if clamping occurred - either from dialog or check locally (for console commands)
    local wasClamped = wasClampedByDialog
    if wasClamped == nil then
        -- Console command or other caller - check if clamping is needed
        local minCapacity = RmAdjustStorageCapacity:getMinCapacity(placeable, fillTypeIndex)
        if newCapacity < minCapacity then
            Log:info("Capacity clamped from %d to %d (current fill level)", newCapacity, minCapacity)
            newCapacity = minCapacity
            wasClamped = true
        else
            wasClamped = false
        end
    end

    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer
    local isServer = g_currentMission:getIsServer()

    if not isMultiplayer or isServer then
        -- Single player or server can apply directly
        Log:debug("Applying SET directly (isMultiplayer=%s, isServer=%s)",
            tostring(isMultiplayer), tostring(isServer))

        local success, err = RmAdjustStorageCapacity:setCapacity(placeable, fillTypeIndex, newCapacity)
        if success then
            -- Broadcast to clients if MP
            if isMultiplayer then
                g_server:broadcastEvent(RmStorageCapacitySyncEvent.newServerToClient(
                    RmStorageCapacitySyncEvent.RESULT_OK, placeable, fillTypeIndex, newCapacity))
            end

            local fillTypeName
            if fillTypeIndex == -1 then
                fillTypeName = g_i18n:getText("rm_asc_husbandryFood") or "Animal Food"
            else
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                fillTypeName = fillType and fillType.title or "Unknown"
            end
            local messageKey = wasClamped and "rm_asc_mp_success_clamped" or "rm_asc_mp_success"
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText(messageKey), placeable:getName(), fillTypeName, newCapacity))
        else
            Log:warning("Failed to set capacity: %s", err or "unknown")
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("rm_asc_error_invalidCapacity"))
        end
    else
        -- MP client: send to server
        Log:debug("Client sending SET request to server")
        g_client:getServerConnection():sendEvent(RmStorageCapacitySyncEvent.new(
            placeable, fillTypeIndex, newCapacity, RmStorageCapacitySyncEvent.ACTION_SET_CAPACITY))
    end
end

--- Send a capacity reset request
---@param placeable table The storage placeable object
---@param fillTypeIndex number|nil Fill type index (nil = reset all, -1 = HusbandryFood only)
function RmStorageCapacitySyncEvent.sendResetCapacity(placeable, fillTypeIndex)
    if placeable == nil then
        Log:warning("sendResetCapacity: placeable is nil")
        return
    end

    Log:debug("sendResetCapacity: placeable=%s, fillType=%s",
        placeable:getName(), tostring(fillTypeIndex))

    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer
    local isServer = g_currentMission:getIsServer()

    if not isMultiplayer or isServer then
        -- Single player or server can apply directly
        Log:debug("Applying RESET directly")

        local success, err = RmAdjustStorageCapacity:resetCapacity(placeable, fillTypeIndex)
        if success then
            -- Broadcast to clients if MP
            if isMultiplayer then
                g_server:broadcastEvent(RmStorageCapacitySyncEvent.newServerToClient(
                    RmStorageCapacitySyncEvent.RESULT_OK, placeable, fillTypeIndex or 0, 0))
            end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                g_i18n:getText("rm_asc_status_reset"))
        else
            Log:warning("Failed to reset capacity: %s", err or "unknown")
        end
    else
        -- MP client: send to server
        Log:debug("Client sending RESET request to server")
        g_client:getServerConnection():sendEvent(RmStorageCapacitySyncEvent.new(
            placeable, fillTypeIndex or 0, 0, RmStorageCapacitySyncEvent.ACTION_RESET_CAPACITY))
    end
end
