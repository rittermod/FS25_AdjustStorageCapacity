-- RmAdjustStorageCapacity - Main module for AdjustStorageCapacity
-- Author: Ritter
--
-- Description: Adjusts storage capacities for silos, productions, husbandries, and other storage facilities.
-- Supports: PlaceableSilo, PlaceableProductionPoint, PlaceableHusbandry, PlaceableHusbandryFood
-- NOT Supported: BunkerSilo (terrain heap-based, no capacity property)
--
-- Unlike LimitHusbandryAnimals, this mod allows setting ANY capacity value (no upper limit).

RmAdjustStorageCapacity = {}
RmAdjustStorageCapacity.modDirectory = g_currentModDirectory
RmAdjustStorageCapacity.modName = g_currentModName

-- Storage type constants
RmAdjustStorageCapacity.STORAGE_TYPE = {
    SILO = "silo",
    PRODUCTION = "production",
    HUSBANDRY = "husbandry",
    HUSBANDRY_FOOD = "husbandryFood"
}

-- Storage for custom placeable capacities
-- Key = uniqueId, Value = {fillTypes = {[fillTypeIndex] = capacity}, husbandryFood = capacity}
RmAdjustStorageCapacity.customCapacities = {}

-- Storage for original placeable capacities (for reset functionality)
-- Key = uniqueId, Value = {fillTypes = {[fillTypeIndex] = capacity}, husbandryFood = capacity, loadSpeedLitersPerSec = speed}
RmAdjustStorageCapacity.originalCapacities = {}

-- Auto-scale speed when capacity changes (enabled by default)
RmAdjustStorageCapacity.autoScaleSpeed = true

-- Storage for custom vehicle capacities
-- Key = uniqueId, Value = {[fillUnitIndex] = capacity}
RmAdjustStorageCapacity.vehicleCapacities = {}

-- Note: Placeable keybinds now use the activatableObjectsSystem via RmPlaceableCapacityActivatable.
-- Vehicle keybinds also use the activatableObjectsSystem via RmVehicleCapacityActivatable.

-- Console error messages (hardcoded English - console is developer-facing)
local CONSOLE_ERRORS = {
    rm_asc_error_notOwner = "You don't own this storage",
    rm_asc_error_notManager = "You must be farm manager to change capacities",
    rm_asc_error_notModifiable = "This storage cannot be modified",
    rm_asc_error_notFound = "Storage not found",
    rm_asc_error_invalidCapacity = "Invalid capacity value",
    rm_asc_error_unknown = "An unknown error occurred"
}

-- Get logger for this module (prefix auto-generated with context suffix)
local Log = RmLogging.getLogger("AdjustStorageCapacity")
-- Log:setLevel(RmLogging.LOG_LEVEL.TRACE) -- TODO: Change to INFO for release

-- ============================================================================
-- Storage Enumeration and Type Detection
-- ============================================================================

--- Get all storage information for a placeable
--- Returns structured info about all storage types present
---@param placeable table The placeable to inspect
---@return table storageInfo {storages = array of {storage, type, index}, husbandryFood = spec or nil, hasStorage = bool}
function RmAdjustStorageCapacity:getStorageInfo(placeable)
    local result = {
        storages = {},       -- Array of {storage=Storage object, type=string, index=number}
        husbandryFood = nil, -- PlaceableHusbandryFood spec if present
        hasStorage = false
    }

    if placeable == nil then
        return result
    end

    -- Check PlaceableSilo (can have multiple storages)
    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
        for i, storage in ipairs(placeable.spec_silo.storages) do
            table.insert(result.storages, {
                storage = storage,
                type = self.STORAGE_TYPE.SILO,
                index = i
            })
        end
    end

    -- Check PlaceableProductionPoint
    if placeable.spec_productionPoint ~= nil and placeable.spec_productionPoint.productionPoint ~= nil then
        local pp = placeable.spec_productionPoint.productionPoint
        if pp.storage ~= nil then
            table.insert(result.storages, {
                storage = pp.storage,
                type = self.STORAGE_TYPE.PRODUCTION,
                index = 1
            })
        end
    end

    -- Check PlaceableHusbandry (output storage for manure, milk, etc.)
    if placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage ~= nil then
        table.insert(result.storages, {
            storage = placeable.spec_husbandry.storage,
            type = self.STORAGE_TYPE.HUSBANDRY,
            index = 1
        })
    end

    -- Check PlaceableHusbandryFood (different mechanism - direct capacity property)
    if placeable.spec_husbandryFood ~= nil then
        result.husbandryFood = placeable.spec_husbandryFood
    end

    result.hasStorage = #result.storages > 0 or result.husbandryFood ~= nil
    return result
end

--- Get the loading station for a placeable (if present)
--- Loading stations control the speed at which items are loaded FROM storage
---@param placeable table The placeable to inspect
---@return table|nil loadingStation The LoadingStation object or nil
function RmAdjustStorageCapacity:getLoadingStation(placeable)
    if placeable == nil then
        return nil
    end

    -- PlaceableSilo
    if placeable.spec_silo ~= nil and placeable.spec_silo.loadingStation ~= nil then
        return placeable.spec_silo.loadingStation
    end

    -- PlaceableHusbandry
    if placeable.spec_husbandry ~= nil and placeable.spec_husbandry.loadingStation ~= nil then
        return placeable.spec_husbandry.loadingStation
    end

    -- PlaceableProductionPoint
    if placeable.spec_productionPoint ~= nil and placeable.spec_productionPoint.productionPoint ~= nil then
        local pp = placeable.spec_productionPoint.productionPoint
        if pp.loadingStation ~= nil then
            return pp.loadingStation
        end
    end

    -- PlaceableBuyingStation
    if placeable.spec_buyingStation ~= nil and placeable.spec_buyingStation.buyingStation ~= nil then
        return placeable.spec_buyingStation.buyingStation
    end

    return nil
end

--- Get all fill types supported by a placeable's storages
---@param placeable table The placeable to inspect
---@return table fillTypes Array of {fillTypeIndex, fillTypeName, capacity, fillLevel, storageType, isSharedCapacity}
function RmAdjustStorageCapacity:getAllFillTypes(placeable)
    local fillTypes = {}
    local seen = {} -- Avoid duplicates

    local storageInfo = self:getStorageInfo(placeable)

    -- Collect from Storage class instances
    for _, info in ipairs(storageInfo.storages) do
        local storage = info.storage

        -- Check for per-filltype capacities first
        if storage.capacities ~= nil and next(storage.capacities) ~= nil then
            for fillTypeIndex, capacity in pairs(storage.capacities) do
                if not seen[fillTypeIndex] then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    local fillLevel = storage.fillLevels and storage.fillLevels[fillTypeIndex] or 0
                    table.insert(fillTypes, {
                        fillTypeIndex = fillTypeIndex,
                        fillTypeName = fillType and fillType.title or "Unknown",
                        capacity = capacity,
                        fillLevel = fillLevel,
                        storageType = info.type,
                        isSharedCapacity = false
                    })
                    seen[fillTypeIndex] = true
                end
            end
            -- Check for shared capacity model (storage.capacity + storage.supportedFillTypes)
        elseif storage.capacity ~= nil and storage.supportedFillTypes ~= nil then
            for fillTypeIndex, _ in pairs(storage.supportedFillTypes) do
                if not seen[fillTypeIndex] then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    local fillLevel = storage.fillLevels and storage.fillLevels[fillTypeIndex] or 0
                    table.insert(fillTypes, {
                        fillTypeIndex = fillTypeIndex,
                        fillTypeName = fillType and fillType.title or "Unknown",
                        capacity = storage.capacity, -- Shared capacity
                        fillLevel = fillLevel,
                        storageType = info.type,
                        isSharedCapacity = true
                    })
                    seen[fillTypeIndex] = true
                end
            end
            -- Check for fillLevels without explicit capacities (some production point storages)
        elseif storage.fillLevels ~= nil then
            for fillTypeIndex, fillLevel in pairs(storage.fillLevels) do
                if not seen[fillTypeIndex] then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    -- Try to determine capacity from various sources
                    local capacity = 0
                    if storage.capacities and storage.capacities[fillTypeIndex] then
                        capacity = storage.capacities[fillTypeIndex]
                    elseif storage.capacity then
                        capacity = storage.capacity
                    end
                    table.insert(fillTypes, {
                        fillTypeIndex = fillTypeIndex,
                        fillTypeName = fillType and fillType.title or "Unknown",
                        capacity = capacity,
                        fillLevel = fillLevel,
                        storageType = info.type,
                        isSharedCapacity = storage.capacity ~= nil
                    })
                    seen[fillTypeIndex] = true
                end
            end
        end
    end

    -- Add HusbandryFood if present (shows as combined capacity)
    if storageInfo.husbandryFood ~= nil then
        local spec = storageInfo.husbandryFood
        -- Calculate total fill across all food types
        local totalFill = 0
        if spec.fillLevels ~= nil then
            for _, level in pairs(spec.fillLevels) do
                totalFill = totalFill + level
            end
        end

        table.insert(fillTypes, {
            fillTypeIndex = -1, -- Special marker for husbandry food
            fillTypeName = g_i18n:getText("rm_asc_husbandryFood") or "Animal Food",
            capacity = spec.capacity or 0,
            fillLevel = totalFill,
            storageType = self.STORAGE_TYPE.HUSBANDRY_FOOD
        })
    end

    return fillTypes
end

--- Check if a placeable has any modifiable storage
---@param placeable table The placeable to check
---@return boolean hasStorage Whether the placeable has storage we can modify
function RmAdjustStorageCapacity:hasModifiableStorage(placeable)
    local storageInfo = self:getStorageInfo(placeable)
    return storageInfo.hasStorage
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

--- Called when map is loaded
function RmAdjustStorageCapacity:loadMap()
    Log:info("Mod loaded successfully (v%s)", g_modManager:getModByName(self.modName).version)

    -- Register console commands for placeables
    addConsoleCommand("ascList", "Lists all storage placeables with capacities", "consoleCommandList", self)
    addConsoleCommand("ascSet", "Sets capacity: ascSet <index> <fillType> <capacity>", "consoleCommandSet", self)
    addConsoleCommand("ascReset", "Resets capacity: ascReset <index> [fillType]", "consoleCommandReset", self)

    -- Register console commands for vehicles
    addConsoleCommand("ascListVehicles", "Lists all vehicles with fill units", "consoleCommandListVehicles", self)
    addConsoleCommand("ascSetVehicle", "Sets vehicle capacity: ascSetVehicle <index> <fillUnit> <capacity>",
        "consoleCommandSetVehicle", self)
    addConsoleCommand("ascResetVehicle", "Resets vehicle capacity: ascResetVehicle <index> [fillUnit]",
        "consoleCommandResetVehicle", self)
end

--- Called when mission starts (via hook) - placeables are populated at this point
function RmAdjustStorageCapacity.onMissionStarted()
    Log:info("Mission started, initializing...")

    -- Register console commands for log level management
    RmLogging.registerConsoleCommands()

    -- Register GUI dialogs
    RmStorageCapacityDialog.register()
    RmVehicleCapacityDialog.register()

    -- Initialize menu integration (adds K button to production/husbandry menus)
    RmMenuIntegration.init()

    -- Initialize vehicle detection handler (player-attached trigger for vehicles)
    RmVehicleDetectionHandler.init()

    -- Capture original capacities for any storages not yet captured
    -- Note: Most placeables have originals captured in onLoad() (before custom capacities apply)
    -- This catches any edge cases or placeables without our specialization
    RmAdjustStorageCapacity:captureAllOriginalCapacities()

    -- Log current state
    RmAdjustStorageCapacity:logAllStorages()
    RmAdjustStorageCapacity:logAllVehicles()
end

-- ============================================================================
-- Permission Checking
-- ============================================================================

--- Check if current player can modify a storage's capacity
---@param placeable table The storage placeable
---@return boolean canModify Whether the player can modify the capacity
---@return string|nil errorKey Localization key for error message if not allowed
function RmAdjustStorageCapacity:canModifyCapacity(placeable)
    if placeable == nil then
        return false, "rm_asc_error_notAvailable"
    end

    local ownerFarmId = placeable:getOwnerFarmId()
    local playerFarmId = g_currentMission:getFarmId()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    -- Block modification of unowned/spectator assets (even admins)
    if ownerFarmId == 0 or ownerFarmId == FarmManager.SPECTATOR_FARM_ID then
        return false, "rm_asc_error_notModifiable"
    end

    -- Check admin/server status first (can modify ANY storage)
    if isMultiplayer then
        -- Server/host can modify any storage
        if g_currentMission:getIsServer() then
            return true, nil
        end

        -- Admin (master user) can modify any storage
        if g_currentMission.isMasterUser then
            return true, nil
        end
    end

    -- Non-admin: must own the storage
    if ownerFarmId ~= playerFarmId then
        return false, "rm_asc_error_notOwner"
    end

    -- Single player: ownership is sufficient
    if not isMultiplayer then
        return true, nil
    end

    -- Multiplayer non-admin: must be farm manager
    local farm = g_farmManager:getFarmById(playerFarmId)
    if farm ~= nil and farm:isUserFarmManager(g_currentMission.playerUserId) then
        return true, nil
    end

    -- Not authorized
    return false, "rm_asc_error_notManager"
end

-- ============================================================================
-- Capacity Application
-- ============================================================================

--- Capture original capacities for all storage placeables
function RmAdjustStorageCapacity:captureAllOriginalCapacities()
    local captured = 0

    if g_currentMission.placeableSystem ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
            if self:captureOriginalCapacities(placeable) then
                captured = captured + 1
            end
        end
    end

    Log:debug("Captured original capacities for %d placeable(s)", captured)
end

--- Capture original capacities for a single placeable
---@param placeable table The placeable
---@return boolean captured Whether any capacities were captured
function RmAdjustStorageCapacity:captureOriginalCapacities(placeable)
    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        return false
    end

    -- Skip if already captured
    if self.originalCapacities[uniqueId] ~= nil then
        return false
    end

    local storageInfo = self:getStorageInfo(placeable)
    if not storageInfo.hasStorage then
        return false
    end

    local originals = {
        fillTypes = {},
        husbandryFood = nil,
        sharedCapacity = nil,
        loadSpeedLitersPerSec = nil -- Original loading speed (l/sec)
    }

    -- Capture from Storage class instances
    for _, info in ipairs(storageInfo.storages) do
        local storage = info.storage

        -- Capture per-filltype capacities
        if storage.capacities ~= nil then
            for fillTypeIndex, capacity in pairs(storage.capacities) do
                -- Only capture first occurrence (in case multiple storages have same fill type)
                if originals.fillTypes[fillTypeIndex] == nil then
                    originals.fillTypes[fillTypeIndex] = capacity
                end
            end
        end

        -- Capture shared capacity (for silos with storage.capacity instead of storage.capacities)
        if storage.capacity ~= nil and originals.sharedCapacity == nil then
            originals.sharedCapacity = storage.capacity
        end
    end

    -- Capture HusbandryFood capacity
    if storageInfo.husbandryFood ~= nil then
        originals.husbandryFood = storageInfo.husbandryFood.capacity
    end

    -- Capture original load speed from LoadingStation (if present)
    local loadingStation = self:getLoadingStation(placeable)
    if loadingStation ~= nil and loadingStation.loadTriggers ~= nil then
        for _, loadTrigger in ipairs(loadingStation.loadTriggers) do
            if loadTrigger.fillLitersPerMS ~= nil then
                -- Convert from l/ms to l/sec for easier human understanding
                originals.loadSpeedLitersPerSec = loadTrigger.fillLitersPerMS * 1000
                Log:trace("Captured original load speed: %.0f l/sec for %s",
                    originals.loadSpeedLitersPerSec, placeable:getName())
                break -- Usually only one trigger per station
            end
        end
    end

    self.originalCapacities[uniqueId] = originals
    return true
end

--- Calculate the maximum capacity multiplier for a placeable
--- When multiple fill types have different multipliers, use the largest one for load speed
---@param placeable table The placeable
---@param customCapacity table The custom capacity settings
---@return number multiplier The maximum multiplier (1.0 if no change)
function RmAdjustStorageCapacity:getMaxCapacityMultiplier(placeable, customCapacity)
    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        Log:debug("getMaxCapacityMultiplier: no uniqueId, returning 1.0")
        return 1.0
    end

    local originals = self.originalCapacities[uniqueId]
    if originals == nil then
        Log:debug("getMaxCapacityMultiplier: no originals for %s, returning 1.0", placeable:getName())
        return 1.0
    end

    local maxMultiplier = 1.0

    -- Check shared capacity multiplier
    if customCapacity.sharedCapacity ~= nil and originals.sharedCapacity ~= nil and originals.sharedCapacity > 0 then
        local mult = customCapacity.sharedCapacity / originals.sharedCapacity
        Log:debug("getMaxCapacityMultiplier: shared capacity %d / %d = %.2f",
            customCapacity.sharedCapacity, originals.sharedCapacity, mult)
        if mult > maxMultiplier then
            maxMultiplier = mult
        end
    elseif customCapacity.sharedCapacity ~= nil then
        Log:debug("getMaxCapacityMultiplier: customCapacity.sharedCapacity=%d but originals.sharedCapacity=%s",
            customCapacity.sharedCapacity, tostring(originals.sharedCapacity))
    end

    -- Check per-filltype capacity multipliers
    if customCapacity.fillTypes ~= nil and originals.fillTypes ~= nil then
        for fillTypeIndex, newCapacity in pairs(customCapacity.fillTypes) do
            local originalCapacity = originals.fillTypes[fillTypeIndex]
            if originalCapacity ~= nil and originalCapacity > 0 then
                local mult = newCapacity / originalCapacity
                if mult > maxMultiplier then
                    maxMultiplier = mult
                end
            end
        end
    end

    -- Check husbandry food capacity multiplier
    if customCapacity.husbandryFood ~= nil and originals.husbandryFood ~= nil and originals.husbandryFood > 0 then
        local mult = customCapacity.husbandryFood / originals.husbandryFood
        if mult > maxMultiplier then
            maxMultiplier = mult
        end
    end

    return maxMultiplier
end

--- Apply proportional load speed to a placeable based on capacity multiplier
---@param placeable table The placeable
---@param multiplier number The capacity multiplier (e.g., 10 for 10x capacity)
function RmAdjustStorageCapacity:applyProportionalLoadSpeed(placeable, multiplier)
    Log:debug("applyProportionalLoadSpeed: %s, multiplier=%.2f, autoScaleSpeed=%s",
        placeable:getName(), multiplier, tostring(self.autoScaleSpeed))

    if not self.autoScaleSpeed then
        Log:debug("applyProportionalLoadSpeed: autoScaleSpeed is disabled")
        return
    end

    if multiplier <= 0 or multiplier == 1.0 then
        Log:debug("applyProportionalLoadSpeed: multiplier is %.2f, no change needed", multiplier)
        return -- No change needed
    end

    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        Log:debug("applyProportionalLoadSpeed: no uniqueId")
        return
    end

    local originals = self.originalCapacities[uniqueId]
    if originals == nil or originals.loadSpeedLitersPerSec == nil then
        Log:debug("applyProportionalLoadSpeed: no original speed (originals=%s, loadSpeed=%s)",
            originals and "exists" or "nil",
            originals and tostring(originals.loadSpeedLitersPerSec) or "N/A")
        return -- No original speed recorded
    end

    local loadingStation = self:getLoadingStation(placeable)
    if loadingStation == nil or loadingStation.loadTriggers == nil then
        Log:debug("applyProportionalLoadSpeed: no loadingStation or loadTriggers (station=%s)",
            loadingStation and "exists" or "nil")
        return
    end

    local originalSpeed = originals.loadSpeedLitersPerSec
    local newSpeed = originalSpeed * multiplier

    -- Apply to all load triggers
    for _, loadTrigger in ipairs(loadingStation.loadTriggers) do
        if loadTrigger.fillLitersPerMS ~= nil then
            local oldSpeedMS = loadTrigger.fillLitersPerMS
            loadTrigger.fillLitersPerMS = newSpeed / 1000 -- Convert l/sec to l/ms
            Log:debug("Applied load speed %.0f -> %.0f l/sec (%.1fx) to %s",
                oldSpeedMS * 1000, newSpeed, multiplier, placeable:getName())
        end
    end
end

--- Update visual fill planes after capacity change
--- Call this after modifying storage capacities to update the visual representation
---@param placeable table The placeable
function RmAdjustStorageCapacity:updatePlaceableFillPlanes(placeable)
    if placeable == nil then return end

    local storageInfo = self:getStorageInfo(placeable)

    -- Update storage fill planes (silos, productions, husbandries)
    for _, info in ipairs(storageInfo.storages) do
        local storage = info.storage
        if storage ~= nil then
            -- Update 2D fill planes (simple percentage bars)
            if storage.updateFillPlanes ~= nil then
                storage:updateFillPlanes()
                Log:trace("Updated 2D fill planes for storage type %s", info.type)
            end

            -- Update 3D dynamic fill plane (heap) if present
            if storage.dynamicFillPlane ~= nil and storage.dynamicFillPlaneBaseNode ~= nil then
                self:recreateStorageDynamicFillPlane(storage)
            end
        end
    end

    -- Update husbandry food fill planes
    if storageInfo.husbandryFood ~= nil and placeable.updateFillPlanes ~= nil then
        placeable:updateFillPlanes()
        Log:trace("Updated husbandry food fill planes")

        -- Update 3D dynamic food plane if present
        local spec = storageInfo.husbandryFood
        if spec.dynamicFoodPlane ~= nil and spec.baseNode ~= nil then
            self:recreateHusbandryFoodDynamicPlane(placeable, spec)
        end
    end
end

--- Recreate a Storage's dynamicFillPlane with updated capacity
---@param storage table The storage object
function RmAdjustStorageCapacity:recreateStorageDynamicFillPlane(storage)
    if storage.dynamicFillPlane == nil or storage.dynamicFillPlaneBaseNode == nil then
        return
    end

    -- Get current fill state
    local totalFillLevel = 0
    local primaryFillType = FillType.UNKNOWN
    for fillType, fillLevel in pairs(storage.fillLevels or {}) do
        if fillLevel > 0 then
            totalFillLevel = totalFillLevel + fillLevel
            if primaryFillType == FillType.UNKNOWN then
                primaryFillType = fillType
            end
        end
    end

    -- Get new capacity (use first available capacity or shared capacity)
    local newCapacity = storage.capacity
    if storage.capacities ~= nil and next(storage.capacities) ~= nil then
        for _, cap in pairs(storage.capacities) do
            newCapacity = cap
            break
        end
    end

    -- Store old fill plane reference
    local oldFillPlane = storage.dynamicFillPlane
    local baseNode = storage.dynamicFillPlaneBaseNode

    -- Delete old fill plane
    if oldFillPlane ~= nil then
        delete(oldFillPlane)
    end

    -- Create new fill plane with updated capacity
    -- Note: We use createFillPlaneShape directly since Storage doesn't store XML parameters
    local newFillPlane = createFillPlaneShape(
        baseNode,
        "fillPlane",
        newCapacity,
        1.0,          -- maxDelta: max heap height above surface
        math.rad(35), -- maxSurfaceAngle: heap slope angle
        math.rad(35), -- maxPhysicalSurfaceAngle: physical slope angle
        0.05,         -- maxSurfaceDistanceError: precision 
        0.9,          -- maxSubDivEdgeLength: mesh subdivision
        1.35,         -- syncMaxSubDivEdgeLength: multiplayer sync subdivision
        false,        -- allSidePlanes
        false         -- retessellateTop
    )

    if newFillPlane ~= nil and newFillPlane ~= 0 then
        -- Apply material using game utility (same as Storage.lua does)
        if FillPlaneUtil ~= nil and FillPlaneUtil.assignDefaultMaterialsFromTerrain ~= nil then
            FillPlaneUtil.assignDefaultMaterialsFromTerrain(newFillPlane, g_terrainNode)
        end

        -- Set fill type using game utility (same as Storage.lua does)
        if primaryFillType ~= FillType.UNKNOWN then
            if FillPlaneUtil ~= nil and FillPlaneUtil.setFillType ~= nil then
                FillPlaneUtil.setFillType(newFillPlane, primaryFillType)
            end
        end

        -- Restore fill level visually
        if totalFillLevel > 0 then
            local x, y, z = localToWorld(newFillPlane, 0, 0, 0)
            local d1x, d1y, d1z = localDirectionToWorld(newFillPlane, 1, 0, 0)
            local d2x, d2y, d2z = localDirectionToWorld(newFillPlane, 0, 0, 1)

            local steps = math.max(1, math.floor(totalFillLevel / 400))
            steps = math.min(steps, 50)
            for _ = 1, steps do
                fillPlaneAdd(newFillPlane, totalFillLevel / steps, x, y, z, d1x, d1y, d1z, d2x, d2y, d2z)
            end
        end

        setVisibility(newFillPlane, totalFillLevel > 0)

        storage.dynamicFillPlane = newFillPlane
        Log:debug("Recreated storage dynamicFillPlane with capacity %d, restored %.0f fill", newCapacity, totalFillLevel)
    else
        Log:warning("Failed to recreate storage dynamicFillPlane - createFillPlaneShape returned nil")
        storage.dynamicFillPlane = nil
    end
end

--- Recreate a HusbandryFood's dynamicFoodPlane with updated capacity
---@param placeable table The placeable
---@param spec table The husbandryFood spec
function RmAdjustStorageCapacity:recreateHusbandryFoodDynamicPlane(placeable, spec)
    if spec.dynamicFoodPlane == nil or spec.baseNode == nil then
        return
    end

    -- Get current fill state
    local totalFillLevel = 0
    if placeable.getTotalFood ~= nil then
        totalFillLevel = placeable:getTotalFood()
    end
    local newCapacity = spec.capacity or 10000

    -- Get primary fill type for texture
    local primaryFillType = FillType.UNKNOWN
    if spec.fillLevels ~= nil then
        for fillType, fillLevel in pairs(spec.fillLevels) do
            if fillLevel > 0 then
                primaryFillType = fillType
                break
            end
        end
    end

    -- Store old fill plane reference
    local oldFillPlane = spec.dynamicFoodPlane
    local baseNode = spec.baseNode

    -- Delete old fill plane
    if oldFillPlane ~= nil then
        delete(oldFillPlane)
    end

    -- Create new fill plane with updated capacity
    local newFillPlane = createFillPlaneShape(
        baseNode,
        "fillPlane",
        newCapacity,
        1.0,          -- maxDelta: max heap height above surface
        math.rad(35), -- maxSurfaceAngle: heap slope angle
        math.rad(35), -- maxPhysicalSurfaceAngle: physical slope angle
        0.05,         -- maxSurfaceDistanceError: precision
        0.9,          -- maxSubDivEdgeLength: mesh subdivision
        1.35,         -- syncMaxSubDivEdgeLength: multiplayer sync subdivision
        false,        -- allSidePlanes
        false         -- retessellateTop
    )

    if newFillPlane ~= nil and newFillPlane ~= 0 then
        -- Apply material using game utility (same as PlaceableHusbandryFood.lua does)
        if FillPlaneUtil ~= nil and FillPlaneUtil.assignDefaultMaterialsFromTerrain ~= nil then
            FillPlaneUtil.assignDefaultMaterialsFromTerrain(newFillPlane, g_terrainNode)
        end

        -- Set fill type using game utility (same as PlaceableHusbandryFood.lua does)
        if primaryFillType ~= FillType.UNKNOWN then
            if FillPlaneUtil ~= nil and FillPlaneUtil.setFillType ~= nil then
                FillPlaneUtil.setFillType(newFillPlane, primaryFillType)
            end
        end

        -- Restore fill level visually
        if totalFillLevel > 0 then
            local x, y, z = localToWorld(newFillPlane, 0, 0, 0)
            local d1x, d1y, d1z = localDirectionToWorld(newFillPlane, 1, 0, 0)
            local d2x, d2y, d2z = localDirectionToWorld(newFillPlane, 0, 0, 1)

            local steps = math.max(1, math.floor(totalFillLevel / 400))
            steps = math.min(steps, 50)
            for _ = 1, steps do
                fillPlaneAdd(newFillPlane, totalFillLevel / steps, x, y, z, d1x, d1y, d1z, d2x, d2y, d2z)
            end
        end

        setVisibility(newFillPlane, totalFillLevel > 0)

        spec.dynamicFoodPlane = newFillPlane
        Log:debug("Recreated husbandryFood dynamicFoodPlane with capacity %d, restored %.0f fill", newCapacity,
            totalFillLevel)
    else
        Log:warning("Failed to recreate husbandryFood dynamicFoodPlane - createFillPlaneShape returned nil")
        spec.dynamicFoodPlane = nil
    end
end

--- Reset load speed to original for a placeable
---@param placeable table The placeable
function RmAdjustStorageCapacity:resetLoadSpeed(placeable)
    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        return
    end

    local originals = self.originalCapacities[uniqueId]
    if originals == nil or originals.loadSpeedLitersPerSec == nil then
        return
    end

    local loadingStation = self:getLoadingStation(placeable)
    if loadingStation == nil or loadingStation.loadTriggers == nil then
        return
    end

    -- Reset all load triggers to original speed
    for _, loadTrigger in ipairs(loadingStation.loadTriggers) do
        if loadTrigger.fillLitersPerMS ~= nil then
            loadTrigger.fillLitersPerMS = originals.loadSpeedLitersPerSec / 1000
            Log:debug("Reset load speed to %.0f l/sec for %s",
                originals.loadSpeedLitersPerSec, placeable:getName())
        end
    end
end

--- Apply all custom capacities to storage placeables
function RmAdjustStorageCapacity:applyAllCapacities()
    local applied = 0

    -- Iterate through all placeables looking for storages
    if g_currentMission.placeableSystem ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
            local uniqueId = placeable.uniqueId
            local customCapacity = self.customCapacities[uniqueId]

            if customCapacity ~= nil then
                if self:applyCapacitiesToPlaceable(placeable, customCapacity) then
                    applied = applied + 1
                end
            end
        end
    end

    if applied > 0 then
        Log:info("Applied custom capacities to %d storage(s)", applied)
    end
end

--- Apply all saved vehicle capacities (called after savegame load)
function RmAdjustStorageCapacity:applyAllVehicleCapacities()
    local applied = 0

    -- Iterate through all vehicles with custom capacities
    for uniqueId, fillUnitCapacities in pairs(self.vehicleCapacities) do
        local vehicle = self:findVehicleByUniqueId(uniqueId)
        if vehicle ~= nil then
            self:applyVehicleCapacities(vehicle)
            applied = applied + 1
        else
            Log:debug("Vehicle not found for uniqueId: %s", uniqueId)
        end
    end

    if applied > 0 then
        Log:info("Applied custom capacities to %d vehicle(s)", applied)
    end
end

--- Apply custom capacities to a specific placeable
---@param placeable table The storage placeable
---@param customCapacity table {fillTypes = {[fillTypeIndex] = capacity}, husbandryFood = capacity, sharedCapacity = capacity}
---@return boolean success Whether any capacities were applied
function RmAdjustStorageCapacity:applyCapacitiesToPlaceable(placeable, customCapacity)
    if placeable == nil or customCapacity == nil then
        return false
    end

    local storageInfo = self:getStorageInfo(placeable)
    if not storageInfo.hasStorage then
        return false
    end

    local applied = 0

    -- Apply shared capacity if specified
    if customCapacity.sharedCapacity ~= nil then
        for _, info in ipairs(storageInfo.storages) do
            local storage = info.storage
            if storage.capacity ~= nil then
                local oldCapacity = storage.capacity
                storage.capacity = customCapacity.sharedCapacity
                applied = applied + 1
                Log:debug("Applied shared capacity %d -> %d to %s",
                    oldCapacity, customCapacity.sharedCapacity, info.type)
            end
        end
    end

    -- Apply fillType capacities to Storage class instances
    if customCapacity.fillTypes ~= nil then
        for _, info in ipairs(storageInfo.storages) do
            local storage = info.storage

            -- Handle per-filltype capacities
            if storage.capacities ~= nil then
                for fillTypeIndex, capacity in pairs(customCapacity.fillTypes) do
                    if storage.capacities[fillTypeIndex] ~= nil then
                        -- Check for overfill situation (fillLevel > new capacity)
                        local currentFill = storage.fillLevels and storage.fillLevels[fillTypeIndex] or 0
                        if currentFill > capacity then
                            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                            local fillTypeName = fillType and fillType.name or "UNKNOWN"
                            Log:info(
                                "Storage overfilled: %s has %d but new capacity is %d (will drain naturally)",
                                fillTypeName, currentFill, capacity)
                        end

                        storage.capacities[fillTypeIndex] = capacity
                        applied = applied + 1
                        Log:trace("Applied capacity %d to %s fillType=%d",
                            capacity, info.type, fillTypeIndex)
                    end
                end
            end

            -- Handle shared capacity silos - set storage.capacity for any fillType change
            -- (Shared capacity silos use a single capacity value for all fill types)
            if storage.capacity ~= nil and storage.capacities == nil and storage.supportedFillTypes ~= nil then
                for fillTypeIndex, capacity in pairs(customCapacity.fillTypes) do
                    if storage.supportedFillTypes[fillTypeIndex] ~= nil then
                        local oldCapacity = storage.capacity
                        storage.capacity = capacity
                        applied = applied + 1
                        Log:debug("Applied shared capacity %d -> %d to %s (fillType %d triggered)",
                            oldCapacity, capacity, info.type, fillTypeIndex)
                        break -- Only apply once for shared capacity
                    end
                end
            end
        end
    end

    -- Apply HusbandryFood capacity
    if customCapacity.husbandryFood ~= nil and storageInfo.husbandryFood ~= nil then
        self:applyHusbandryFoodCapacity(storageInfo.husbandryFood, customCapacity.husbandryFood)
        applied = applied + 1
    end

    if applied > 0 then
        Log:debug("Applied %d capacity changes to %s", applied, placeable:getName())

        -- Apply proportional load speed based on capacity multiplier
        local multiplier = self:getMaxCapacityMultiplier(placeable, customCapacity)
        Log:debug("Capacity multiplier for %s: %.2f (sharedCapacity=%s, fillTypes=%s)",
            placeable:getName(), multiplier,
            tostring(customCapacity.sharedCapacity),
            customCapacity.fillTypes and "yes" or "no")
        if multiplier ~= 1.0 then
            self:applyProportionalLoadSpeed(placeable, multiplier)
        else
            Log:debug("Skipping load speed adjustment for %s (multiplier is 1.0)", placeable:getName())
        end

        -- Update visual fill planes to reflect new capacity
        self:updatePlaceableFillPlanes(placeable)
    end

    return applied > 0
end

--- Apply capacity to HusbandryFood
--- NOTE: We intentionally do NOT modify FILLLEVEL_NUM_BITS here.
---
--- MULTIPLAYER STREAM CORRUPTION BUG (discovered 2024-12-20):
--- PlaceableHusbandryFood.onWriteStream/onReadStream use FILLLEVEL_NUM_BITS to serialize
--- fill levels. This value is calculated from spec.capacity in onLoad (from XML).
---
--- If we modify FILLLEVEL_NUM_BITS on the server after applying custom capacity:
---   Server: capacity=50000 -> FILLLEVEL_NUM_BITS=16
---   Client: capacity=5000 (XML) -> FILLLEVEL_NUM_BITS=13
---   Server writes 16 bits per fill type, client reads 13 bits -> STREAM CORRUPTION
---   Subsequent specializations (e.g., PlaceableHusbandryFence) read garbage -> crash
---
--- CURRENT LIMITATION:
--- Fill levels above original XML capacity's bit range will be truncated during MP sync.
--- Example: Original capacity 5000 (13 bits, max 8191). If fill=10000, MP syncs as 1808.
--- This causes data loss but prevents crashes. Works correctly in singleplayer.
---
--- FUTURE IMPROVEMENT:
--- Use Event-based sync to update client's capacity BEFORE PlaceableHusbandryFood's
--- ReadStream runs, so both sides calculate the same FILLLEVEL_NUM_BITS.
---
---@param spec table The spec_husbandryFood table
---@param newCapacity number The new capacity
function RmAdjustStorageCapacity:applyHusbandryFoodCapacity(spec, newCapacity)
    if spec == nil then
        return
    end

    local oldCapacity = spec.capacity
    spec.capacity = newCapacity

    -- Calculate total current fill for logging
    local totalFill = 0
    if spec.fillLevels ~= nil then
        for _, level in pairs(spec.fillLevels) do
            totalFill = totalFill + level
        end
    end

    -- DO NOT modify FILLLEVEL_NUM_BITS - see function comment for MP stream corruption bug

    -- Log overfill situation if present
    if totalFill > newCapacity then
        Log:info("HusbandryFood overfilled: fillLevel %d > capacity %d (will drain naturally)",
            totalFill, newCapacity)
    end

    Log:debug("Applied HusbandryFood capacity: %d -> %d (fillLevel: %d, bits unchanged: %d)",
        oldCapacity, newCapacity, totalFill, spec.FILLLEVEL_NUM_BITS)
end

-- ============================================================================
-- Capacity Modification API
-- ============================================================================

--- Get the minimum allowed capacity (current fill level) for a placeable storage
--- Used to prevent setting capacity below current fill level
---@param placeable table The storage placeable
---@param fillTypeIndex number The fill type index (-1 for husbandryFood, 0 for shared capacity)
---@return number minCapacity The current fill level (minimum allowed capacity)
function RmAdjustStorageCapacity:getMinCapacity(placeable, fillTypeIndex)
    if placeable == nil then
        return 0
    end

    local storageInfo = self:getStorageInfo(placeable)

    -- Husbandry food: sum all food fill levels
    if fillTypeIndex == -1 then
        if storageInfo.husbandryFood and storageInfo.husbandryFood.fillLevels then
            local totalFill = 0
            for _, level in pairs(storageInfo.husbandryFood.fillLevels) do
                totalFill = totalFill + level
            end
            return math.floor(totalFill)
        end
        return 0
    end

    -- Shared capacity (fillTypeIndex == 0): sum all fill levels
    if fillTypeIndex == 0 then
        local totalFill = 0
        for _, info in ipairs(storageInfo.storages) do
            if info.storage.fillLevels then
                for _, level in pairs(info.storage.fillLevels) do
                    totalFill = totalFill + level
                end
            end
        end
        return math.floor(totalFill)
    end

    -- Per-fill-type: get specific fill level
    for _, info in ipairs(storageInfo.storages) do
        if info.storage.fillLevels and info.storage.fillLevels[fillTypeIndex] then
            return math.floor(info.storage.fillLevels[fillTypeIndex])
        end
    end

    return 0
end

--- Get the minimum allowed capacity (current fill level) for a vehicle fill unit
--- Used to prevent setting capacity below current fill level
---@param vehicle table The vehicle
---@param fillUnitIndex number The fill unit index (1-based)
---@return number minCapacity The current fill level (minimum allowed capacity)
function RmAdjustStorageCapacity:getMinVehicleCapacity(vehicle, fillUnitIndex)
    if vehicle == nil then
        return 0
    end

    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        return 0
    end

    local fillUnit = fillUnitSpec.fillUnits[fillUnitIndex]
    if fillUnit == nil then
        return 0
    end

    return math.floor(fillUnit.fillLevel or 0)
end

--- Set a custom capacity for a storage
---@param placeable table The storage placeable
---@param fillTypeIndex number The fill type index (-1 for husbandryFood)
---@param newCapacity number The new capacity
---@return boolean success Whether the capacity was set
---@return string|nil error Error message if failed
function RmAdjustStorageCapacity:setCapacity(placeable, fillTypeIndex, newCapacity)
    if placeable == nil then
        return false, "Storage not found"
    end

    if newCapacity < 0 then
        return false, "Capacity must be positive"
    end

    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        return false, "Storage has no unique ID"
    end

    -- Initialize custom capacity table for this placeable if needed
    if self.customCapacities[uniqueId] == nil then
        self.customCapacities[uniqueId] = {
            fillTypes = {},
            husbandryFood = nil,
            sharedCapacity = nil
        }
    end

    -- Handle HusbandryFood special case
    if fillTypeIndex == -1 then
        self.customCapacities[uniqueId].husbandryFood = newCapacity

        -- Apply immediately
        local storageInfo = self:getStorageInfo(placeable)
        if storageInfo.husbandryFood ~= nil then
            self:applyHusbandryFoodCapacity(storageInfo.husbandryFood, newCapacity)
            -- Update visual fill planes
            self:updatePlaceableFillPlanes(placeable)
        end

        Log:info("Set HusbandryFood capacity for %s to %d", placeable:getName(), newCapacity)
    else
        -- Check if this is a shared capacity silo
        local storageInfo = self:getStorageInfo(placeable)
        local isSharedCapacity = false

        for _, info in ipairs(storageInfo.storages) do
            local storage = info.storage
            -- Shared capacity: has storage.capacity but no storage.capacities
            if storage.capacity ~= nil and (storage.capacities == nil or next(storage.capacities) == nil) then
                isSharedCapacity = true
                break
            end
        end

        if isSharedCapacity then
            -- Shared capacity silo - set sharedCapacity
            self.customCapacities[uniqueId].sharedCapacity = newCapacity

            -- Apply immediately
            local customCapacity = { sharedCapacity = newCapacity }
            self:applyCapacitiesToPlaceable(placeable, customCapacity)

            Log:info("Set shared capacity for %s to %d", placeable:getName(), newCapacity)
        else
            -- Per-filltype capacity silo
            if self.customCapacities[uniqueId].fillTypes == nil then
                self.customCapacities[uniqueId].fillTypes = {}
            end
            self.customCapacities[uniqueId].fillTypes[fillTypeIndex] = newCapacity

            -- Apply immediately
            local customCapacity = { fillTypes = { [fillTypeIndex] = newCapacity } }
            self:applyCapacitiesToPlaceable(placeable, customCapacity)

            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local fillTypeName = fillType and fillType.title or "Unknown"
            Log:info("Set capacity for %s (%s) to %d", placeable:getName(), fillTypeName, newCapacity)
        end
    end

    return true, nil
end

--- Reset capacity to original for a storage
---@param placeable table The storage placeable
---@param fillTypeIndex number|nil The fill type index (nil = reset all, -1 = husbandryFood only)
---@return boolean success Whether the capacity was reset
---@return string|nil error Error message if failed
function RmAdjustStorageCapacity:resetCapacity(placeable, fillTypeIndex)
    if placeable == nil then
        return false, "Storage not found"
    end

    local uniqueId = placeable.uniqueId
    if uniqueId == nil then
        return false, "Storage has no unique ID"
    end

    local originals = self.originalCapacities[uniqueId]
    if originals == nil then
        return false, "No original capacities recorded"
    end

    if fillTypeIndex == -1 then
        -- Reset HusbandryFood only
        if self.customCapacities[uniqueId] ~= nil then
            self.customCapacities[uniqueId].husbandryFood = nil
        end

        if originals.husbandryFood ~= nil then
            local storageInfo = self:getStorageInfo(placeable)
            if storageInfo.husbandryFood ~= nil then
                self:applyHusbandryFoodCapacity(storageInfo.husbandryFood, originals.husbandryFood)
                -- Update visual fill planes
                self:updatePlaceableFillPlanes(placeable)
            end
        end

        Log:info("Reset HusbandryFood capacity for %s to original", placeable:getName())
    elseif fillTypeIndex ~= nil then
        -- Reset specific fill type (or shared capacity if it's a shared capacity silo)
        local storageInfo = self:getStorageInfo(placeable)
        local isSharedCapacity = false

        for _, info in ipairs(storageInfo.storages) do
            local storage = info.storage
            if storage.capacity ~= nil and (storage.capacities == nil or next(storage.capacities) == nil) then
                isSharedCapacity = true
                break
            end
        end

        if isSharedCapacity then
            -- Reset shared capacity
            if self.customCapacities[uniqueId] ~= nil then
                self.customCapacities[uniqueId].sharedCapacity = nil
            end

            if originals.sharedCapacity ~= nil then
                local customCapacity = { sharedCapacity = originals.sharedCapacity }
                self:applyCapacitiesToPlaceable(placeable, customCapacity)
            end

            Log:info("Reset shared capacity for %s to original", placeable:getName())
        else
            -- Reset per-filltype capacity
            if self.customCapacities[uniqueId] ~= nil and self.customCapacities[uniqueId].fillTypes ~= nil then
                self.customCapacities[uniqueId].fillTypes[fillTypeIndex] = nil
            end

            -- Apply original capacity
            if originals.fillTypes ~= nil and originals.fillTypes[fillTypeIndex] ~= nil then
                local customCapacity = { fillTypes = { [fillTypeIndex] = originals.fillTypes[fillTypeIndex] } }
                self:applyCapacitiesToPlaceable(placeable, customCapacity)
            end

            Log:info("Reset capacity for %s fillType=%d to original", placeable:getName(), fillTypeIndex)
        end
    else
        -- Reset all
        if originals.fillTypes ~= nil then
            local customCapacity = { fillTypes = originals.fillTypes }
            self:applyCapacitiesToPlaceable(placeable, customCapacity)
        end

        if originals.sharedCapacity ~= nil then
            local customCapacity = { sharedCapacity = originals.sharedCapacity }
            self:applyCapacitiesToPlaceable(placeable, customCapacity)
        end

        if originals.husbandryFood ~= nil then
            local storageInfo = self:getStorageInfo(placeable)
            if storageInfo.husbandryFood ~= nil then
                self:applyHusbandryFoodCapacity(storageInfo.husbandryFood, originals.husbandryFood)
                -- Update visual fill planes
                self:updatePlaceableFillPlanes(placeable)
            end
        end

        -- Reset load speed to original
        self:resetLoadSpeed(placeable)

        self.customCapacities[uniqueId] = nil
        Log:info("Reset all capacities for %s to original", placeable:getName())
    end

    -- Clean up empty custom capacity entries
    if self.customCapacities[uniqueId] ~= nil then
        local hasData = false
        if self.customCapacities[uniqueId].husbandryFood ~= nil then
            hasData = true
        end
        if self.customCapacities[uniqueId].fillTypes ~= nil and next(self.customCapacities[uniqueId].fillTypes) ~= nil then
            hasData = true
        end
        if self.customCapacities[uniqueId].sharedCapacity ~= nil then
            hasData = true
        end
        if not hasData then
            self.customCapacities[uniqueId] = nil
        end
    end

    return true, nil
end

-- ============================================================================
-- Vehicle Capacity Functions
-- ============================================================================

--- Set a custom capacity for a vehicle fill unit
---@param vehicle table The vehicle
---@param fillUnitIndex number The fill unit index (1-based)
---@param newCapacity number The new capacity
---@return boolean success Whether the capacity was set
---@return string|nil error Error message if failed
function RmAdjustStorageCapacity:setVehicleCapacity(vehicle, fillUnitIndex, newCapacity)
    if vehicle == nil then
        return false, "Vehicle not found"
    end

    if newCapacity < 0 then
        return false, "Capacity must be positive"
    end

    local uniqueId = vehicle.uniqueId
    if uniqueId == nil then
        return false, "Vehicle has no unique ID"
    end

    -- Initialize capacity table for this vehicle if needed
    if self.vehicleCapacities[uniqueId] == nil then
        self.vehicleCapacities[uniqueId] = {}
    end

    -- Store the custom capacity
    self.vehicleCapacities[uniqueId][fillUnitIndex] = newCapacity

    -- Apply immediately
    self:applyVehicleCapacity(vehicle, fillUnitIndex, newCapacity)

    Log:info("Set vehicle %s fillUnit[%d] capacity to %d", vehicle:getName(), fillUnitIndex, newCapacity)
    return true, nil
end

--- Reset a vehicle fill unit capacity to original
---@param vehicle table The vehicle
---@param fillUnitIndex number|nil The fill unit index (nil = reset all)
---@return boolean success Whether the capacity was reset
---@return string|nil error Error message if failed
function RmAdjustStorageCapacity:resetVehicleCapacity(vehicle, fillUnitIndex)
    if vehicle == nil then
        return false, "Vehicle not found"
    end

    local uniqueId = vehicle.uniqueId
    if uniqueId == nil then
        return false, "Vehicle has no unique ID"
    end

    local spec = vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return false, "Vehicle does not have storage capacity specialization"
    end

    if fillUnitIndex ~= nil and fillUnitIndex > 0 then
        -- Reset specific fill unit
        if self.vehicleCapacities[uniqueId] ~= nil then
            self.vehicleCapacities[uniqueId][fillUnitIndex] = nil

            -- Clean up empty table
            if next(self.vehicleCapacities[uniqueId]) == nil then
                self.vehicleCapacities[uniqueId] = nil
            end
        end

        -- Apply original capacity (this will also reset discharge speed via proportional calculation)
        local originalCapacity = spec.originalCapacities[fillUnitIndex]
        if originalCapacity ~= nil then
            self:applyVehicleCapacity(vehicle, fillUnitIndex, originalCapacity)
        end

        -- Explicitly reset discharge speed for this fill unit
        RmVehicleStorageCapacity.resetDischargeSpeed(vehicle, fillUnitIndex)

        Log:info("Reset vehicle %s fillUnit[%d] capacity to original", vehicle:getName(), fillUnitIndex)
    else
        -- Reset all fill units
        self.vehicleCapacities[uniqueId] = nil

        -- Apply all original capacities
        for fuIndex, originalCapacity in pairs(spec.originalCapacities) do
            self:applyVehicleCapacity(vehicle, fuIndex, originalCapacity)
        end

        -- Explicitly reset all discharge speeds
        RmVehicleStorageCapacity.resetDischargeSpeed(vehicle, nil)

        Log:info("Reset all capacities for vehicle %s to original", vehicle:getName())
    end

    return true, nil
end

--- Update FillVolume visual after fillUnit.capacity change
--- Recreates the 3D fill plane shape to reflect the new capacity
---@param vehicle table The vehicle
---@param fillUnitIndex number The fill unit index
---@param newCapacity number The new capacity value
function RmAdjustStorageCapacity:updateVehicleFillVolumeCapacity(vehicle, fillUnitIndex, newCapacity)
    if vehicle == nil then return end

    local fillVolumeSpec = vehicle.spec_fillVolume
    if fillVolumeSpec == nil or fillVolumeSpec.volumes == nil then return end

    -- Get current fill state from FillUnit
    local fillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
    local fillType = vehicle:getFillUnitFillType(fillUnitIndex) or FillType.UNKNOWN

    -- Update all fill volumes linked to this fill unit
    for i, fillVolume in ipairs(fillVolumeSpec.volumes) do
        if fillVolume.fillUnitIndex == fillUnitIndex then
            local factor = fillVolume.fillUnitFactor or 1
            local oldCapacity = fillVolume.capacity
            local newVolumeCapacity = newCapacity * factor

            -- Update the Lua capacity value
            fillVolume.capacity = newVolumeCapacity

            -- Recreate the 3D fill plane shape if it exists
            if fillVolume.volume ~= nil and fillVolume.baseNode ~= nil then
                -- Delete old fill plane shape
                delete(fillVolume.volume)

                -- Create new fill plane shape with updated capacity
                fillVolume.volume = createFillPlaneShape(
                    fillVolume.baseNode,
                    "fillPlane",
                    newVolumeCapacity,
                    fillVolume.maxDelta,
                    fillVolume.maxSurfaceAngle,
                    fillVolume.maxPhysicalSurfaceAngle,
                    fillVolume.maxSurfaceDistanceError,
                    fillVolume.maxSubDivEdgeLength,
                    fillVolume.syncMaxSubDivEdgeLength,
                    fillVolume.allSidePlanes,
                    fillVolume.retessellateTop
                )

                if fillVolume.volume ~= nil and fillVolume.volume ~= 0 then
                    -- Link to parent node
                    link(fillVolume.baseNode, fillVolume.volume)

                    -- Apply material
                    local fillVolumeMaterial = g_materialManager:getBaseMaterialByName("fillPlane")
                    if fillVolumeMaterial ~= nil then
                        setMaterial(fillVolume.volume, fillVolumeMaterial, 0)
                        g_fillTypeManager:assignFillTypeTextureArraysFromTerrain(fillVolume.volume, g_terrainNode, true,
                            true, true)
                    end

                    -- Recalculate height offset
                    fillPlaneAdd(fillVolume.volume, 1, 0, 1, 0, 11, 0, 0, 0, 0, 11)
                    fillVolume.heightOffset = getFillPlaneHeightAtLocalPos(fillVolume.volume, 0, 0)
                    fillPlaneAdd(fillVolume.volume, -1, 0, 1, 0, 11, 0, 0, 0, 0, 11)

                    -- Rebuild deformer polylines
                    for j = #fillVolume.deformers, 1, -1 do
                        local deformer = fillVolume.deformers[j]
                        deformer.polyline = findPolyline(fillVolume.volume, deformer.posX, deformer.posZ)
                        if deformer.polyline == nil or deformer.polyline == -1 then
                            Log:trace("Could not find polyline for deformer %d", j)
                        end
                    end

                    -- Set fill type texture if known
                    if fillType ~= FillType.UNKNOWN then
                        local textureArrayIndex = g_fillTypeManager:getTextureArrayIndexByFillTypeIndex(fillType)
                        if textureArrayIndex ~= nil then
                            setShaderParameter(fillVolume.volume, "fillTypeId", textureArrayIndex - 1, 0, 0, 0, false)
                        end

                        -- Set physical surface angle from fill type
                        local fillTypeInfo = g_fillTypeManager:getFillTypeByIndex(fillType)
                        if fillTypeInfo ~= nil and fillTypeInfo.maxPhysicalSurfaceAngle ~= nil then
                            setFillPlaneMaxPhysicalSurfaceAngle(fillVolume.volume, fillTypeInfo.maxPhysicalSurfaceAngle)
                        end
                    end

                    -- Restore fill level visually using fillPlaneAdd
                    local volumeFillLevel = math.min(fillLevel, newVolumeCapacity)
                    if volumeFillLevel > 0 then
                        -- Add fill in steps to build up the heap properly
                        local loadSize = 0.1
                        if fillVolume.maxPhysicalSurfaceAngle == 0 or fillVolume.maxSurfaceAngle == 0 then
                            loadSize = 10
                        end
                        local x, y, z = localToWorld(fillVolume.volume, -loadSize * 0.5, 0, -loadSize * 0.5)
                        local d1x, d1y, d1z = localDirectionToWorld(fillVolume.volume, loadSize, 0, 0)
                        local d2x, d2y, d2z = localDirectionToWorld(fillVolume.volume, 0, 0, loadSize)

                        local steps = math.max(1, math.floor(volumeFillLevel / 400))
                        steps = math.min(steps, 50) -- Cap iterations
                        for _ = 1, steps do
                            fillPlaneAdd(fillVolume.volume, volumeFillLevel / steps, x, y, z, d1x, d1y, d1z, d2x, d2y,
                                d2z)
                        end
                    end

                    -- Update internal fill level tracking
                    fillVolume.fillLevel = volumeFillLevel
                    fillVolume.lastFillType = fillType

                    -- Restore visibility
                    setVisibility(fillVolume.volume, volumeFillLevel > 0)

                    Log:debug("Recreated fillVolume[%d] with capacity %d -> %d, restored %.0f fill",
                        i, oldCapacity or 0, newVolumeCapacity, volumeFillLevel)
                else
                    Log:warning("Failed to recreate fillVolume[%d] - createFillPlaneShape returned nil", i)
                    fillVolume.volume = nil
                end
            else
                -- No 3D volume, just update capacity value
                Log:trace("Updated fillVolume[%d] capacity %d -> %d (no 3D shape)",
                    i, oldCapacity or 0, newVolumeCapacity)
            end
        end
    end
end

--- Apply custom capacities to a vehicle from stored settings
---@param vehicle table The vehicle
function RmAdjustStorageCapacity:applyVehicleCapacities(vehicle)
    if vehicle == nil then
        return
    end

    local uniqueId = vehicle.uniqueId
    if uniqueId == nil then
        return
    end

    local customCaps = self.vehicleCapacities[uniqueId]
    if customCaps == nil then
        return
    end

    for fillUnitIndex, capacity in pairs(customCaps) do
        self:applyVehicleCapacity(vehicle, fillUnitIndex, capacity)
    end

    Log:debug("Applied custom capacities to vehicle %s", vehicle:getName())
end

--- Apply a specific capacity to a vehicle fill unit
---@param vehicle table The vehicle
---@param fillUnitIndex number The fill unit index (1-based)
---@param capacity number The capacity to set
function RmAdjustStorageCapacity:applyVehicleCapacity(vehicle, fillUnitIndex, capacity)
    if vehicle == nil then
        return
    end

    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        return
    end

    local fillUnit = fillUnitSpec.fillUnits[fillUnitIndex]
    if fillUnit == nil then
        Log:warning("Fill unit %d not found on vehicle %s", fillUnitIndex, vehicle:getName())
        return
    end

    local oldCapacity = fillUnit.capacity
    fillUnit.capacity = capacity

    -- Check for overfill situation
    if fillUnit.fillLevel > capacity then
        Log:info("Vehicle %s fillUnit[%d] overfilled: %d > %d (will drain naturally)",
            vehicle:getName(), fillUnitIndex, fillUnit.fillLevel, capacity)
    end

    Log:debug("Applied capacity %d -> %d to vehicle %s fillUnit[%d]",
        oldCapacity, capacity, vehicle:getName(), fillUnitIndex)

    -- Apply proportional discharge speed
    local spec = vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec ~= nil and spec.applyProportionalDischargeSpeed ~= nil then
        -- Call via method on the vehicle/spec
        RmVehicleStorageCapacity.applyProportionalDischargeSpeed(vehicle, fillUnitIndex, capacity)
    end

    -- Update FillVolume cached capacity for visual representation
    self:updateVehicleFillVolumeCapacity(vehicle, fillUnitIndex, capacity)
end

--- Check if current player can modify a vehicle's capacity
---@param vehicle table The vehicle
---@return boolean canModify Whether the player can modify the capacity
---@return string|nil errorKey Localization key for error message if not allowed
function RmAdjustStorageCapacity:canModifyVehicleCapacity(vehicle)
    if vehicle == nil then
        return false, "rm_asc_error_notAvailable"
    end

    local ownerFarmId = vehicle:getOwnerFarmId()
    local playerFarmId = g_currentMission:getFarmId()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    -- Block modification of unowned/spectator assets (even admins)
    if ownerFarmId == 0 or ownerFarmId == FarmManager.SPECTATOR_FARM_ID then
        return false, "rm_asc_error_notModifiable"
    end

    -- Check admin/server status first (can modify ANY vehicle)
    if isMultiplayer then
        if g_currentMission:getIsServer() then
            return true, nil
        end
        if g_currentMission.isMasterUser then
            return true, nil
        end
    end

    -- Non-admin: must own the vehicle
    if ownerFarmId ~= playerFarmId then
        return false, "rm_asc_error_notOwner"
    end

    -- Single player: ownership is sufficient
    if not isMultiplayer then
        return true, nil
    end

    -- Multiplayer non-admin: must be farm manager
    local farm = g_farmManager:getFarmById(playerFarmId)
    if farm ~= nil and farm:isUserFarmManager(g_currentMission.playerUserId) then
        return true, nil
    end

    return false, "rm_asc_error_notManager"
end

--- Find a vehicle by its unique ID
---@param uniqueId string The unique ID to search for
---@return table|nil vehicle The vehicle or nil if not found
function RmAdjustStorageCapacity:findVehicleByUniqueId(uniqueId)
    if uniqueId == nil then
        return nil
    end

    -- FS25 has a direct lookup method
    if g_currentMission.vehicleSystem ~= nil then
        return g_currentMission.vehicleSystem:getVehicleByUniqueId(uniqueId)
    end

    return nil
end

--- Get all vehicles with fill units that can be modified
---@param onlyPermitted boolean|nil Filter to only include vehicles the player can modify (default: true)
---@return table Array of vehicles with fill units
function RmAdjustStorageCapacity:getAllVehiclesWithFillUnits(onlyPermitted)
    if onlyPermitted == nil then onlyPermitted = true end
    local vehicles = {}

    -- FS25 stores vehicles in vehicleSystem.vehicles, not g_currentMission.vehicles
    local vehicleList = {}
    if g_currentMission.vehicleSystem ~= nil then
        vehicleList = g_currentMission.vehicleSystem.vehicles or {}
    end

    local totalVehicles = 0
    for _, vehicle in pairs(vehicleList) do
        totalVehicles = totalVehicles + 1

        -- Use central eligibility check
        local isSupported, reason = RmVehicleStorageCapacity.isVehicleSupported(vehicle)
        if isSupported then
            if not onlyPermitted or self:canModifyVehicleCapacity(vehicle) then
                table.insert(vehicles, vehicle)
            end
        else
            Log:trace("Skipping vehicle (%s): %s", reason, vehicle:getName() or "unknown")
        end
    end

    Log:debug("getAllVehiclesWithFillUnits: Checked %d vehicles, found %d supported (onlyPermitted=%s)",
        totalVehicles, #vehicles, tostring(onlyPermitted))

    return vehicles
end

-- ============================================================================
-- Storage Lookup
-- ============================================================================

--- Get storage placeable by index
---@param index number The 1-based index
---@return table|nil placeable The storage placeable or nil
function RmAdjustStorageCapacity:getStorageByIndex(index)
    local storages = self:getAllStoragePlaceables()
    if index >= 1 and index <= #storages then
        return storages[index]
    end
    return nil
end

--- Get all placeables that have modifiable storage
---@param onlyPermitted boolean|nil Filter to only include placeables the player can modify (default: true)
---@return table Array of storage placeables
function RmAdjustStorageCapacity:getAllStoragePlaceables(onlyPermitted)
    if onlyPermitted == nil then onlyPermitted = true end
    local storages = {}

    if g_currentMission.placeableSystem ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
            if self:hasModifiableStorage(placeable) then
                if not onlyPermitted or self:canModifyCapacity(placeable) then
                    table.insert(storages, placeable)
                end
            end
        end
    end

    return storages
end

-- ============================================================================
-- GUI
-- ============================================================================

--- Show capacity dialog for a storage
---@param placeable table The storage placeable
function RmAdjustStorageCapacity:showCapacityDialog(placeable)
    if placeable == nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("rm_asc_error_notAvailable"))
        return
    end

    RmStorageCapacityDialog.show(placeable)
end

-- ============================================================================
-- Console Commands
-- ============================================================================

--- Console command: List all storages with capacities
function RmAdjustStorageCapacity:consoleCommandList()
    local storages = self:getAllStoragePlaceables()

    if #storages == 0 then
        return "No storage placeables found"
    end

    Log:info("=== Storage Capacities ===")

    for i, placeable in ipairs(storages) do
        local uniqueId = placeable.uniqueId or "N/A"
        local name = placeable:getName() or "Unknown"
        local ownerFarmId = placeable:getOwnerFarmId() or 0

        local customMarker = ""
        if self.customCapacities[uniqueId] then
            customMarker = " [CUSTOM]"
        end

        -- Determine storage type
        local storageInfo = self:getStorageInfo(placeable)
        local typeDesc = {}
        if #storageInfo.storages > 0 then
            local types = {}
            for _, info in ipairs(storageInfo.storages) do
                types[info.type] = true
            end
            for t, _ in pairs(types) do
                table.insert(typeDesc, t)
            end
        end
        if storageInfo.husbandryFood then
            table.insert(typeDesc, "husbandryFood")
        end

        Log:info(string.format("#%d: %s (Farm %d) [%s]%s",
            i, name, ownerFarmId, table.concat(typeDesc, ","), customMarker))
        Log:info(string.format("    UniqueId: %s", uniqueId))

        -- Debug: Show storage structure for troubleshooting
        for j, info in ipairs(storageInfo.storages) do
            local storage = info.storage
            local hasCapacities = storage.capacities ~= nil and next(storage.capacities) ~= nil
            local hasCapacity = storage.capacity ~= nil
            local hasSupportedFillTypes = storage.supportedFillTypes ~= nil
            local hasFillLevels = storage.fillLevels ~= nil
            -- When capacities=true, the storage.capacity value is unused (per-filltype mode)
            local capacityStr = "nil"
            if hasCapacity then
                if hasCapacities then
                    capacityStr = string.format("%d (unused)", storage.capacity)
                else
                    capacityStr = tostring(storage.capacity)
                end
            end
            Log:debug("    Storage %d: capacities=%s, capacity=%s, supportedFillTypes=%s, fillLevels=%s",
                j,
                tostring(hasCapacities),
                capacityStr,
                tostring(hasSupportedFillTypes),
                tostring(hasFillLevels))
        end

        -- Show fill types and capacities
        local fillTypes = self:getAllFillTypes(placeable)
        if #fillTypes == 0 then
            Log:info("    (no fill types detected)")
        end
        for _, ft in ipairs(fillTypes) do
            local customMark = ""
            local custom = self.customCapacities[uniqueId]
            if custom ~= nil then
                if ft.fillTypeIndex == -1 and custom.husbandryFood ~= nil then
                    customMark = " *"
                elseif ft.isSharedCapacity and custom.sharedCapacity ~= nil then
                    customMark = " *"
                elseif custom.fillTypes ~= nil and custom.fillTypes[ft.fillTypeIndex] ~= nil then
                    customMark = " *"
                end
            end
            -- Show fillType name for easier console command usage
            local ftName = "husbandryFood"
            if ft.fillTypeIndex ~= -1 then
                local ftData = g_fillTypeManager:getFillTypeByIndex(ft.fillTypeIndex)
                ftName = ftData and ftData.name or "UNKNOWN"
            end
            -- Show [SHARED] marker for shared capacity silos
            local sharedMark = ft.isSharedCapacity and " [SHARED]" or ""
            Log:info(string.format("    - %s (%d): %d%s%s",
                ftName, ft.fillTypeIndex, ft.capacity, sharedMark, customMark))
        end
    end

    return string.format("Listed %d storage(s). Use 'ascSet <index> <fillType> <capacity>' to set capacity.", #storages)
end

--- Console command: Set capacity
function RmAdjustStorageCapacity:consoleCommandSet(indexStr, fillTypeStr, capacityStr)
    if indexStr == nil or fillTypeStr == nil or capacityStr == nil then
        return
        "Usage: ascSet <index> <fillType> <capacity>\n  fillType: -1 for husbandryFood, index number, or name (e.g., WHEAT)"
    end

    local index = tonumber(indexStr)
    local capacity = tonumber(capacityStr)

    if index == nil or capacity == nil then
        return "Invalid arguments. Index and capacity must be numbers."
    end

    -- fillType can be a number OR a name string
    local fillTypeIndex = tonumber(fillTypeStr)
    if fillTypeIndex == nil then
        -- Not a number, try as fillType name (e.g., "WHEAT", "WATER")
        fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeStr)
        if fillTypeIndex == nil then
            return string.format("Unknown fill type '%s'. Use ascList to see valid fill types.", fillTypeStr)
        end
    end

    local placeable = self:getStorageByIndex(index)
    if placeable == nil then
        return "Storage not found (use ascList to see valid indexes)"
    end

    -- Check permission
    local canModify, errorKey = self:canModifyCapacity(placeable)
    if not canModify then
        return "Error: " .. (CONSOLE_ERRORS[errorKey] or errorKey)
    end

    -- Use sync event for MP support
    RmStorageCapacitySyncEvent.sendSetCapacity(placeable, fillTypeIndex, capacity)
    return "Capacity change requested..."
end

--- Console command: Reset capacity
function RmAdjustStorageCapacity:consoleCommandReset(indexStr, fillTypeStr)
    if indexStr == nil then
        return
        "Usage: ascReset <index> [fillType]\n  fillType: -1 for husbandryFood, index number, name (e.g., WHEAT), or omit to reset all"
    end

    local index = tonumber(indexStr)
    if index == nil then
        return "Invalid index"
    end

    local placeable = self:getStorageByIndex(index)
    if placeable == nil then
        return "Storage not found (use ascList to see valid indexes)"
    end

    -- Check permission
    local canModify, errorKey = self:canModifyCapacity(placeable)
    if not canModify then
        return "Error: " .. (CONSOLE_ERRORS[errorKey] or errorKey)
    end

    -- fillType can be nil (reset all), a number, or a name string
    local fillTypeIndex = nil
    if fillTypeStr ~= nil then
        fillTypeIndex = tonumber(fillTypeStr)
        if fillTypeIndex == nil then
            -- Not a number, try as fillType name
            fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeStr)
            if fillTypeIndex == nil then
                return string.format("Unknown fill type '%s'. Use ascList to see valid fill types.", fillTypeStr)
            end
        end
    end

    RmStorageCapacitySyncEvent.sendResetCapacity(placeable, fillTypeIndex)
    return "Capacity reset requested..."
end

-- ============================================================================
-- Vehicle Console Commands
-- ============================================================================

--- Console command: List all vehicles with fill units
function RmAdjustStorageCapacity:consoleCommandListVehicles()
    local vehicles = self:getAllVehiclesWithFillUnits()

    if #vehicles == 0 then
        return "No vehicles with fill units found"
    end

    Log:info("=== Vehicle Fill Unit Capacities ===")

    for i, vehicle in ipairs(vehicles) do
        local uniqueId = vehicle.uniqueId or "N/A"
        local name = vehicle:getName() or "Unknown"
        local ownerFarmId = vehicle:getOwnerFarmId() or 0

        local customMarker = ""
        if self.vehicleCapacities[uniqueId] then
            customMarker = " [CUSTOM]"
        end

        Log:info(string.format("#%d: %s (Farm %d)%s",
            i, name, ownerFarmId, customMarker))
        Log:info(string.format("    UniqueId: %s", uniqueId))

        -- Show fill units
        local fillUnitSpec = vehicle.spec_fillUnit
        if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
            -- Build set of fill unit indexes used by Leveler specialization (internal mechanics)
            local levelerFillUnits = {}
            local levelerSpec = vehicle.spec_leveler
            if levelerSpec ~= nil then
                if levelerSpec.fillUnitIndex ~= nil then
                    levelerFillUnits[levelerSpec.fillUnitIndex] = true
                end
                if levelerSpec.nodes ~= nil then
                    for _, node in pairs(levelerSpec.nodes) do
                        if node.fillUnitIndex ~= nil then
                            levelerFillUnits[node.fillUnitIndex] = true
                        end
                    end
                end
            end

            for j, fillUnit in ipairs(fillUnitSpec.fillUnits) do
                -- Skip leveler fill units - internal buffers for bunker silo leveling
                if levelerFillUnits[j] then
                    Log:debug("    - [%d] (leveler buffer - skipped, capacity=%d L)", j, fillUnit.capacity)
                else
                    -- Get fill type info and display name
                    local ftName = "EMPTY"
                    local displayName = string.format("Tank %d", j)
                    if fillUnit.fillType ~= nil and fillUnit.fillType ~= FillType.UNKNOWN then
                        local ftData = g_fillTypeManager:getFillTypeByIndex(fillUnit.fillType)
                        if ftData ~= nil then
                            ftName = ftData.name or "UNKNOWN"
                            -- Use fill type title as display name (properly localized)
                            if ftData.title ~= nil and ftData.title ~= "" then
                                displayName = ftData.title
                            end
                        end
                    else
                        -- Empty container - check if it's multi-purpose storage
                        if fillUnit.supportedFillTypes ~= nil and next(fillUnit.supportedFillTypes) ~= nil then
                            displayName = "Storage"
                        end
                    end

                    -- Check for custom capacity
                    local customMark = ""
                    local customCaps = self.vehicleCapacities[uniqueId]
                    if customCaps ~= nil and customCaps[j] ~= nil then
                        customMark = " *"
                    end

                    Log:info(string.format("    - [%d] %s: %d / %d L (%s)%s",
                        j, displayName, math.floor(fillUnit.fillLevel), fillUnit.capacity, ftName, customMark))

                    -- Show supported fill types (for debugging multi-fill-unit vehicles)
                    if fillUnit.supportedFillTypes ~= nil then
                        local supportedNames = {}
                        for ftIndex, isSupported in pairs(fillUnit.supportedFillTypes) do
                            if isSupported then
                                local ftData = g_fillTypeManager:getFillTypeByIndex(ftIndex)
                                if ftData ~= nil then
                                    table.insert(supportedNames, ftData.name or "?")
                                end
                            end
                        end
                        if #supportedNames > 0 then
                            table.sort(supportedNames)
                            -- Truncate if too many
                            if #supportedNames > 10 then
                                local count = #supportedNames
                                supportedNames = { table.unpack(supportedNames, 1, 10) }
                                table.insert(supportedNames, string.format("... +%d more", count - 10))
                            end
                            Log:info(string.format("      Supports: %s", table.concat(supportedNames, ", ")))
                        end
                    end
                end
            end
        end
    end

    return string.format("Listed %d vehicle(s). Use 'ascSetVehicle <index> <fillUnit> <capacity>' to set capacity.",
        #vehicles)
end

--- Console command: Set vehicle capacity
function RmAdjustStorageCapacity:consoleCommandSetVehicle(indexStr, fillUnitStr, capacityStr)
    if indexStr == nil or fillUnitStr == nil or capacityStr == nil then
        return "Usage: ascSetVehicle <index> <fillUnit> <capacity>\n  fillUnit: 1-based fill unit index"
    end

    local index = tonumber(indexStr)
    local fillUnitIndex = tonumber(fillUnitStr)
    local capacity = tonumber(capacityStr)

    if index == nil or fillUnitIndex == nil or capacity == nil then
        return "Invalid arguments. All values must be numbers."
    end

    local vehicles = self:getAllVehiclesWithFillUnits()
    if index < 1 or index > #vehicles then
        return "Vehicle not found (use ascListVehicles to see valid indexes)"
    end

    local vehicle = vehicles[index]

    -- Check permission
    local canModify, errorKey = self:canModifyVehicleCapacity(vehicle)
    if not canModify then
        return "Error: " .. (CONSOLE_ERRORS[errorKey] or errorKey)
    end

    -- Use sync event for MP support
    RmVehicleCapacitySyncEvent.sendSetCapacity(vehicle, fillUnitIndex, capacity)
    return "Vehicle capacity change requested..."
end

--- Console command: Reset vehicle capacity
function RmAdjustStorageCapacity:consoleCommandResetVehicle(indexStr, fillUnitStr)
    if indexStr == nil then
        return "Usage: ascResetVehicle <index> [fillUnit]\n  fillUnit: 1-based fill unit index, or omit to reset all"
    end

    local index = tonumber(indexStr)
    if index == nil then
        return "Invalid index"
    end

    local vehicles = self:getAllVehiclesWithFillUnits()
    if index < 1 or index > #vehicles then
        return "Vehicle not found (use ascListVehicles to see valid indexes)"
    end

    local vehicle = vehicles[index]

    -- Check permission
    local canModify, errorKey = self:canModifyVehicleCapacity(vehicle)
    if not canModify then
        return "Error: " .. (CONSOLE_ERRORS[errorKey] or errorKey)
    end

    -- fillUnit can be nil (reset all) or a number
    local fillUnitIndex = nil
    if fillUnitStr ~= nil then
        fillUnitIndex = tonumber(fillUnitStr)
        if fillUnitIndex == nil then
            return "Invalid fill unit index"
        end
    end

    RmVehicleCapacitySyncEvent.sendResetCapacity(vehicle, fillUnitIndex)
    return "Vehicle capacity reset requested..."
end

-- ============================================================================
-- Debug/Logging
-- ============================================================================

--- Log all storages with their properties
function RmAdjustStorageCapacity:logAllStorages()
    local storages = self:getAllStoragePlaceables()
    Log:info("Found %d storage placeable(s)", #storages)

    for i, placeable in ipairs(storages) do
        local uniqueId = placeable.uniqueId or "N/A"
        local name = placeable:getName() or "Unknown"
        local ownerFarmId = placeable:getOwnerFarmId() or 0
        local customMarker = self.customCapacities[uniqueId] and " [CUSTOM]" or ""

        local storageInfo = self:getStorageInfo(placeable)
        local storageCount = #storageInfo.storages
        local hasFood = storageInfo.husbandryFood ~= nil and "+food" or ""

        Log:debug("  #%d: %s (Farm %d, %d storages%s)%s",
            i, name, ownerFarmId, storageCount, hasFood, customMarker)
    end
end

--- Log all vehicles with fill units
function RmAdjustStorageCapacity:logAllVehicles()
    local vehicles = self:getAllVehiclesWithFillUnits()
    Log:info("Found %d vehicle(s) with fill units", #vehicles)

    for i, vehicle in ipairs(vehicles) do
        local uniqueId = vehicle.uniqueId or "N/A"
        local name = vehicle:getName() or "Unknown"
        local ownerFarmId = vehicle:getOwnerFarmId() or 0
        local customMarker = self.vehicleCapacities[uniqueId] and " [CUSTOM]" or ""

        local fillUnitSpec = vehicle.spec_fillUnit
        local fillUnitCount = fillUnitSpec and fillUnitSpec.fillUnits and #fillUnitSpec.fillUnits or 0

        Log:debug("  #%d: %s (Farm %d, %d fill units)%s",
            i, name, ownerFarmId, fillUnitCount, customMarker)
    end
end

--- Called when map is about to unload
function RmAdjustStorageCapacity:deleteMap()
    Log:debug("Mod unloading")

    -- Note: Keybind cleanup is now handled by activatableObjectsSystem
    -- via RmPlaceableCapacityActivatable and RmVehicleCapacityActivatable

    -- Remove placeable console commands
    removeConsoleCommand("ascList")
    removeConsoleCommand("ascSet")
    removeConsoleCommand("ascReset")

    -- Remove vehicle console commands
    removeConsoleCommand("ascListVehicles")
    removeConsoleCommand("ascSetVehicle")
    removeConsoleCommand("ascResetVehicle")

    RmLogging.unregisterConsoleCommands()

    -- Clear placeable data
    self.customCapacities = {}
    self.originalCapacities = {}

    -- Clear vehicle data
    self.vehicleCapacities = {}
end

-- ============================================================================
-- Game Hooks
-- ============================================================================

-- Hook onStartMission - fires after placeables are populated
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission,
    RmAdjustStorageCapacity.onMissionStarted)

-- Register mod event listener (calls loadMap/deleteMap)
addModEventListener(RmAdjustStorageCapacity)
