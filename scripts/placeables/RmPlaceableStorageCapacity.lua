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

--- Register savegame XML paths for this specialization
--- Called during type registration to register all paths we write to savegame
---@param schema table The savegame XML schema
---@param basePath string Base path for this specialization (e.g., "placeables.placeable(?).MOD.specName")
function RmPlaceableStorageCapacity.registerSavegameXMLPaths(schema, basePath)
    -- Register the paths we write in saveToXMLFile
    -- Our data is stored under basePath.rmAdjustStorageCapacity
    local modKey = basePath .. ".rmAdjustStorageCapacity"

    -- Fill type capacities
    schema:register(XMLValueType.STRING, modKey .. ".fillTypes.fillType(?)#name", "Fill type name")
    schema:register(XMLValueType.INT, modKey .. ".fillTypes.fillType(?)#capacity", "Custom capacity for fill type")

    -- Husbandry food capacity
    schema:register(XMLValueType.INT, modKey .. ".husbandryFood#capacity", "Custom capacity for husbandry food")

    -- Shared capacity (for multi-fill-type storages)
    schema:register(XMLValueType.INT, modKey .. ".sharedCapacity#value", "Custom shared capacity")
end

--- Register event listeners for this specialization
function RmPlaceableStorageCapacity.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onPostLoad", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", RmPlaceableStorageCapacity)
    -- Savegame hooks - critical for applying capacity BEFORE fill levels load
    SpecializationUtil.registerEventListener(placeableType, "loadFromXMLFile", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "saveToXMLFile", RmPlaceableStorageCapacity)
    -- PlaceableInfoTrigger events - fired when player enters/leaves the info trigger area
    SpecializationUtil.registerEventListener(placeableType, "onInfoTriggerEnter", RmPlaceableStorageCapacity)
    SpecializationUtil.registerEventListener(placeableType, "onInfoTriggerLeave", RmPlaceableStorageCapacity)
end

--- Called when placeable is loaded
--- CRITICAL TIMING: Our onLoad runs AFTER PlaceableSilo:onLoad (specs fire in registration order).
--- PlaceableSilo:onLoad creates the Storage objects. So storages EXIST when our onLoad runs!
--- Custom capacities MUST be applied here in onLoad, BEFORE PlaceableSilo:loadFromXMLFile loads fill levels.
function RmPlaceableStorageCapacity:onLoad(savegame)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME] = {}
        spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    end

    spec.storageTypes = {} -- Which storage types this placeable has
    spec.loadedFromSavegame = false
    spec.activatable = nil -- Will hold RmPlaceableCapacityActivatable when player is in trigger

    local placeableName = self:getName() or "Unknown"
    local ownerFarmId = self:getOwnerFarmId()
    Log:debug("onLoad: %s (uniqueId=%s, ownerFarmId=%s)",
        placeableName, tostring(self.uniqueId), tostring(ownerFarmId))

    -- CRITICAL: Capture original capacities BEFORE applying custom capacities
    -- This ensures we have the true original values for speed scaling calculations
    RmAdjustStorageCapacity:captureOriginalCapacities(self)

    -- Load and apply custom capacity from savegame (server only)
    -- This MUST happen in onLoad, BEFORE PlaceableSilo:loadFromXMLFile loads fill levels
    if g_server ~= nil and savegame ~= nil then
        local uniqueId = self.uniqueId
        if uniqueId == nil then
            Log:debug("onLoad: %s has nil uniqueId, skipping savegame load", placeableName)
            return
        end

        -- Construct path to our embedded data
        -- Format: placeables.placeable(N).MODNAME.storageCapacity.rmAdjustStorageCapacity
        local modKey = savegame.key .. "." .. RmPlaceableStorageCapacity.MOD_NAME .. ".storageCapacity.rmAdjustStorageCapacity"
        local xmlFile = savegame.xmlFile

        Log:debug("LOAD_SAVEGAME_START: %s (uniqueId=%s, key=%s)", placeableName, uniqueId, modKey)

        if not xmlFile:hasProperty(modKey) then
            Log:debug("LOAD_SAVEGAME_NONE: No custom capacity data for %s", placeableName)
            return
        end

        -- Read from embedded XML
        local entry = {
            fillTypes = {},
            husbandryFood = nil,
            sharedCapacity = nil
        }

        -- Read fill type capacities (stored by NAME for cross-session stability)
        xmlFile:iterate(modKey .. ".fillTypes.fillType", function(_, ftKey)
            local name = xmlFile:getValue(ftKey .. "#name")
            local capacity = xmlFile:getValue(ftKey .. "#capacity")
            if name and capacity then
                local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
                if fillTypeIndex then
                    entry.fillTypes[fillTypeIndex] = capacity
                    Log:debug("LOAD_SAVEGAME: Read fillType %s = %d", name, capacity)
                else
                    Log:warning("LOAD_SAVEGAME: Unknown fill type '%s' in savegame", name)
                end
            end
        end)

        -- Read husbandry food capacity
        entry.husbandryFood = xmlFile:getValue(modKey .. ".husbandryFood#capacity")
        if entry.husbandryFood then
            Log:debug("LOAD_SAVEGAME: Read husbandryFood = %d", entry.husbandryFood)
        end

        -- Read shared capacity
        entry.sharedCapacity = xmlFile:getValue(modKey .. ".sharedCapacity#value")
        if entry.sharedCapacity then
            Log:debug("LOAD_SAVEGAME: Read sharedCapacity = %d", entry.sharedCapacity)
        end

        -- Apply if we have data
        if next(entry.fillTypes) or entry.husbandryFood or entry.sharedCapacity then
            RmAdjustStorageCapacity.customCapacities[uniqueId] = entry
            spec.loadedFromSavegame = true

            local applySuccess, applyErr = pcall(function()
                RmAdjustStorageCapacity:applyCapacitiesToPlaceable(self, entry)
            end)

            if applySuccess then
                Log:info("LOAD_SAVEGAME: Applied capacity for %s (BEFORE fill levels load)", placeableName)
            else
                Log:error("LOAD_SAVEGAME: Failed to apply capacity to %s: %s", placeableName, tostring(applyErr))
            end
        end
    end
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

    -- Note: Original capacities are now captured in onLoad() BEFORE custom capacities are applied
    -- This ensures the true original values are captured for speed scaling calculations

    local ownerFarmId = self:getOwnerFarmId()
    Log:debug("onPostLoad complete: %s (uniqueId=%s, ownerFarmId=%s, storage types: %s)",
        self:getName(), tostring(self.uniqueId), tostring(ownerFarmId),
        table.concat(spec.storageTypes, ", "))
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
--- Creates activatable and adds to activatableObjectsSystem
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

    -- Check permission before creating activatable
    local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(self)
    if not canModify then
        return  -- Don't create activatable for unauthorized players
    end

    -- Avoid duplicate activatables
    if spec.activatable ~= nil then
        Log:debug("onInfoTriggerEnter: Activatable already exists for %s, skipping", self:getName())
        return
    end

    -- Create activatable and add to system
    spec.activatable = RmPlaceableCapacityActivatable.new(self)

    if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:addActivatable(spec.activatable)
        Log:debug("onInfoTriggerEnter: Added activatable for %s", self:getName())
    end
end

--- Called when player leaves the info trigger area
--- Removes activatable from activatableObjectsSystem
---@param otherId number The player/entity node that left
function RmPlaceableStorageCapacity:onInfoTriggerLeave(otherId)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return
    end

    -- Remove activatable if present
    if spec.activatable ~= nil then
        if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
            Log:debug("onInfoTriggerLeave: Removed activatable for %s", self:getName())
        end
        spec.activatable = nil
    end
end

--- Called when placeable is deleted/sold - clean up data
function RmPlaceableStorageCapacity:onDelete()
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]

    -- Clean up activatable if present
    if spec ~= nil and spec.activatable ~= nil then
        if g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
        end
        spec.activatable = nil
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
    local placeableName = self:getName() or "Unknown"
    local ownerFarmId = self:getOwnerFarmId()
    local customCapacity = RmAdjustStorageCapacity.customCapacities[uniqueId]

    Log:debug("WriteStream: Starting for %s (uniqueId=%s, ownerFarmId=%s)",
        placeableName, tostring(uniqueId), tostring(ownerFarmId))

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
    local placeableName = self:getName() or "Unknown"

    Log:debug("ReadStream: Starting for %s (uniqueId=%s)", placeableName, tostring(uniqueId))

    -- Log farm context for debugging multiplayer issues
    local ownerFarmId = self:getOwnerFarmId()
    local playerFarmId = nil
    local isSpectator = false
    if g_currentMission ~= nil and g_currentMission.player ~= nil then
        playerFarmId = g_currentMission.player.farmId
        isSpectator = g_currentMission.player:getIsInSpectatorMode()
    end
    Log:debug("ReadStream: %s farm context - ownerFarmId=%s, playerFarmId=%s, spectator=%s",
        placeableName, tostring(ownerFarmId), tostring(playerFarmId), tostring(isSpectator))

    -- Read custom capacity data if present
    local hasCustomCapacity = streamReadBool(streamId)
    Log:debug("ReadStream: %s hasCustomCapacity=%s", placeableName, tostring(hasCustomCapacity))

    if hasCustomCapacity then
        local entry = {
            fillTypes = {},
            husbandryFood = nil,
            sharedCapacity = nil
        }

        -- Read fill type capacities
        local fillTypeCount = streamReadInt32(streamId)
        Log:debug("ReadStream: %s fillTypeCount=%d", placeableName, fillTypeCount)
        for i = 1, fillTypeCount do
            local fillTypeIndex = streamReadInt32(streamId)
            local capacity = streamReadInt32(streamId)
            entry.fillTypes[fillTypeIndex] = capacity
        end

        -- Read husbandry food capacity
        local hasHusbandryFood = streamReadBool(streamId)
        if hasHusbandryFood then
            entry.husbandryFood = streamReadInt32(streamId)
        end

        -- Read shared capacity
        local hasSharedCapacity = streamReadBool(streamId)
        if hasSharedCapacity then
            entry.sharedCapacity = streamReadInt32(streamId)
        end

        -- Count total capacities read
        local totalCount = fillTypeCount
        if entry.husbandryFood ~= nil then totalCount = totalCount + 1 end
        if entry.sharedCapacity ~= nil then totalCount = totalCount + 1 end

        if uniqueId ~= nil then
            RmAdjustStorageCapacity.customCapacities[uniqueId] = entry

            -- Apply the custom capacities (wrapped in pcall for safety)
            local applySuccess, applyErr = pcall(function()
                RmAdjustStorageCapacity:applyCapacitiesToPlaceable(self, entry)
            end)

            if applySuccess then
                Log:debug("ReadStream: Applied %d custom capacities for %s", totalCount, placeableName)
            else
                Log:error("ReadStream: Failed to apply capacities to %s: %s", placeableName, tostring(applyErr))
            end
        else
            -- Log warning when uniqueId is nil (data read correctly but can't store)
            Log:warning("ReadStream: %s has nil uniqueId, read %d capacities but cannot store",
                placeableName, totalCount)
        end
    end
end

-- ============================================================================
-- Savegame XML Hooks (RIT-146 fix)
-- NOTE: Capacity is now applied in onLoad() to ensure it happens BEFORE fill levels load.
-- This loadFromXMLFile is kept as a no-op for compatibility.
-- ============================================================================

--- Load custom capacity from placeable's embedded savegame section
--- NOTE: This fires AFTER PlaceableSilo:loadFromXMLFile, so it's TOO LATE for fill level preservation.
--- Capacity loading is now done in onLoad() instead. This is kept for compatibility.
---@param _xmlFile table XMLFile object (unused - capacity loaded in onLoad)
---@param _key string Base key for this placeable (unused - capacity loaded in onLoad)
function RmPlaceableStorageCapacity:loadFromXMLFile(_xmlFile, _key)
    -- Capacity is now loaded in onLoad() to ensure correct timing
    -- This hook fires too late (after fill levels are loaded and capped)
    -- We keep this registered for compatibility with the savegame system
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec and spec.loadedFromSavegame then
        Log:debug("LOAD_XML: Skipping %s - already loaded in onLoad", self:getName() or "Unknown")
    end
end

--- Save custom capacity to placeable's embedded savegame section
---@param xmlFile table XMLFile object (new API with methods)
---@param key string The base key for this placeable in the savegame XML
---@param usedModNames table Array to add mod name if we write data
function RmPlaceableStorageCapacity:saveToXMLFile(xmlFile, key, usedModNames)
    local uniqueId = self.uniqueId
    if uniqueId == nil then
        return
    end

    local entry = RmAdjustStorageCapacity.customCapacities[uniqueId]
    if entry == nil then
        return  -- No custom capacity for this placeable
    end

    local placeableName = self:getName() or "Unknown"
    local modKey = key .. ".rmAdjustStorageCapacity"

    -- Write fill type capacities (by NAME for cross-session stability)
    local ftIndex = 0
    for fillTypeIndex, capacity in pairs(entry.fillTypes or {}) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType then
            local ftKey = string.format("%s.fillTypes.fillType(%d)", modKey, ftIndex)
            xmlFile:setValue(ftKey .. "#name", fillType.name)
            xmlFile:setValue(ftKey .. "#capacity", capacity)
            ftIndex = ftIndex + 1
        end
    end

    -- Write husbandry food capacity
    if entry.husbandryFood then
        xmlFile:setValue(modKey .. ".husbandryFood#capacity", entry.husbandryFood)
    end

    -- Write shared capacity
    if entry.sharedCapacity then
        xmlFile:setValue(modKey .. ".sharedCapacity#value", entry.sharedCapacity)
    end

    -- Mark mod as used in this savegame
    table.insert(usedModNames, RmAdjustStorageCapacity.modName)

    Log:debug("SAVE_XML: Wrote capacity to embedded data for %s (%d fillTypes, husbandryFood=%s, sharedCapacity=%s)",
        placeableName, ftIndex, tostring(entry.husbandryFood ~= nil), tostring(entry.sharedCapacity ~= nil))
end
