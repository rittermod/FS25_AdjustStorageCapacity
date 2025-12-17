-- RmVehicleDetectionHandler - Player proximity detection for vehicle capacity adjustment
-- Author: Ritter
--
-- Detects nearby vehicles using distance checks in update loop.
-- When player walks near a vehicle with FillUnit, shows K keybind to adjust capacity.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmVehicleDetectionHandler = {}

-- Configuration
RmVehicleDetectionHandler.PROXIMITY_RADIUS = 4.0    -- meters
RmVehicleDetectionHandler.CLEANUP_INTERVAL = 2000   -- ms

-- State
RmVehicleDetectionHandler.initialized = false
RmVehicleDetectionHandler.isActive = false
RmVehicleDetectionHandler.nearbyVehicles = {}       -- {[vehicle] = timestamp}
RmVehicleDetectionHandler.currentVehicle = nil      -- Vehicle currently showing keybind for
RmVehicleDetectionHandler.actionEventId = nil       -- Input action event ID
RmVehicleDetectionHandler.lastCleanupTime = 0

--- Initialize the detection handler
function RmVehicleDetectionHandler.init()
    if RmVehicleDetectionHandler.initialized then
        return
    end

    Log:debug("Initializing vehicle detection handler")

    -- Hook into player lifecycle
    Player.onEnter = Utils.appendedFunction(Player.onEnter, RmVehicleDetectionHandler.onPlayerEnter)
    Player.onLeave = Utils.prependedFunction(Player.onLeave, RmVehicleDetectionHandler.onPlayerLeave)

    RmVehicleDetectionHandler.initialized = true

    -- Check if player is already present (hooks set up after player spawned)
    if g_localPlayer ~= nil then
        Log:debug("Player already present - starting detection immediately")
        RmVehicleDetectionHandler.startDetection()
    end

    Log:info("Vehicle detection handler initialized")
end

--- Called when player spawns/enters
---@param player table The Player object (self in the hooked function)
function RmVehicleDetectionHandler.onPlayerEnter(player)
    -- Only track local player
    if player ~= g_localPlayer then
        return
    end

    Log:debug("Player entered - starting vehicle detection")
    RmVehicleDetectionHandler.startDetection()
end

--- Called when player leaves/despawns
---@param player table The Player object
function RmVehicleDetectionHandler.onPlayerLeave(player)
    if player ~= g_localPlayer then
        return
    end

    Log:debug("Player leaving - stopping vehicle detection")
    RmVehicleDetectionHandler.stopDetection()
end

--- Start proximity detection (register for updates)
function RmVehicleDetectionHandler.startDetection()
    if RmVehicleDetectionHandler.isActive then
        return
    end

    Log:debug("Starting vehicle proximity detection")
    g_currentMission:addUpdateable(RmVehicleDetectionHandler)
    RmVehicleDetectionHandler.isActive = true
    Log:info("Vehicle proximity detection active")
end

--- Stop proximity detection (unregister from updates)
function RmVehicleDetectionHandler.stopDetection()
    if not RmVehicleDetectionHandler.isActive then
        return
    end

    -- Clear keybind
    RmVehicleDetectionHandler.hideKeybind()

    -- Clear tracked vehicles
    RmVehicleDetectionHandler.nearbyVehicles = {}
    RmVehicleDetectionHandler.currentVehicle = nil

    -- Unregister from update
    if g_currentMission ~= nil then
        g_currentMission:removeUpdateable(RmVehicleDetectionHandler)
    end

    RmVehicleDetectionHandler.isActive = false
end

--- Update function - check proximity to vehicles
---@param dt number Delta time in milliseconds
function RmVehicleDetectionHandler:update(dt)
    -- Run periodic cleanup of stale vehicles
    RmVehicleDetectionHandler.lastCleanupTime = RmVehicleDetectionHandler.lastCleanupTime + dt
    if RmVehicleDetectionHandler.lastCleanupTime >= RmVehicleDetectionHandler.CLEANUP_INTERVAL then
        RmVehicleDetectionHandler.lastCleanupTime = 0
        RmVehicleDetectionHandler.cleanupStaleVehicles()
    end

    -- Get player position
    local player = g_localPlayer
    if player == nil or player.rootNode == nil then
        return
    end

    -- Don't detect when player is in a vehicle
    if player.isEntered == false then
        -- Player is in a vehicle, hide keybind if showing
        if RmVehicleDetectionHandler.currentVehicle ~= nil then
            RmVehicleDetectionHandler.hideKeybind()
            RmVehicleDetectionHandler.currentVehicle = nil
            RmVehicleDetectionHandler.nearbyVehicles = {}
        end
        return
    end

    local px, py, pz = getWorldTranslation(player.rootNode)
    local radius = RmVehicleDetectionHandler.PROXIMITY_RADIUS

    -- Find closest valid vehicle
    local closestVehicle = nil
    local closestDistance = radius + 1

    -- FS25 stores vehicles in vehicleSystem.vehicles
    local vehicleList = {}
    if g_currentMission.vehicleSystem ~= nil then
        vehicleList = g_currentMission.vehicleSystem.vehicles or {}
    end

    for _, vehicle in pairs(vehicleList) do
        if RmVehicleDetectionHandler.canHandleVehicle(vehicle) then
            local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
            local distance = MathUtil.vector3Length(vx - px, vy - py, vz - pz)

            if distance <= radius and distance < closestDistance then
                closestVehicle = vehicle
                closestDistance = distance
            end
        end
    end

    -- Update state based on detection
    if closestVehicle ~= nil then
        if RmVehicleDetectionHandler.currentVehicle ~= closestVehicle then
            RmVehicleDetectionHandler.onVehicleEnterRange(closestVehicle)
        end
    else
        if RmVehicleDetectionHandler.currentVehicle ~= nil then
            RmVehicleDetectionHandler.onVehicleLeaveRange(RmVehicleDetectionHandler.currentVehicle)
        end
    end
end

--- Check if a vehicle can be handled (has FillUnit with fill units and our specialization)
---@param vehicle table|nil The vehicle to check
---@return boolean canHandle True if vehicle can be handled
function RmVehicleDetectionHandler.canHandleVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    -- Must be a Vehicle
    if vehicle.isa == nil or not vehicle:isa(Vehicle) then
        return false
    end

    -- Must have FillUnit specialization with fill units
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil or #fillUnitSpec.fillUnits == 0 then
        return false
    end

    -- Must have our specialization
    local spec = vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return false
    end

    return true
end

--- Called when a vehicle enters detection range
---@param vehicle table The vehicle
function RmVehicleDetectionHandler.onVehicleEnterRange(vehicle)
    Log:debug("Vehicle entered range: %s", vehicle:getName())

    RmVehicleDetectionHandler.nearbyVehicles[vehicle] = g_currentMission.time
    RmVehicleDetectionHandler.currentVehicle = vehicle

    -- Show keybind
    RmVehicleDetectionHandler.showKeybind(vehicle)
end

--- Called when a vehicle leaves detection range
---@param vehicle table The vehicle
function RmVehicleDetectionHandler.onVehicleLeaveRange(vehicle)
    Log:debug("Vehicle left range: %s", vehicle:getName())

    RmVehicleDetectionHandler.nearbyVehicles[vehicle] = nil
    RmVehicleDetectionHandler.hideKeybind()
    RmVehicleDetectionHandler.currentVehicle = nil
end

--- Cleanup vehicles that are no longer valid
function RmVehicleDetectionHandler.cleanupStaleVehicles()
    for vehicle, _ in pairs(RmVehicleDetectionHandler.nearbyVehicles) do
        -- Remove if vehicle is deleted
        if vehicle == nil or vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then
            RmVehicleDetectionHandler.nearbyVehicles[vehicle] = nil
            if RmVehicleDetectionHandler.currentVehicle == vehicle then
                RmVehicleDetectionHandler.hideKeybind()
                RmVehicleDetectionHandler.currentVehicle = nil
            end
        end
    end
end

--- Show the K keybind for adjusting vehicle capacity
---@param vehicle table The vehicle
function RmVehicleDetectionHandler.showKeybind(vehicle)
    -- Check permission first
    local canModify, _ = RmAdjustStorageCapacity:canModifyVehicleCapacity(vehicle)
    if not canModify then
        Log:debug("No permission to modify vehicle %s", vehicle:getName())
        return
    end

    -- Don't register if already registered
    if RmVehicleDetectionHandler.actionEventId ~= nil then
        return
    end

    -- Register the K keybind
    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_ADJUST_STORAGE_CAPACITY,
        RmVehicleDetectionHandler,
        RmVehicleDetectionHandler.onAdjustCapacityAction,
        false, -- triggerUp
        true,  -- triggerDown
        false, -- triggerAlways
        true   -- isActive
    )

    if actionEventId ~= nil then
        g_inputBinding:setActionEventText(actionEventId, g_i18n:getText("rm_asc_action_adjustVehicleCapacity"))
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)

        RmVehicleDetectionHandler.actionEventId = actionEventId
        Log:debug("Registered K keybind for %s", vehicle:getName())
    else
        Log:warning("Failed to register K keybind")
    end
end

--- Hide the K keybind
function RmVehicleDetectionHandler.hideKeybind()
    if RmVehicleDetectionHandler.actionEventId ~= nil then
        g_inputBinding:removeActionEvent(RmVehicleDetectionHandler.actionEventId)
        RmVehicleDetectionHandler.actionEventId = nil
        local vehicleName = RmVehicleDetectionHandler.currentVehicle and RmVehicleDetectionHandler.currentVehicle:getName() or "unknown"
        Log:debug("Unregistered K keybind for %s", vehicleName)
    end
end

--- Handle K key press to open capacity dialog
---@param actionName string The action name
---@param inputValue number The input value
function RmVehicleDetectionHandler.onAdjustCapacityAction(actionName, inputValue)
    local vehicle = RmVehicleDetectionHandler.currentVehicle

    if vehicle == nil then
        Log:warning("K pressed but no current vehicle")
        return
    end

    Log:debug("K pressed for %s", vehicle:getName())

    -- Check permission
    local canModify, errorKey = RmAdjustStorageCapacity:canModifyVehicleCapacity(vehicle)
    if not canModify then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey))
        return
    end

    -- Show dialog
    RmVehicleCapacityDialog.show(vehicle)
end
