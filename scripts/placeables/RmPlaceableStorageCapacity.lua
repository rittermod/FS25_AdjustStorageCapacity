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
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", RmPlaceableStorageCapacity)
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

    -- CRITICAL (MP): force the husbandryFood serialization bit width to a constant, symmetric
    -- value on EVERY peer, BEFORE any husbandryFood stream. Unconditional and before the
    -- server-savegame guard below so server and client always agree (a pure client does not yet
    -- know a trough's custom capacity at onLoad). No-op for non-husbandryFood placeables.
    RmAdjustStorageCapacity:normalizeHusbandryFoodBitWidth(self)

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

        -- Dropping a corrupt entry reverts that capacity to the engine default, which can sit BELOW
        -- the fill level the savegame is about to restore (it was saved under the dropped override).
        -- That is what the load-time excess-fill heal in loadFromXMLFile exists for, and its gate is
        -- spec.loadedFromSavegame - so track drops and open the gate even when nothing survived.
        local droppedCorrupt = false

        -- Read fill type capacities (stored by NAME for cross-session stability)
        xmlFile:iterate(modKey .. ".fillTypes.fillType", function(_, ftKey)
            local name = xmlFile:getValue(ftKey .. "#name")
            local capacity = xmlFile:getValue(ftKey .. "#capacity")
            if name and capacity then
                -- Check if the parsed capacity is valid. If not, keep the engine default
                if not RmAdjustStorageCapacity.isStoredCapacityValid(capacity) then
                    Log:warning("LOAD_SAVEGAME: %s dropped corrupt fillType '%s' capacity (parsed %s)"
                        .. " - keeping engine default", placeableName, name, tostring(capacity))
                    droppedCorrupt = true
                else
                    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
                    if fillTypeIndex then
                        entry.fillTypes[fillTypeIndex] = capacity
                        Log:debug("LOAD_SAVEGAME: Read fillType %s = %d", name, capacity)
                    else
                        Log:warning("LOAD_SAVEGAME: Unknown fill type '%s' in savegame", name)
                    end
                end
            end
        end)

        -- Read husbandry food capacity
        entry.husbandryFood = xmlFile:getValue(modKey .. ".husbandryFood#capacity")
        if entry.husbandryFood then
            if not RmAdjustStorageCapacity.isStoredCapacityValid(entry.husbandryFood) then
                Log:warning("LOAD_SAVEGAME: %s dropped corrupt husbandryFood capacity (parsed %s)"
                    .. " - keeping engine default", placeableName, tostring(entry.husbandryFood))
                entry.husbandryFood = nil
                droppedCorrupt = true
            else
                Log:debug("LOAD_SAVEGAME: Read husbandryFood = %d", entry.husbandryFood)
            end
        end

        -- Read shared capacity
        entry.sharedCapacity = xmlFile:getValue(modKey .. ".sharedCapacity#value")
        if entry.sharedCapacity then
            if not RmAdjustStorageCapacity.isStoredCapacityValid(entry.sharedCapacity) then
                Log:warning("LOAD_SAVEGAME: %s dropped corrupt sharedCapacity (parsed %s) - keeping engine default",
                    placeableName, tostring(entry.sharedCapacity))
                entry.sharedCapacity = nil
                droppedCorrupt = true
            else
                Log:debug("LOAD_SAVEGAME: Read sharedCapacity = %d", entry.sharedCapacity)
            end
        end

        -- Apply if we have data
        if next(entry.fillTypes) or entry.husbandryFood or entry.sharedCapacity then
            RmAdjustStorageCapacity.customCapacities[uniqueId] = entry
            spec.loadedFromSavegame = true

            local applySuccess, applyErr = pcall(function()
                -- skipVisualUpdate=true: fill levels are 0 at this point, visual update
                -- is deferred to loadFromXMLFile when fill levels are loaded
                RmAdjustStorageCapacity:applyCapacitiesToPlaceable(self, entry, true)
            end)

            if applySuccess then
                Log:info("LOAD_SAVEGAME: Applied capacity for %s (BEFORE fill levels load, visual update deferred)", placeableName)
            else
                Log:error("LOAD_SAVEGAME: Failed to apply capacity to %s: %s", placeableName, tostring(applyErr))
            end
        elseif droppedCorrupt then
            -- Every entry was corrupt: nothing to store or apply, so the placeable keeps its engine
            -- default. Still open the heal gate - on a shared-capacity storage the restored fill can
            -- exceed that default, and no override was applied to bound it at onLoad.
            spec.loadedFromSavegame = true
            Log:info("LOAD_SAVEGAME: %s kept engine default for every entry (all corrupt)"
                .. " - excess-fill heal still armed", placeableName)
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

--- Called when placeable finalization completes (after uniqueId is assigned)
--- For newly placed buildings, uniqueId is nil during onLoad but available here.
--- Retries original capacity capture if it was missed in onLoad.
function RmPlaceableStorageCapacity:onFinalizePlacement()
    local uniqueId = self.uniqueId
    if uniqueId == nil then
        return
    end

    -- Capture original capacities if not already captured (e.g., new placements where
    -- uniqueId was nil during onLoad)
    if RmAdjustStorageCapacity.originalCapacities[uniqueId] == nil then
        RmAdjustStorageCapacity:captureOriginalCapacities(self)
    end
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

        -- Carry the server's TRUE fill for each Storage so a joining client can re-establish it
        -- AFTER ASC raises the capacity. Base Storage deserializes + clamps fill to the ORIGINAL
        -- capacity before ASC's spec runs, so the above-original portion is lost without this.
        -- Count-framed and decoded POSITIONALLY: getStorageInfo().storages is built in identical
        -- order on both peers (FS25 requires identical mods/map), so the i-th written storage is
        -- the i-th storage on the client. husbandryFood is a SEPARATE getStorageInfo field
        -- (deferred Part B) and is therefore structurally excluded here.
        local storages = RmAdjustStorageCapacity:getStorageInfo(self).storages
        streamWriteInt32(streamId, #storages)
        for _, info in ipairs(storages) do
            local fillList = {}
            local fillLevels = info.storage.fillLevels
            if fillLevels ~= nil then
                for fillTypeIndex, fillLevel in pairs(fillLevels) do
                    if fillLevel > 0 then
                        fillList[#fillList + 1] = { fillTypeIndex, fillLevel }
                    end
                end
            end
            streamWriteInt32(streamId, #fillList)
            for _, p in ipairs(fillList) do
                streamWriteInt32(streamId, p[1])
                streamWriteFloat32(streamId, p[2])
            end
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

        -- The three capacity reads below deliberately HEAL an out-of-range value with a [0, MAX]
        -- clamp instead of dropping the entry the way the savegame read path does. The asymmetry is
        -- intentional: the server never stores a corrupt capacity, so the only way a wrapped-negative
        -- reaches the wire is an older server - and a client that dropped the entry would fall back
        -- to its local engine default, silently disagreeing with the capacity the server enforces.
        -- Do not "unify" these three sites with the onLoad drop logic.

        -- Read fill type capacities
        local fillTypeCount = streamReadInt32(streamId)
        Log:debug("ReadStream: %s fillTypeCount=%d", placeableName, fillTypeCount)
        for i = 1, fillTypeCount do
            local fillTypeIndex = streamReadInt32(streamId)
            local capacity = streamReadInt32(streamId)
            -- Defensive [0, MAX] clamp: a pre-fix server could send a wrapped-negative capacity.
            entry.fillTypes[fillTypeIndex] = math.max(0, (RmAdjustStorageCapacity.clampToMax(capacity)))
        end

        -- Read husbandry food capacity
        local hasHusbandryFood = streamReadBool(streamId)
        if hasHusbandryFood then
            entry.husbandryFood = math.max(0, (RmAdjustStorageCapacity.clampToMax(streamReadInt32(streamId))))
        end

        -- Read shared capacity
        local hasSharedCapacity = streamReadBool(streamId)
        if hasSharedCapacity then
            entry.sharedCapacity = math.max(0, (RmAdjustStorageCapacity.clampToMax(streamReadInt32(streamId))))
        end

        -- Read the carried Storage fill segment UNCONDITIONALLY (outside the uniqueId/pcall apply
        -- block) so the cursor stays aligned even when uniqueId is nil or the apply throws. The
        -- whole segment is consumed by count regardless of the client's local storage set;
        -- carried[i] = { [fillTypeIndex] = fillLevel }. Only the RE-APPLY below is gated.
        local carried = {}
        local storageCount = streamReadInt32(streamId)
        for i = 1, storageCount do
            local fills = {}
            local pairCount = streamReadInt32(streamId)
            for _ = 1, pairCount do
                local fillTypeIndex = streamReadInt32(streamId)
                fills[fillTypeIndex] = streamReadFloat32(streamId)
            end
            carried[i] = fills
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
                -- Re-establish each carried Storage fill AFTER the capacity raise. setFillLevel
                -- clamps to the now-raised capacity, no-ops on an absent slot, and does NOT
                -- re-broadcast on a client (its dirty-flag raise is isServer-gated). Apply the
                -- i-th carried storage to the i-th local storage (positional parity); skip and
                -- debug-log a fill-type slot the client storage lacks.
                for i, info in ipairs(RmAdjustStorageCapacity:getStorageInfo(self).storages) do
                    local fills = carried[i]
                    if fills ~= nil then
                        local storage = info.storage
                        for fillTypeIndex, fillLevel in pairs(fills) do
                            if fillLevel > 0 then
                                if storage.fillLevels ~= nil and storage.fillLevels[fillTypeIndex] ~= nil then
                                    storage:setFillLevel(fillLevel, fillTypeIndex)
                                else
                                    Log:debug(
                                        "ReadStream: Carried fill for absent slot skipped on %s (storage %d, fillType %d)",
                                        placeableName, i, fillTypeIndex)
                                end
                            end
                        end
                    end
                end
                -- Belt-and-suspenders plane refresh for a freshly stream-created placeable.
                RmAdjustStorageCapacity:updatePlaceableFillPlanes(self)

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
-- Savegame XML Hooks (savegame load-order fix)
-- NOTE: Capacity is now applied in onLoad() to ensure it happens BEFORE fill levels load.
-- This loadFromXMLFile is kept as a no-op for compatibility.
-- ============================================================================

--- Load custom capacity from placeable's embedded savegame section
--- NOTE: Capacity values are applied in onLoad() (BEFORE fill levels load to prevent clamping).
--- This hook fires AFTER fill levels are loaded, so we use it for the deferred visual fill plane
--- update - 3D fill planes need correct fill levels to render properly.
---@param _xmlFile table XMLFile object (unused - capacity loaded in onLoad)
---@param _key string Base key for this placeable (unused - capacity loaded in onLoad)
function RmPlaceableStorageCapacity:loadFromXMLFile(_xmlFile, _key)
    local spec = self[RmPlaceableStorageCapacity.SPEC_TABLE_NAME]
    if spec and spec.loadedFromSavegame then
        -- Load-time excess-fill heal: clamp any runtime FILL that loaded ABOVE the (already
        -- onLoad-bounded) storage capacity DOWN to capacity. Loaded fill is already within cap for
        -- healthy entities, so this is a guaranteed no-op except on a hand-edited SHARED-capacity
        -- silo: each fill type loads within its own cap, but their sum can still exceed the single
        -- shared capacity. Each storage is healed under its OWN pcall - and the plane refresh in a
        -- SEPARATE pcall below - so one storage's throw cannot skip its siblings OR the refresh.
        local storageInfo = RmAdjustStorageCapacity:getStorageInfo(self)
        for _, info in ipairs(storageInfo.storages) do
            local healOk, healErr = pcall(function()
                RmAdjustStorageCapacity:clampExcessFill(info.storage)
            end)
            if not healOk then
                Log:error("LOAD_XML: Failed to heal excess fill for %s: %s",
                    self:getName() or "Unknown", tostring(healErr))
            end
        end

        -- Now that fill levels are loaded (and healed), update visual fill planes
        Log:debug("LOAD_XML: Deferred visual fill plane update for %s", self:getName() or "Unknown")
        local success, err = pcall(function()
            RmAdjustStorageCapacity:updatePlaceableFillPlanes(self)
        end)
        if not success then
            Log:error("LOAD_XML: Failed to update fill planes for %s: %s", self:getName() or "Unknown", tostring(err))
        end
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
