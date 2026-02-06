-- RmVehicleCapacityActivatable - Activatable for vehicle capacity adjustment
-- Author: Ritter
--
-- Uses FS25's activatable pattern for proper input context handling.
-- This solves the K keybind getting stuck when entering/exiting vehicles.
--
-- The activatableObjectsSystem manages:
-- - Calling registerCustomInput/removeCustomInput at appropriate times
-- - Handling input context transitions (PLAYER <-> VEHICLE)
-- - Proximity-based activation

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

-- Defensive fallback for player context constant
-- Guards against the constant not being accessible from mod code at runtime
local PLAYER_CONTEXT = (PlayerInputComponent and PlayerInputComponent.INPUT_CONTEXT_NAME) or "PLAYER"

-- Distance penalty to yield priority to native triggers at same location
-- This ensures ASC's K keybind doesn't occlude other activatables
local DISTANCE_PENALTY = 0.5  -- meters

--- Check if any other (non-ASC) activatable is currently active
--- If so, yield priority to avoid occluding native triggers.
---@param selfActivatable table The ASC activatable to check against
---@return boolean true if we should yield (another activatable is active)
local function shouldYieldToOtherActivatable(selfActivatable)
    local system = g_currentMission and g_currentMission.activatableObjectsSystem
    if system == nil then
        return false
    end

    -- Check all other activatables
    for _, other in pairs(system.objects) do
        -- Skip ourselves
        if other ~= selfActivatable then
            -- Check if it's an ASC activatable (has our unique marker)
            local isAscActivatable = (other.isRmAscActivatable == true)

            if not isAscActivatable then
                -- Check if other is currently activatable
                local otherActive = other.getIsActivatable == nil or other:getIsActivatable(system.dirX, system.dirY, system.dirZ)
                if otherActive then
                    return true  -- Yield to any active non-ASC activatable
                end
            end
        end
    end

    return false
end

RmVehicleCapacityActivatable = {}
local RmVehicleCapacityActivatable_mt = Class(RmVehicleCapacityActivatable)

--- Create new activatable for a vehicle
---@param vehicle table The vehicle
---@return table activatable
function RmVehicleCapacityActivatable.new(vehicle)
    local self = setmetatable({}, RmVehicleCapacityActivatable_mt)

    self.vehicle = vehicle
    self.activateText = g_i18n:getText("rm_asc_action_adjustVehicleCapacity")
    self.isRmAscActivatable = true  -- Unique marker to identify ASC activatables

    local vehicleName = vehicle and vehicle:getName() or "unknown"
    Log:debug("[Activatable] Created for vehicle: %s", vehicleName)

    return self
end

--- Check if this activatable can be activated
--- Called by activatableObjectsSystem to determine visibility
---@return boolean
function RmVehicleCapacityActivatable:getIsActivatable()
    if self.vehicle == nil or self.vehicle.rootNode == nil then
        return false
    end

    -- Check if trigger shortcuts are disabled in settings
    if not RmAscSettings.isShortcutEnabled() then
        return false
    end

    -- Check if vehicle still exists
    if not entityExists(self.vehicle.rootNode) then
        return false
    end

    -- Check if vehicle is supported (has FillUnit, not a leveler, etc.)
    local isSupported = RmVehicleStorageCapacity.isVehicleSupported(self.vehicle)
    if not isSupported then
        return false
    end

    -- Check if player has permission to modify
    local canModify, _ = RmAdjustStorageCapacity:canModifyVehicleCapacity(self.vehicle)
    if not canModify then
        return false
    end

    -- DYNAMIC YIELD: If any other (non-ASC) activatable is closer or at equal distance,
    -- yield priority by returning false. This prevents ASC from occluding native triggers.
    if shouldYieldToOtherActivatable(self) then
        return false
    end

    return true
end

--- Get distance from player position to this vehicle
--- Used by activatableObjectsSystem for proximity sorting
---@param x number Player X position
---@param y number Player Y position
---@param z number Player Z position
---@return number distance
function RmVehicleCapacityActivatable:getDistance(x, y, z)
    if self.vehicle == nil or self.vehicle.rootNode == nil then
        return math.huge
    end

    if not entityExists(self.vehicle.rootNode) then
        return math.huge
    end

    local vx, vy, vz = getWorldTranslation(self.vehicle.rootNode)
    local baseDistance = MathUtil.vector3Length(x - vx, y - vy, z - vz)

    -- Add penalty so ASC yields to native triggers at equal distance
    return baseDistance + DISTANCE_PENALTY
end

--- Register custom input (K key) - called by activatableObjectsSystem
--- CRITICAL: Only registers when in player on-foot context to prevent
--- registration failures during input context transitions.
---@param inputContext string The current input context
function RmVehicleCapacityActivatable:registerCustomInput(inputContext)
    local vehicleName = self.vehicle and self.vehicle:getName() or "unknown"
    Log:debug("[Activatable] registerCustomInput called (context=%s, expected=%s) for vehicle: %s",
        tostring(inputContext), PLAYER_CONTEXT, vehicleName)

    -- Only allow registration in player (on-foot) context
    -- This prevents failed registrations during context transitions
    -- (e.g., when player is entering a vehicle while still in trigger)
    if inputContext ~= PLAYER_CONTEXT then
        Log:debug("[Activatable] Skipping registration - wrong context")
        return
    end

    Log:debug("[Activatable] Registering K keybind for vehicle: %s", vehicleName)

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_ADJUST_STORAGE_CAPACITY,
        self,
        self.onKeybindPressed,
        false,  -- triggerUp
        true,   -- triggerDown
        false,  -- triggerAlways
        true    -- isActive
    )

    if actionEventId ~= nil and actionEventId ~= "" then
        self.actionEventId = actionEventId
        g_inputBinding:setActionEventText(actionEventId, self.activateText)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
        Log:debug("[Activatable] Registration SUCCESS: actionEventId=%s", tostring(actionEventId))
    else
        Log:warning("[Activatable] Registration FAILED for vehicle: %s", vehicleName)
    end
end

--- Remove custom input - called by activatableObjectsSystem
--- Uses removeActionEventsByTarget to clean ALL events registered with self as target.
--- This is the recommended FS25 pattern for clean removal regardless of context.
---@param inputContext string The current input context (unused but required by interface)
function RmVehicleCapacityActivatable:removeCustomInput(inputContext)
    local vehicleName = self.vehicle and self.vehicle:getName() or "nil"
    Log:debug("[Activatable] removeCustomInput called (context=%s) for vehicle: %s",
        tostring(inputContext), vehicleName)

    -- Remove all action events registered with this activatable as target
    -- This works regardless of current input context
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
    Log:debug("[Activatable] K keybind removed for vehicle: %s", vehicleName)
end

--- Called when K is pressed - opens the vehicle capacity dialog
---@param actionName string The action name (unused)
---@param inputValue number The input value (unused)
function RmVehicleCapacityActivatable:onKeybindPressed(actionName, inputValue)
    if self.vehicle == nil then
        Log:warning("[Activatable] K pressed but vehicle is nil")
        return
    end

    local vehicleName = self.vehicle:getName() or "unknown"
    Log:debug("[Activatable] K pressed for vehicle: %s", vehicleName)

    -- Double-check permission (player state may have changed)
    local canModify, errorKey = RmAdjustStorageCapacity:canModifyVehicleCapacity(self.vehicle)
    if not canModify then
        Log:debug("[Activatable] Permission denied for vehicle: %s (reason=%s)", vehicleName, tostring(errorKey))
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey)
        )
        return
    end

    -- Open vehicle capacity dialog
    RmVehicleCapacityDialog.show(self.vehicle)
end

--- Called when activatable becomes active (player enters range)
--- Optional: can be used for additional setup
function RmVehicleCapacityActivatable:activate()
    -- Nothing needed - registration handled by registerCustomInput
end

--- Called when activatable becomes inactive (player leaves range)
--- Optional: can be used for cleanup
function RmVehicleCapacityActivatable:deactivate()
    -- Nothing needed - cleanup handled by removeCustomInput
end

--- Empty run function - we use custom input instead of the default activate action
function RmVehicleCapacityActivatable:run()
    -- We use registerCustomInput for our K keybind instead of the default run action
end
