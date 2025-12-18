-- RmVehicleStorageCapacity - Vehicle specialization for capacity adjustment
-- Author: Ritter
--
-- This specialization enables capacity adjustment for vehicle fill units (trailers, harvesters, tankers).
-- Stores original capacities and handles network synchronization for multiplayer.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmVehicleStorageCapacity = {}

-- Capture mod name at file load time (when sourced by addSpecialization)
RmVehicleStorageCapacity.MOD_NAME = g_currentModName
-- Spec name for injection: "modName.shortName"
RmVehicleStorageCapacity.SPEC_NAME = string.format("%s.rmVehicleStorageCapacity", g_currentModName)
-- Spec table name on vehicle: "spec_modName.shortName" (per BulkFill pattern)
RmVehicleStorageCapacity.SPEC_TABLE_NAME = ("spec_%s.rmVehicleStorageCapacity"):format(g_currentModName)

-- ============================================================================
-- Vehicle Eligibility Check (shared utility)
-- ============================================================================

--- Check if a vehicle is supported for capacity adjustment
--- This is the central check used by both detection handler and console commands.
---@param vehicle table|nil The vehicle to check
---@return boolean isSupported True if vehicle can have capacity adjusted
---@return string|nil reason Reason code if not supported (for logging)
function RmVehicleStorageCapacity.isVehicleSupported(vehicle)
    if vehicle == nil then
        return false, "nil"
    end

    -- Must be a Vehicle class
    if vehicle.isa == nil or not vehicle:isa(Vehicle) then
        return false, "not_vehicle"
    end

    -- Must have FillUnit specialization with fill units
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil or #fillUnitSpec.fillUnits == 0 then
        return false, "no_fill_units"
    end

    -- Must have our specialization installed
    if vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME] == nil then
        return false, "no_spec"
    end

    -- Exclude pallets - they ARE the product, not containers
    -- Pallet specialization sets vehicle.isPallet = true in onPreLoad
    if vehicle.isPallet == true then
        return false, "is_pallet"
    end

    -- Exclude big bags - they ARE the product, not containers
    if vehicle.spec_bigBag ~= nil then
        return false, "is_bigbag"
    end

    return true, nil
end

-- ============================================================================
-- Specialization Registration
-- ============================================================================

--- Check if this specialization can be added
--- Returns true if vehicle has FillUnit specialization with fill units
function RmVehicleStorageCapacity.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(FillUnit, specializations)
end

--- Register event listeners for this specialization
function RmVehicleStorageCapacity.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", RmVehicleStorageCapacity)
end

--- Called when vehicle is loaded
function RmVehicleStorageCapacity:onLoad(savegame)
    local specTableName = RmVehicleStorageCapacity.SPEC_TABLE_NAME
    local spec = self[specTableName]

    Log:debug("onLoad: %s", self:getName())

    if spec == nil then
        -- FS25 should have created this - create fallback if missing
        self[specTableName] = {}
        spec = self[specTableName]
        Log:debug("onLoad: %s - created fallback spec table", self:getName())
    end

    -- Storage for original capacities {[fillUnitIndex] = originalCapacity}
    spec.originalCapacities = {}
end

--- Called after vehicle loads - capture original capacities
function RmVehicleStorageCapacity:onPostLoad(savegame)
    local spec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    local fillUnitSpec = self.spec_fillUnit

    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        Log:debug("onPostLoad: %s has no fill units", self:getName())
        return
    end

    -- Capture original capacities for each fill unit
    for i, fillUnit in ipairs(fillUnitSpec.fillUnits) do
        spec.originalCapacities[i] = fillUnit.capacity
    end

    -- Apply any stored custom capacities (from savegame load on server)
    if g_server ~= nil then
        RmAdjustStorageCapacity:applyVehicleCapacities(self)
    end

    Log:debug("onPostLoad: %s - %d fill units, capacities captured",
        self:getName(), #fillUnitSpec.fillUnits)
end

--- Called when vehicle is deleted/sold - clean up custom capacities
function RmVehicleStorageCapacity:onDelete()
    local uniqueId = self.uniqueId

    if uniqueId ~= nil then
        local hadCustomCapacity = RmAdjustStorageCapacity.vehicleCapacities[uniqueId] ~= nil

        -- Clean up custom capacities
        RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = nil

        if hadCustomCapacity then
            Log:debug("Cleaned up custom capacities for deleted vehicle: %s", self:getName() or uniqueId)
        end
    end
end

--- Called on server side when syncing vehicle to a new client
---@param streamId number Network stream ID
---@param connection table Network connection
function RmVehicleStorageCapacity:onWriteStream(streamId, connection)
    local uniqueId = self.uniqueId
    local customCaps = nil

    if uniqueId ~= nil then
        customCaps = RmAdjustStorageCapacity.vehicleCapacities[uniqueId]
    end

    -- Write whether we have custom capacities
    if streamWriteBool(streamId, customCaps ~= nil) then
        -- Count fill units with custom capacities
        local count = 0
        for _ in pairs(customCaps) do
            count = count + 1
        end
        streamWriteInt32(streamId, count)

        -- Write each fill unit's custom capacity
        for fillUnitIndex, capacity in pairs(customCaps) do
            streamWriteInt32(streamId, fillUnitIndex)
            streamWriteInt32(streamId, capacity)
        end

        Log:debug("WriteStream: Sent %d custom capacities for %s", count, self:getName())
    end
end

--- Called on client side when receiving vehicle sync from server
---@param streamId number Network stream ID
---@param connection table Network connection
function RmVehicleStorageCapacity:onReadStream(streamId, connection)
    local uniqueId = self.uniqueId

    -- Read whether we have custom capacities
    if streamReadBool(streamId) then
        local entry = {}
        local count = streamReadInt32(streamId)

        -- Read each fill unit's custom capacity
        for _ = 1, count do
            local fillUnitIndex = streamReadInt32(streamId)
            local capacity = streamReadInt32(streamId)
            entry[fillUnitIndex] = capacity
        end

        if uniqueId ~= nil then
            RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = entry

            -- Apply the custom capacities
            RmAdjustStorageCapacity:applyVehicleCapacities(self)

            Log:debug("ReadStream: Applied %d custom capacities for %s", count, self:getName())
        else
            Log:warning("ReadStream: Vehicle %s has nil uniqueId, cannot store capacities", self:getName())
        end
    end
end

--- Get the original capacity for a fill unit
---@param fillUnitIndex number The fill unit index (1-based)
---@return number|nil originalCapacity The original capacity or nil
function RmVehicleStorageCapacity:getOriginalCapacity(fillUnitIndex)
    local spec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil or spec.originalCapacities == nil then
        return nil
    end
    return spec.originalCapacities[fillUnitIndex]
end

--- Check if this vehicle has any fill units
---@return boolean hasFillUnits True if vehicle has fill units
function RmVehicleStorageCapacity:hasFillUnits()
    local fillUnitSpec = self.spec_fillUnit
    return fillUnitSpec ~= nil
        and fillUnitSpec.fillUnits ~= nil
        and #fillUnitSpec.fillUnits > 0
end

--- Get all fill unit information for this vehicle
---@return table fillUnits Array of {index, name, capacity, fillLevel, fillType, supportedFillTypes}
function RmVehicleStorageCapacity:getAllFillUnitInfo()
    local result = {}
    local fillUnitSpec = self.spec_fillUnit

    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        return result
    end

    -- Build set of fill unit indexes used by Leveler specialization (internal mechanics)
    local levelerFillUnits = {}
    local levelerSpec = self.spec_leveler
    if levelerSpec ~= nil then
        -- Main leveler fillUnitIndex
        if levelerSpec.fillUnitIndex ~= nil then
            levelerFillUnits[levelerSpec.fillUnitIndex] = true
        end
        -- Each leveler node can have its own fillUnitIndex
        if levelerSpec.nodes ~= nil then
            for _, node in pairs(levelerSpec.nodes) do
                if node.fillUnitIndex ~= nil then
                    levelerFillUnits[node.fillUnitIndex] = true
                end
            end
        end
    end

    for i, fillUnit in ipairs(fillUnitSpec.fillUnits) do
        -- Skip leveler fill units - they're internal buffers for pushing/leveling in bunker silos
        -- Adjusting their capacity would affect leveling mechanics unpredictably
        if levelerFillUnits[i] then
            Log:trace("Skipping leveler fill unit %d (capacity=%d L)", i, fillUnit.capacity)
        else
            -- Determine display name from fill type title (avoids l10n issues with unitText)
            local displayName = string.format("Tank %d", i)
            -- Only get title if fillType is valid (not UNKNOWN), otherwise getFillTypeTitleByIndex returns "Unknown"
            if fillUnit.fillType ~= nil and fillUnit.fillType ~= FillType.UNKNOWN then
                local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(fillUnit.fillType)
                if fillTypeTitle ~= nil and fillTypeTitle ~= "" then
                    displayName = fillTypeTitle
                end
            elseif fillUnit.supportedFillTypes ~= nil and next(fillUnit.supportedFillTypes) ~= nil then
                -- Empty multi-purpose container
                displayName = "Storage"
            end

            -- Get supported fill types
            local supportedFillTypes = {}
            if fillUnit.supportedFillTypes ~= nil then
                for fillTypeIndex, _ in pairs(fillUnit.supportedFillTypes) do
                    table.insert(supportedFillTypes, fillTypeIndex)
                end
            end

            table.insert(result, {
                index = i,
                name = displayName,
                capacity = fillUnit.capacity,
                fillLevel = fillUnit.fillLevel,
                fillType = fillUnit.fillType,
                supportedFillTypes = supportedFillTypes
            })
        end
    end

    return result
end
