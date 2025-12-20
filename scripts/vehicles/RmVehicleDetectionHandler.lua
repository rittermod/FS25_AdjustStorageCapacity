-- RmVehicleDetectionHandler - Player proximity detection for vehicle capacity adjustment
-- Author: Ritter
--
-- Detects nearby vehicles using distance checks in update loop.
-- When player walks near a supported vehicle, creates an activatable that
-- uses FS25's activatableObjectsSystem for proper input context handling.
--
-- This solves the K keybind getting stuck when entering/exiting vehicles
-- by letting the game's built-in system handle input context transitions.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmVehicleDetectionHandler = {}

-- Configuration
RmVehicleDetectionHandler.PROXIMITY_RADIUS = 4.0    -- meters
RmVehicleDetectionHandler.CLEANUP_INTERVAL = 2000   -- ms

-- State
RmVehicleDetectionHandler.initialized = false
RmVehicleDetectionHandler.isActive = false
RmVehicleDetectionHandler.vehicleActivatables = {}  -- {[vehicle] = activatable}
RmVehicleDetectionHandler.lastCleanupTime = 0
RmVehicleDetectionHandler.loggedVehicles = {}       -- {[vehicle] = true} - tracks which vehicles we've logged

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

    Log:info("Vehicle detection handler initialized (using activatable pattern)")
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

    -- Remove all activatables
    RmVehicleDetectionHandler.removeAllActivatables()

    -- Clear tracking state
    RmVehicleDetectionHandler.loggedVehicles = {}

    -- Unregister from update
    if g_currentMission ~= nil then
        g_currentMission:removeUpdateable(RmVehicleDetectionHandler)
    end

    RmVehicleDetectionHandler.isActive = false
    Log:debug("Vehicle proximity detection stopped")
end

--- Remove all tracked activatables from the system
function RmVehicleDetectionHandler.removeAllActivatables()
    for vehicle, activatable in pairs(RmVehicleDetectionHandler.vehicleActivatables) do
        if activatable ~= nil and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
        end
    end
    RmVehicleDetectionHandler.vehicleActivatables = {}
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

    -- NOTE: We no longer check player.isEntered here.
    -- The activatableObjectsSystem handles input context transitions automatically.
    -- When player enters a vehicle, context changes from PLAYER to VEHICLE,
    -- and registerCustomInput is called with the new context (which we ignore).

    local px, py, pz = getWorldTranslation(player.rootNode)
    local radius = RmVehicleDetectionHandler.PROXIMITY_RADIUS

    -- Track which vehicles are currently in range
    local vehiclesInRange = {}

    -- FS25 stores vehicles in vehicleSystem.vehicles
    local vehicleList = {}
    if g_currentMission.vehicleSystem ~= nil then
        vehicleList = g_currentMission.vehicleSystem.vehicles or {}
    end

    for _, vehicle in pairs(vehicleList) do
        if RmVehicleDetectionHandler.canHandleVehicle(vehicle) then
            local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
            local distance = MathUtil.vector3Length(vx - px, vy - py, vz - pz)

            if distance <= radius then
                vehiclesInRange[vehicle] = true

                -- Add activatable if not already tracked
                if RmVehicleDetectionHandler.vehicleActivatables[vehicle] == nil then
                    RmVehicleDetectionHandler.onVehicleEnterRange(vehicle)
                end
            end
        end
    end

    -- Remove activatables for vehicles that left range
    for vehicle, activatable in pairs(RmVehicleDetectionHandler.vehicleActivatables) do
        if not vehiclesInRange[vehicle] then
            RmVehicleDetectionHandler.onVehicleLeaveRange(vehicle)
        end
    end
end

--- Get a list of specialization names for a vehicle (for debug logging)
---@param vehicle table The vehicle to inspect
---@return string specList Comma-separated list of specialization short names
function RmVehicleDetectionHandler.getVehicleSpecializations(vehicle)
    local specs = {}

    -- Method 1: Check spec_* tables on the vehicle
    for key, _ in pairs(vehicle) do
        if type(key) == "string" and key:sub(1, 5) == "spec_" then
            -- Extract short name: "spec_fillUnit" -> "fillUnit"
            local shortName = key:sub(6)
            -- Skip our mod's spec prefix for cleaner output
            if not shortName:find("^FS25_") then
                table.insert(specs, shortName)
            else
                -- Extract just the spec name after mod prefix: "FS25_ModName.specName" -> "specName"
                local dotPos = shortName:find("%.")
                if dotPos then
                    table.insert(specs, shortName:sub(dotPos + 1))
                end
            end
        end
    end

    table.sort(specs)
    return table.concat(specs, ", ")
end

--- Get the vehicle type name for debug logging
---@param vehicle table The vehicle to inspect
---@return string typeName The vehicle type name
function RmVehicleDetectionHandler.getVehicleTypeName(vehicle)
    if vehicle.typeName then
        return vehicle.typeName
    end
    if vehicle.typeDesc and vehicle.typeDesc.name then
        return vehicle.typeDesc.name
    end
    return "unknown"
end

--- Check if a vehicle can be handled (has FillUnit with fill units and our specialization)
---@param vehicle table|nil The vehicle to check
---@return boolean canHandle True if vehicle can be handled
function RmVehicleDetectionHandler.canHandleVehicle(vehicle)
    -- Use central eligibility check
    local isSupported, reason = RmVehicleStorageCapacity.isVehicleSupported(vehicle)

    -- Debug log: Only log each vehicle once to avoid spam
    local shouldLog = vehicle ~= nil and not RmVehicleDetectionHandler.loggedVehicles[vehicle]
    if shouldLog then
        RmVehicleDetectionHandler.loggedVehicles[vehicle] = true

        local fillUnitCount = 0
        if vehicle.spec_fillUnit and vehicle.spec_fillUnit.fillUnits then
            fillUnitCount = #vehicle.spec_fillUnit.fillUnits
        end

        if isSupported then
            Log:debug("Vehicle ACCEPTED: name=%s, type=%s, fillUnits=%d, specs=[%s]",
                vehicle:getName(),
                RmVehicleDetectionHandler.getVehicleTypeName(vehicle),
                fillUnitCount,
                RmVehicleDetectionHandler.getVehicleSpecializations(vehicle))
        else
            Log:debug("Vehicle SKIPPED (%s): name=%s, type=%s, fillUnits=%d, specs=[%s]",
                reason,
                vehicle:getName(),
                RmVehicleDetectionHandler.getVehicleTypeName(vehicle),
                fillUnitCount,
                RmVehicleDetectionHandler.getVehicleSpecializations(vehicle))
        end
    end

    return isSupported
end

--- Called when a vehicle enters detection range
--- Creates an activatable and adds it to the activatableObjectsSystem
---@param vehicle table The vehicle
function RmVehicleDetectionHandler.onVehicleEnterRange(vehicle)
    Log:debug("Vehicle entered range: %s", vehicle:getName())

    -- Create activatable for this vehicle
    local activatable = RmVehicleCapacityActivatable.new(vehicle)
    RmVehicleDetectionHandler.vehicleActivatables[vehicle] = activatable

    -- Add to activatable system - it will handle input registration
    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:addActivatable(activatable)
        Log:debug("Added activatable for vehicle: %s", vehicle:getName())
    end
end

--- Called when a vehicle leaves detection range
--- Removes the activatable from the activatableObjectsSystem
---@param vehicle table The vehicle
function RmVehicleDetectionHandler.onVehicleLeaveRange(vehicle)
    Log:debug("Vehicle left range: %s", vehicle:getName())

    local activatable = RmVehicleDetectionHandler.vehicleActivatables[vehicle]
    if activatable ~= nil then
        -- Remove from activatable system - it will handle input cleanup
        if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
            Log:debug("Removed activatable for vehicle: %s", vehicle:getName())
        end
    end

    RmVehicleDetectionHandler.vehicleActivatables[vehicle] = nil
end

--- Cleanup vehicles that are no longer valid (deleted, etc.)
function RmVehicleDetectionHandler.cleanupStaleVehicles()
    for vehicle, activatable in pairs(RmVehicleDetectionHandler.vehicleActivatables) do
        -- Remove if vehicle is deleted
        if vehicle == nil or vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then
            Log:debug("Cleaning up stale vehicle activatable (vehicle deleted)")
            if activatable ~= nil and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
                g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
            end
            RmVehicleDetectionHandler.vehicleActivatables[vehicle] = nil
            RmVehicleDetectionHandler.loggedVehicles[vehicle] = nil
        end
    end

    -- Also clean up logged vehicles cache for deleted vehicles
    for vehicle, _ in pairs(RmVehicleDetectionHandler.loggedVehicles) do
        if vehicle == nil or vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then
            RmVehicleDetectionHandler.loggedVehicles[vehicle] = nil
        end
    end
end
