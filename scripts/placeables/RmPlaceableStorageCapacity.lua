-- RmPlaceableStorageCapacity - Specialization for adding capacity adjustment to storage placeables
-- Author: Ritter
--
-- This specialization adds the ability to adjust storage capacity for silos, productions, and husbandries.
-- It uses PlaceableInfoTrigger events to detect when player enters/leaves the trigger area
-- and registers the K keybind for opening the capacity dialog.
--
-- Supports:
-- - PlaceableSilo (spec_silo.storages[])
-- - PlaceableProductionPoint (spec_productionPoint.productionPoint.storage)
-- - PlaceableHusbandry (spec_husbandry.storage for output, spec_husbandryFood for food)
--
-- NOT Supported:
-- - BunkerSilo (terrain heap-based, no capacity property)

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmPlaceableStorageCapacity = {}

RmPlaceableStorageCapacity.MOD_NAME = g_currentModName
RmPlaceableStorageCapacity.SPEC_NAME = string.format("%s.storageCapacity", g_currentModName)
RmPlaceableStorageCapacity.SPEC_TABLE_NAME = string.format("spec_%s", RmPlaceableStorageCapacity.SPEC_NAME)

--- Check if this specialization can be added
--- Returns true if placeable has storage we can modify (silo, husbandry, or production point)
function RmPlaceableStorageCapacity.prerequisitesPresent(specializations)
    -- Check for any storage-related specialization
    if SpecializationUtil.hasSpecialization(PlaceableSilo, specializations) then
        return true
    end
    if SpecializationUtil.hasSpecialization(PlaceableHusbandry, specializations) then
        return true
    end
    if SpecializationUtil.hasSpecialization(PlaceableProductionPoint, specializations) then
        return true
    end
    return false
end

--- Register event listeners for this specialization
function RmPlaceableStorageCapacity.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onPostLoad", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", RmPlaceableStorageCapacity)
    -- PlaceableInfoTrigger events - fired when player enters/leaves the info trigger area
    SpecializationUtil.registerEventListener(placeableType, "onInfoTriggerEnter", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onInfoTriggerLeave", RmPlaceableStorageCapacity)
end

--- Called when placeable is loaded
function RmPlaceableStorageCapacity:onLoad(savegame)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME] = {}
        spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    end

    spec.storageTypes = {} -- Which storage types this placeable has
    spec.capacityActionEventId = nil -- Input action event ID for K keybind

    Log:debug("onLoad: %s", self:getName())
end

--- Called after placeable loads - detect storage types
function RmPlaceableStorageCapacity:onPostLoad(savegame)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]

    -- Detect which storage types are present
    spec.storageTypes = RmPlaceableStorageCapacity.detectStorageTypes(self)

    if #spec.storageTypes == 0 then
        Log:debug("onPostLoad: %s has no modifiable storage", self:getName())
        return
    end

    -- Capture original capacity before any ReadStream modifications
    -- This must happen here (not in onMissionStarted) because ReadStream runs before mission start
    RmAdjustStorageCapacity:captureOriginalCapacities(self)

    Log:debug("onPostLoad complete: %s (storage types: %s)",
        self:getName(), table.concat(spec.storageTypes, ", "))
end

--- Detect which storage types are present on this placeable
---@return table Array of storage type strings
function RmPlaceableStorageCapacity:detectStorageTypes()
    local types = {}

    if self.spec_silo ~= nil and self.spec_silo.storages ~= nil and #self.spec_silo.storages > 0 then
        table.insert(types, RmAdjustStorageCapacity.STORAGE_TYPE.SILO)
    end

    if self.spec_productionPoint ~= nil and self.spec_productionPoint.productionPoint ~= nil then
        local pp = self.spec_productionPoint.productionPoint
        if pp.storage ~= nil then
            table.insert(types, RmAdjustStorageCapacity.STORAGE_TYPE.PRODUCTION)
        end
    end

    if self.spec_husbandry ~= nil and self.spec_husbandry.storage ~= nil then
        table.insert(types, RmAdjustStorageCapacity.STORAGE_TYPE.HUSBANDRY)
    end

    if self.spec_husbandryFood ~= nil then
        table.insert(types, RmAdjustStorageCapacity.STORAGE_TYPE.HUSBANDRY_FOOD)
    end

    return types
end

--- Called when player enters the info trigger area
--- Register our K keybind for capacity adjustment
---@param otherId number The player/entity node that entered
function RmPlaceableStorageCapacity:onInfoTriggerEnter(otherId)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return
    end

    -- Only respond if we have modifiable storage
    if spec.storageTypes == nil or #spec.storageTypes == 0 then
        return
    end

    -- Check permission before showing keybind
    local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(self)
    if not canModify then
        return  -- Don't show K for unauthorized players
    end

    -- Don't register if already registered
    if spec.capacityActionEventId ~= nil then
        return
    end

    -- Register our K keybind
    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_ADJUST_STORAGE_CAPACITY,
        self,
        RmPlaceableStorageCapacity.actionEventAdjustCapacity,
        false, -- triggerUp
        true,  -- triggerDown
        false, -- triggerAlways
        true   -- isActive
    )

    if actionEventId ~= nil then
        g_inputBinding:setActionEventText(actionEventId, g_i18n:getText("rm_asc_action_adjustCapacity"))
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)

        spec.capacityActionEventId = actionEventId

        Log:debug("Registered K keybind for %s", self:getName())
    else
        Log:warning("Failed to register K keybind for %s", self:getName())
    end
end

--- Called when player leaves the info trigger area
--- Unregister our K keybind
---@param otherId number The player/entity node that left
function RmPlaceableStorageCapacity:onInfoTriggerLeave(otherId)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return
    end

    -- Remove our K keybind if registered
    if spec.capacityActionEventId ~= nil then
        g_inputBinding:removeActionEvent(spec.capacityActionEventId)
        spec.capacityActionEventId = nil

        Log:debug("Unregistered K keybind for %s", self:getName())
    end
end

--- Handle K key press to open capacity dialog
---@param actionName string The action name
---@param inputValue number The input value
---@param callbackState any Callback state
---@param isAnalog boolean Whether input is analog
function RmPlaceableStorageCapacity:actionEventAdjustCapacity(actionName, inputValue, callbackState, isAnalog)
    Log:debug("K pressed for %s", self:getName())

    -- Check permission
    local canModify, errorKey = RmAdjustStorageCapacity:canModifyCapacity(self)
    if not canModify then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey))
        return
    end

    -- Show capacity dialog
    RmAdjustStorageCapacity:showCapacityDialog(self)
end

--- Called when placeable is deleted/sold - clean up data
function RmPlaceableStorageCapacity:onDelete()
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]

    -- Clean up any active action event
    if spec ~= nil and spec.capacityActionEventId ~= nil then
        g_inputBinding:removeActionEvent(spec.capacityActionEventId)
        spec.capacityActionEventId = nil
    end

    local uniqueId = self.uniqueId

    if uniqueId ~= nil then
        local hadCustomCapacity = RmAdjustStorageCapacity.customCapacities[uniqueId] ~= nil

        -- Clean up custom capacities
        RmAdjustStorageCapacity.customCapacities[uniqueId] = nil
        RmAdjustStorageCapacity.originalCapacities[uniqueId] = nil

        if hadCustomCapacity then
            Log:debug("Cleaned up custom capacities for deleted storage: %s", self:getName() or uniqueId)
        end
    end
end

--- Called on server side when syncing placeable to a new client
---@param streamId number Network stream ID
---@param connection table Network connection
function RmPlaceableStorageCapacity:onWriteStream(streamId, connection)
    local uniqueId = self.uniqueId
    local customCapacity = RmAdjustStorageCapacity.customCapacities[uniqueId]

    -- Send custom capacity data if present
    if streamWriteBool(streamId, customCapacity ~= nil) then
        -- Write fill type capacities count
        local fillTypeCount = 0
        if customCapacity.fillTypes ~= nil then
            for _ in pairs(customCapacity.fillTypes) do
                fillTypeCount = fillTypeCount + 1
            end
        end
        streamWriteInt32(streamId, fillTypeCount)

        -- Write each fill type capacity
        if customCapacity.fillTypes ~= nil then
            for fillTypeIndex, capacity in pairs(customCapacity.fillTypes) do
                streamWriteInt32(streamId, fillTypeIndex)
                streamWriteInt32(streamId, capacity)
            end
        end

        -- Write husbandry food capacity
        if streamWriteBool(streamId, customCapacity.husbandryFood ~= nil) then
            streamWriteInt32(streamId, customCapacity.husbandryFood)
        end

        -- Write shared capacity
        if streamWriteBool(streamId, customCapacity.sharedCapacity ~= nil) then
            streamWriteInt32(streamId, customCapacity.sharedCapacity)
        end

        -- Count total capacities sent
        local totalCount = fillTypeCount
        if customCapacity.husbandryFood ~= nil then totalCount = totalCount + 1 end
        if customCapacity.sharedCapacity ~= nil then totalCount = totalCount + 1 end

        Log:debug("WriteStream: Sent %d custom capacities for %s", totalCount, self:getName())
    end
end

--- Called on client side when receiving placeable sync from server
---@param streamId number Network stream ID
---@param connection table Network connection
function RmPlaceableStorageCapacity:onReadStream(streamId, connection)
    local uniqueId = self.uniqueId

    -- Read custom capacity data if present
    if streamReadBool(streamId) then
        local entry = {
            fillTypes = {},
            husbandryFood = nil,
            sharedCapacity = nil
        }

        -- Read fill type capacities
        local fillTypeCount = streamReadInt32(streamId)
        for _ = 1, fillTypeCount do
            local fillTypeIndex = streamReadInt32(streamId)
            local capacity = streamReadInt32(streamId)
            entry.fillTypes[fillTypeIndex] = capacity
        end

        -- Read husbandry food capacity
        if streamReadBool(streamId) then
            entry.husbandryFood = streamReadInt32(streamId)
        end

        -- Read shared capacity
        if streamReadBool(streamId) then
            entry.sharedCapacity = streamReadInt32(streamId)
        end

        if uniqueId ~= nil then
            RmAdjustStorageCapacity.customCapacities[uniqueId] = entry

            -- Apply the custom capacities
            RmAdjustStorageCapacity:applyCapacitiesToPlaceable(self, entry)

            -- Count total capacities applied
            local totalCount = fillTypeCount
            if entry.husbandryFood ~= nil then totalCount = totalCount + 1 end
            if entry.sharedCapacity ~= nil then totalCount = totalCount + 1 end

            Log:debug("ReadStream: Applied %d custom capacities for %s", totalCount, self:getName())
        end
    end
end
