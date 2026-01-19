-- RmPlaceableCapacityActivatable - Activatable for placeable capacity adjustment
-- Author: Ritter
--
-- Uses FS25's activatable pattern for proper input context handling.
-- This solves the K keybind getting stuck when entering vehicles from trigger zones.
--
-- Unlike vehicles (distance-based detection), placeables use PlaceableInfoTrigger events.
-- The activatable is added/removed when player enters/leaves the trigger zone.
--
-- The activatableObjectsSystem manages:
-- - Calling registerCustomInput/removeCustomInput at appropriate times
-- - Handling input context transitions (PLAYER <-> VEHICLE)
-- - Priority sorting when multiple activatables are present

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

-- Defensive fallback for player context constant
-- Guards against the constant not being accessible from mod code at runtime
local PLAYER_CONTEXT = (PlayerInputComponent and PlayerInputComponent.INPUT_CONTEXT_NAME) or "PLAYER"

RmPlaceableCapacityActivatable = {}
local RmPlaceableCapacityActivatable_mt = Class(RmPlaceableCapacityActivatable)

--- Create new activatable for a placeable
---@param placeable table The placeable
---@return table activatable
function RmPlaceableCapacityActivatable.new(placeable)
    local self = setmetatable({}, RmPlaceableCapacityActivatable_mt)

    self.placeable = placeable
    self.activateText = g_i18n:getText("rm_asc_action_adjustCapacity")
    self.actionEventId = nil

    local placeableName = placeable and placeable:getName() or "unknown"
    Log:debug("[PlaceableActivatable] Created for placeable: %s", placeableName)

    return self
end

--- Check if this activatable can be activated
--- Called by activatableObjectsSystem to determine visibility
---@return boolean
function RmPlaceableCapacityActivatable:getIsActivatable()
    if self.placeable == nil then
        return false
    end

    -- Check if placeable still exists
    if self.placeable.rootNode == nil or not entityExists(self.placeable.rootNode) then
        return false
    end

    -- Check if placeable has modifiable storage
    local spec = self.placeable[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil or spec.storageTypes == nil or #spec.storageTypes == 0 then
        return false
    end

    -- Check if player has permission to modify
    local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(self.placeable)
    return canModify
end

--- Get distance from player position to this placeable
--- Uses actual distance for fair priority with other activatables (like animal triggers)
---@param x number Player X position
---@param y number Player Y position
---@param z number Player Z position
---@return number distance
function RmPlaceableCapacityActivatable:getDistance(x, y, z)
    if self.placeable == nil or self.placeable.rootNode == nil then
        return math.huge
    end

    if not entityExists(self.placeable.rootNode) then
        return math.huge
    end

    local px, py, pz = getWorldTranslation(self.placeable.rootNode)
    return MathUtil.vector3Length(x - px, y - py, z - pz)
end

--- Register custom input (K key) - called by activatableObjectsSystem
--- CRITICAL: Only registers when in player on-foot context to prevent
--- registration failures during input context transitions.
---@param inputContext string The current input context
function RmPlaceableCapacityActivatable:registerCustomInput(inputContext)
    local placeableName = self.placeable and self.placeable:getName() or "unknown"
    Log:debug("[PlaceableActivatable] registerCustomInput called (context=%s, expected=%s) for: %s",
        tostring(inputContext), PLAYER_CONTEXT, placeableName)

    -- Only allow registration in player (on-foot) context
    -- This prevents failed registrations during context transitions
    -- (e.g., when player is entering a vehicle while still in trigger)
    if inputContext ~= PLAYER_CONTEXT then
        Log:debug("[PlaceableActivatable] Skipping registration - wrong context")
        return
    end

    Log:debug("[PlaceableActivatable] Registering K keybind for: %s", placeableName)

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_ADJUST_STORAGE_CAPACITY,
        self,
        self.onKeybindPressed,
        false, -- triggerUp
        true,  -- triggerDown
        false, -- triggerAlways
        true   -- isActive
    )

    if actionEventId ~= nil and actionEventId ~= "" then
        self.actionEventId = actionEventId
        g_inputBinding:setActionEventText(actionEventId, self.activateText)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
        Log:debug("[PlaceableActivatable] Registration SUCCESS: actionEventId=%s", tostring(actionEventId))
    else
        Log:warning("[PlaceableActivatable] Registration FAILED for: %s", placeableName)
    end
end

--- Remove custom input - called by activatableObjectsSystem
--- Uses removeActionEventsByTarget to clean ALL events registered with self as target.
--- This is the recommended FS25 pattern for clean removal regardless of context.
---@param inputContext string The current input context (unused but required by interface)
function RmPlaceableCapacityActivatable:removeCustomInput(inputContext)
    local placeableName = self.placeable and self.placeable:getName() or "nil"
    Log:debug("[PlaceableActivatable] removeCustomInput called (context=%s) for: %s",
        tostring(inputContext), placeableName)

    -- Remove all action events registered with this activatable as target
    -- This works regardless of current input context
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
    Log:debug("[PlaceableActivatable] K keybind removed for: %s", placeableName)
end

--- Called when K is pressed - opens the placeable capacity dialog
---@param actionName string The action name (unused)
---@param inputValue number The input value (unused)
function RmPlaceableCapacityActivatable:onKeybindPressed(actionName, inputValue)
    if self.placeable == nil then
        Log:warning("[PlaceableActivatable] K pressed but placeable is nil")
        return
    end

    local placeableName = self.placeable:getName() or "unknown"
    Log:debug("[PlaceableActivatable] K pressed for: %s", placeableName)

    -- Double-check permission (player state may have changed)
    local canModify, errorKey = RmAdjustStorageCapacity:canModifyCapacity(self.placeable)
    if not canModify then
        Log:debug("[PlaceableActivatable] Permission denied for: %s (reason=%s)", placeableName, tostring(errorKey))
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey)
        )
        return
    end

    -- Open placeable capacity dialog
    RmStorageCapacityDialog.show(self.placeable)
end

--- Called when activatable becomes active (player enters range)
--- Optional: can be used for additional setup
function RmPlaceableCapacityActivatable:activate()
    -- Nothing needed - registration handled by registerCustomInput
end

--- Called when activatable becomes inactive (player leaves range)
--- Optional: can be used for cleanup
function RmPlaceableCapacityActivatable:deactivate()
    -- Nothing needed - cleanup handled by removeCustomInput
end

--- Empty run function - we use custom input instead of the default activate action
function RmPlaceableCapacityActivatable:run()
    -- We use registerCustomInput for our K keybind instead of the default run action
end
