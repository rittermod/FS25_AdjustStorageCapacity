-- RmVehicleCapacitySyncEvent - Multiplayer sync event for vehicle capacity changes
-- Author: Ritter
--
-- Description: Synchronizes vehicle storage capacity changes between server and clients.
-- Follows same pattern as RmStorageCapacitySyncEvent but for vehicles.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmVehicleCapacitySyncEvent = {}

-- Action types
RmVehicleCapacitySyncEvent.ACTION_SET_CAPACITY = 0
RmVehicleCapacitySyncEvent.ACTION_RESET_CAPACITY = 1

-- Result codes
RmVehicleCapacitySyncEvent.RESULT_OK = 0
RmVehicleCapacitySyncEvent.ERROR_NOT_FOUND = 1
RmVehicleCapacitySyncEvent.ERROR_NOT_OWNER = 2
RmVehicleCapacitySyncEvent.ERROR_NOT_MANAGER = 3
RmVehicleCapacitySyncEvent.ERROR_INVALID_CAPACITY = 4
RmVehicleCapacitySyncEvent.ERROR_UNKNOWN = 255

local RmVehicleCapacitySyncEvent_mt = Class(RmVehicleCapacitySyncEvent, Event)
InitEventClass(RmVehicleCapacitySyncEvent, "RmVehicleCapacitySyncEvent")

--- Create empty event instance
function RmVehicleCapacitySyncEvent.emptyNew()
    return Event.new(RmVehicleCapacitySyncEvent_mt)
end

--- Create new event for client -> server request
---@param vehicle table The vehicle object
---@param fillUnitIndex number Fill unit index (1-based)
---@param newCapacity number New capacity value
---@param actionType number ACTION_SET_CAPACITY or ACTION_RESET_CAPACITY
function RmVehicleCapacitySyncEvent.new(vehicle, fillUnitIndex, newCapacity, actionType)
    local self = RmVehicleCapacitySyncEvent.emptyNew()

    self.vehicle = vehicle
    self.fillUnitIndex = fillUnitIndex or 1
    self.newCapacity = newCapacity or 0
    self.actionType = actionType or RmVehicleCapacitySyncEvent.ACTION_SET_CAPACITY

    return self
end

--- Create event for server -> client response/broadcast
---@param errorCode number Error code (0 = success)
---@param vehicle table The vehicle object
---@param fillUnitIndex number Fill unit index
---@param appliedCapacity number The capacity that was applied
function RmVehicleCapacitySyncEvent.newServerToClient(errorCode, vehicle, fillUnitIndex, appliedCapacity)
    local self = RmVehicleCapacitySyncEvent.emptyNew()

    self.errorCode = errorCode or RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
    self.vehicle = vehicle
    self.fillUnitIndex = fillUnitIndex or 1
    self.appliedCapacity = appliedCapacity or 0
    self.isResponse = true

    return self
end

--- Read event data from network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmVehicleCapacitySyncEvent:readStream(streamId, connection)
    if not connection:getIsServer() then
        -- SERVER receiving from CLIENT (request)
        self.vehicle = NetworkUtil.readNodeObject(streamId)
        self.fillUnitIndex = streamReadInt32(streamId)
        self.newCapacity = streamReadInt32(streamId)
        self.actionType = streamReadUIntN(streamId, 2)
        self.isResponse = false
    else
        -- CLIENT receiving from SERVER (response/broadcast)
        self.errorCode = streamReadUIntN(streamId, 8)
        self.vehicle = NetworkUtil.readNodeObject(streamId)
        self.fillUnitIndex = streamReadInt32(streamId)
        self.appliedCapacity = streamReadInt32(streamId)
        self.isResponse = true
    end

    self:run(connection)
end

--- Write event data to network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmVehicleCapacitySyncEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        -- CLIENT sending to SERVER (request)
        NetworkUtil.writeNodeObject(streamId, self.vehicle)
        streamWriteInt32(streamId, self.fillUnitIndex or 1)
        streamWriteInt32(streamId, self.newCapacity or 0)
        streamWriteUIntN(streamId, self.actionType or 0, 2)
    else
        -- SERVER sending to CLIENT (response/broadcast)
        streamWriteUIntN(streamId, self.errorCode or RmVehicleCapacitySyncEvent.ERROR_UNKNOWN, 8)
        NetworkUtil.writeNodeObject(streamId, self.vehicle)
        streamWriteInt32(streamId, self.fillUnitIndex or 1)
        streamWriteInt32(streamId, self.appliedCapacity or 0)
    end
end

--- Execute the event
---@param connection table Network connection
function RmVehicleCapacitySyncEvent:run(connection)
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
function RmVehicleCapacitySyncEvent:runOnServer(connection)
    local actionName = self.actionType == RmVehicleCapacitySyncEvent.ACTION_RESET_CAPACITY and "RESET" or "SET"

    local errorCode = RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
    local appliedCapacity = 0

    local vehicle = self.vehicle

    if vehicle == nil then
        errorCode = RmVehicleCapacitySyncEvent.ERROR_NOT_FOUND
        Log:warning("Server received %s request but vehicle is nil", actionName)
    else
        Log:debug("Server received %s request for %s (fillUnit=%d, newCapacity=%d)",
            actionName, vehicle:getName(), self.fillUnitIndex, self.newCapacity)

        -- Get the requesting user
        local user = g_currentMission.userManager:getUserByConnection(connection)
        local player = g_currentMission:getPlayerByConnection(connection)

        if user == nil then
            Log:warning("Could not find user for connection")
            errorCode = RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
        elseif player == nil then
            Log:warning("Could not find player for connection")
            errorCode = RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
        else
            local userId = user.userId or user:getId()
            local playerName = user:getNickname() or user.nickname or "Unknown"
            local playerFarmId = player.farmId

            Log:debug("User: %s (farm %s)", playerName, tostring(playerFarmId))

            if playerFarmId == nil or playerFarmId == FarmManager.SPECTATOR_FARM_ID then
                Log:warning("Player %s has no farm or is spectator", playerName)
                errorCode = RmVehicleCapacitySyncEvent.ERROR_NOT_OWNER
            else
                local ownerFarmId = vehicle:getOwnerFarmId()
                local hasPermission = false

                -- Check admin first
                if user:getIsMasterUser() then
                    hasPermission = true
                    Log:debug("Player %s is admin", playerName)
                end

                -- Non-admin: check ownership
                if not hasPermission then
                    if ownerFarmId ~= playerFarmId then
                        errorCode = RmVehicleCapacitySyncEvent.ERROR_NOT_OWNER
                        Log:warning("Player %s (farm %d) tried to modify vehicle owned by farm %d",
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

                if not hasPermission and errorCode == RmVehicleCapacitySyncEvent.ERROR_UNKNOWN then
                    errorCode = RmVehicleCapacitySyncEvent.ERROR_NOT_MANAGER
                    Log:warning("Player %s is not admin or farm manager", playerName)
                end

                -- Permission granted, process the action
                if hasPermission then
                    if self.actionType == RmVehicleCapacitySyncEvent.ACTION_RESET_CAPACITY then
                        -- Reset capacity
                        local success, err = RmAdjustStorageCapacity:resetVehicleCapacity(vehicle, self.fillUnitIndex)
                        if success then
                            appliedCapacity = 0
                            errorCode = RmVehicleCapacitySyncEvent.RESULT_OK
                            Log:info("MP: Reset capacity for %s fillUnit=%d (by %s)",
                                vehicle:getName(), self.fillUnitIndex, playerName)
                        else
                            errorCode = RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
                            Log:warning("Failed to reset capacity: %s", err or "unknown")
                        end
                    else
                        -- Set new capacity
                        if self.newCapacity < 0 then
                            errorCode = RmVehicleCapacitySyncEvent.ERROR_INVALID_CAPACITY
                            Log:warning("Invalid capacity %d", self.newCapacity)
                        else
                            local success, err = RmAdjustStorageCapacity:setVehicleCapacity(
                                vehicle, self.fillUnitIndex, self.newCapacity)
                            if success then
                                appliedCapacity = self.newCapacity
                                errorCode = RmVehicleCapacitySyncEvent.RESULT_OK
                                Log:info("MP: Set capacity for %s fillUnit=%d to %d (by %s)",
                                    vehicle:getName(), self.fillUnitIndex, self.newCapacity, playerName)
                            else
                                errorCode = RmVehicleCapacitySyncEvent.ERROR_UNKNOWN
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
    connection:sendEvent(RmVehicleCapacitySyncEvent.newServerToClient(
        errorCode, vehicle, self.fillUnitIndex, appliedCapacity))

    -- If successful, broadcast to all OTHER clients
    if errorCode == RmVehicleCapacitySyncEvent.RESULT_OK then
        Log:debug("Broadcasting success to other clients")
        g_server:broadcastEvent(RmVehicleCapacitySyncEvent.newServerToClient(
            errorCode, vehicle, self.fillUnitIndex, appliedCapacity), false, connection)
    end
end

--- Client-side processing of server response
function RmVehicleCapacitySyncEvent:runOnClient()
    local vehicle = self.vehicle
    local vehicleName = vehicle and vehicle:getName() or "Unknown"

    Log:debug("Client received response: errorCode=%d, vehicle=%s, fillUnit=%d, appliedCapacity=%d",
        self.errorCode, vehicleName, self.fillUnitIndex, self.appliedCapacity)

    if self.errorCode == RmVehicleCapacitySyncEvent.RESULT_OK then
        -- Update local state
        if vehicle ~= nil then
            local uniqueId = vehicle.uniqueId

            if uniqueId == nil then
                Log:warning("Client: Vehicle %s has nil uniqueId", vehicleName)
                return
            end

            -- Apply the capacity locally
            if self.appliedCapacity > 0 then
                if RmAdjustStorageCapacity.vehicleCapacities[uniqueId] == nil then
                    RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = {}
                end

                RmAdjustStorageCapacity.vehicleCapacities[uniqueId][self.fillUnitIndex] = self.appliedCapacity
                RmAdjustStorageCapacity:applyVehicleCapacities(vehicle)
            else
                -- Reset - remove the entry
                if RmAdjustStorageCapacity.vehicleCapacities[uniqueId] ~= nil then
                    RmAdjustStorageCapacity.vehicleCapacities[uniqueId][self.fillUnitIndex] = nil
                    -- Clean up empty entry
                    if next(RmAdjustStorageCapacity.vehicleCapacities[uniqueId]) == nil then
                        RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = nil
                    end
                end
                RmAdjustStorageCapacity:applyVehicleCapacities(vehicle)
            end

            Log:debug("MP: Updated local capacity for %s fillUnit=%d to %d",
                vehicleName, self.fillUnitIndex, self.appliedCapacity)

            -- Show success message
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("rm_asc_vehicle_capacitySet"), vehicleName, self.appliedCapacity))
        else
            Log:warning("Client: Vehicle not found in response")
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
function RmVehicleCapacitySyncEvent:getErrorMessageKey()
    if self.errorCode == RmVehicleCapacitySyncEvent.ERROR_NOT_FOUND then
        return "rm_asc_error_notFound"
    elseif self.errorCode == RmVehicleCapacitySyncEvent.ERROR_NOT_OWNER then
        return "rm_asc_error_notOwner"
    elseif self.errorCode == RmVehicleCapacitySyncEvent.ERROR_NOT_MANAGER then
        return "rm_asc_error_notManager"
    elseif self.errorCode == RmVehicleCapacitySyncEvent.ERROR_INVALID_CAPACITY then
        return "rm_asc_error_invalidCapacity"
    else
        return "rm_asc_error_unknown"
    end
end

--- Send a capacity change request (called from client or server)
---@param vehicle table The vehicle object
---@param fillUnitIndex number Fill unit index (1-based)
---@param newCapacity number New capacity value
function RmVehicleCapacitySyncEvent.sendSetCapacity(vehicle, fillUnitIndex, newCapacity)
    if vehicle == nil then
        Log:warning("sendSetCapacity: vehicle is nil")
        return
    end

    Log:debug("sendSetCapacity: vehicle=%s, fillUnit=%d, capacity=%d",
        vehicle:getName(), fillUnitIndex, newCapacity)

    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer
    local isServer = g_currentMission:getIsServer()

    if not isMultiplayer or isServer then
        -- Single player or server can apply directly
        Log:debug("Applying SET directly (isMultiplayer=%s, isServer=%s)",
            tostring(isMultiplayer), tostring(isServer))

        local success, err = RmAdjustStorageCapacity:setVehicleCapacity(vehicle, fillUnitIndex, newCapacity)
        if success then
            -- Broadcast to clients if MP
            if isMultiplayer then
                g_server:broadcastEvent(RmVehicleCapacitySyncEvent.newServerToClient(
                    RmVehicleCapacitySyncEvent.RESULT_OK, vehicle, fillUnitIndex, newCapacity))
            end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("rm_asc_vehicle_capacitySet"), vehicle:getName(), newCapacity))
        else
            Log:warning("Failed to set capacity: %s", err or "unknown")
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("rm_asc_error_invalidCapacity"))
        end
    else
        -- MP client: send to server
        Log:debug("Client sending SET request to server")
        g_client:getServerConnection():sendEvent(RmVehicleCapacitySyncEvent.new(
            vehicle, fillUnitIndex, newCapacity, RmVehicleCapacitySyncEvent.ACTION_SET_CAPACITY))
    end
end

--- Send a capacity reset request
---@param vehicle table The vehicle object
---@param fillUnitIndex number|nil Fill unit index (nil = reset all)
function RmVehicleCapacitySyncEvent.sendResetCapacity(vehicle, fillUnitIndex)
    if vehicle == nil then
        Log:warning("sendResetCapacity: vehicle is nil")
        return
    end

    Log:debug("sendResetCapacity: vehicle=%s, fillUnit=%s",
        vehicle:getName(), tostring(fillUnitIndex))

    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer
    local isServer = g_currentMission:getIsServer()

    if not isMultiplayer or isServer then
        -- Single player or server can apply directly
        Log:debug("Applying RESET directly")

        local success, err = RmAdjustStorageCapacity:resetVehicleCapacity(vehicle, fillUnitIndex)
        if success then
            -- Broadcast to clients if MP
            if isMultiplayer then
                g_server:broadcastEvent(RmVehicleCapacitySyncEvent.newServerToClient(
                    RmVehicleCapacitySyncEvent.RESULT_OK, vehicle, fillUnitIndex or 0, 0))
            end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                g_i18n:getText("rm_asc_status_reset"))
        else
            Log:warning("Failed to reset capacity: %s", err or "unknown")
        end
    else
        -- MP client: send to server
        Log:debug("Client sending RESET request to server")
        g_client:getServerConnection():sendEvent(RmVehicleCapacitySyncEvent.new(
            vehicle, fillUnitIndex or 0, 0, RmVehicleCapacitySyncEvent.ACTION_RESET_CAPACITY))
    end
end
