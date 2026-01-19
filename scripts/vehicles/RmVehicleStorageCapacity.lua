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

--- Initialize specialization - called by SpecializationManager:initSpecializations()
--- This is the correct place to register savegame schema paths for mod specializations.
function RmVehicleStorageCapacity.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    if schemaSavegame == nil then
        Log:error("Vehicle.xmlSchemaSavegame is nil in initSpecialization - cannot register savegame paths")
        return
    end

    -- Register savegame paths for our custom capacity data
    -- Format: vehicles.vehicle(?).MODNAME.specShortName.fillUnits.fillUnit(?)
    local basePath = "vehicles.vehicle(?)." .. RmVehicleStorageCapacity.SPEC_NAME

    schemaSavegame:register(XMLValueType.INT, basePath .. ".fillUnits.fillUnit(?)#index", "Fill unit index")
    schemaSavegame:register(XMLValueType.INT, basePath .. ".fillUnits.fillUnit(?)#capacity", "Custom capacity for fill unit")

    Log:info("Vehicle savegame schema paths registered at: %s", basePath)
end

--- Register XML paths for this specialization (vehicle definition schema)
--- NOTE: This is for the vehicle DEFINITION XML, not savegame.
--- Savegame schema registration is done in initSpecialization().
---@param _schema table The vehicle XML schema
function RmVehicleStorageCapacity.registerXMLPaths(_schema)
    -- Vehicle definition paths would go here if we needed any
    -- Savegame paths are registered in initSpecialization()
end

--- Register event listeners for this specialization
function RmVehicleStorageCapacity.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", RmVehicleStorageCapacity)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", RmVehicleStorageCapacity)
    -- NOTE: Vehicles don't have loadFromXMLFile event - savegame data comes via onLoad(savegame)
    -- saveToXMLFile IS called for vehicles (registered as direct function on spec)
end

--- Called when vehicle is loaded
--- For vehicles, savegame data comes via the savegame parameter (NOT loadFromXMLFile event)
--- CRITICAL TIMING: Our onLoad runs AFTER FillUnit:onLoad (specs fire in registration order).
--- FillUnit:onLoad creates the fillUnits array. So fillUnits EXIST when our onLoad runs!
--- We must apply capacity HERE, before FillUnit:onPostLoad loads fill levels (which caps to capacity).
function RmVehicleStorageCapacity:onLoad(savegame)
    local specTableName = RmVehicleStorageCapacity.SPEC_TABLE_NAME
    local spec = self[specTableName]
    local vehicleName = self:getName() or "Unknown"

    Log:debug("onLoad: %s", vehicleName)

    if spec == nil then
        -- FS25 should have created this - create fallback if missing
        self[specTableName] = {}
        spec = self[specTableName]
        Log:debug("onLoad: %s - created fallback spec table", vehicleName)
    end

    -- Storage for original capacities {[fillUnitIndex] = originalCapacity}
    spec.originalCapacities = {}

    -- Storage for original discharge speeds {[nodeIndex] = {emptySpeedLitersPerSec, fillUnitIndex}}
    spec.originalDischargeSpeeds = {}

    -- Capture original capacities NOW (FillUnit:onLoad has already run, fillUnits exist)
    local fillUnitSpec = self.spec_fillUnit
    if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
        for i, fillUnit in ipairs(fillUnitSpec.fillUnits) do
            spec.originalCapacities[i] = fillUnit.capacity
        end
        Log:debug("onLoad: %s - captured %d original capacities", vehicleName, #fillUnitSpec.fillUnits)
    end

    -- Capture original discharge speeds (Dischargeable specialization)
    local dischargeSpec = self.spec_dischargeable
    if dischargeSpec ~= nil and dischargeSpec.dischargeNodes ~= nil then
        for i, node in ipairs(dischargeSpec.dischargeNodes) do
            if node.emptySpeed ~= nil then
                -- Convert from l/ms to l/sec for storage
                spec.originalDischargeSpeeds[i] = {
                    emptySpeedLitersPerSec = node.emptySpeed * 1000,
                    fillUnitIndex = node.fillUnitIndex
                }
                Log:trace("onLoad: %s - captured discharge speed %.0f l/sec for node %d (fillUnit %d)",
                    vehicleName, node.emptySpeed * 1000, i, node.fillUnitIndex)
            end
        end
        if #dischargeSpec.dischargeNodes > 0 then
            Log:debug("onLoad: %s - captured %d original discharge speeds", vehicleName, #dischargeSpec.dischargeNodes)
        end
    end

    -- Load and apply custom capacity from savegame (server only)
    -- This MUST happen in onLoad, BEFORE FillUnit:onPostLoad loads fill levels
    if g_server ~= nil and savegame ~= nil then
        local uniqueId = self.uniqueId
        Log:debug("LOAD_SAVEGAME_START: %s (uniqueId=%s, savegame.key=%s)",
            vehicleName, tostring(uniqueId), savegame.key)

        if uniqueId ~= nil then
            -- Check for embedded data in savegame
            -- The key format matches what saveToXMLFile writes: "vehicles.vehicle(N).MODNAME.specName"
            local modKey = savegame.key .. "." .. RmVehicleStorageCapacity.SPEC_NAME
            local xmlFile = savegame.xmlFile

            Log:debug("LOAD_SAVEGAME: Checking for embedded data at key: %s", modKey)

            if not xmlFile:hasProperty(modKey) then
                Log:debug("LOAD_SAVEGAME_NONE: No custom capacity data for %s", vehicleName)
                return
            end

            local entry = {}

            -- Read fill unit capacities
            xmlFile:iterate(modKey .. ".fillUnits.fillUnit", function(_, fuKey)
                local index = xmlFile:getValue(fuKey .. "#index")
                local capacity = xmlFile:getValue(fuKey .. "#capacity")
                if index and capacity then
                    entry[index] = capacity
                    Log:debug("LOAD_SAVEGAME: Read fillUnit %d = %d", index, capacity)
                end
            end)

            if not next(entry) then
                Log:debug("LOAD_SAVEGAME_NONE: No fillUnit data for %s", vehicleName)
                return
            end

            -- Apply capacity NOW
            -- FillUnit:onLoad has already created fillUnits, so we can modify them
            -- This happens BEFORE FillUnit:onPostLoad which loads fill levels
            RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = entry
            spec.loadedFromSavegame = true

            if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
                for fillUnitIndex, capacity in pairs(entry) do
                    local fillUnit = fillUnitSpec.fillUnits[fillUnitIndex]
                    if fillUnit then
                        local oldCapacity = fillUnit.capacity
                        fillUnit.capacity = capacity
                        Log:info("LOAD_SAVEGAME: %s fillUnit[%d] %d -> %d (BEFORE fill levels load)",
                            vehicleName, fillUnitIndex, oldCapacity, capacity)

                        -- Apply proportional discharge speed
                        RmVehicleStorageCapacity.applyProportionalDischargeSpeed(self, fillUnitIndex, capacity)
                    else
                        Log:warning("LOAD_SAVEGAME: %s fillUnit[%d] not found", vehicleName, fillUnitIndex)
                    end
                end
            else
                Log:warning("LOAD_SAVEGAME: %s has no fillUnits to apply capacity to", vehicleName)
            end
        end
    end
end

--- Called after vehicle loads - verify capacities are applied
--- NOTE: FillUnit:onPostLoad loads fill levels BEFORE this runs (specs fire in registration order)
--- We already applied capacity in onLoad, so fill levels should NOT be capped.
function RmVehicleStorageCapacity:onPostLoad(_savegame)
    local fillUnitSpec = self.spec_fillUnit
    local vehicleName = self:getName() or "Unknown"

    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        Log:debug("onPostLoad: %s has no fill units", vehicleName)
        return
    end

    -- Log current state for debugging
    if g_server ~= nil then
        local uniqueId = self.uniqueId
        local entry = RmAdjustStorageCapacity.vehicleCapacities[uniqueId]

        if entry then
            for fillUnitIndex, expectedCapacity in pairs(entry) do
                local fillUnit = fillUnitSpec.fillUnits[fillUnitIndex]
                if fillUnit then
                    Log:debug("onPostLoad: %s fillUnit[%d] capacity=%d fillLevel=%d (expected capacity=%d)",
                        vehicleName, fillUnitIndex, fillUnit.capacity, fillUnit.fillLevel, expectedCapacity)
                end
            end
        end
    end

    Log:debug("onPostLoad: %s - %d fill units verified", vehicleName, #fillUnitSpec.fillUnits)
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

-- ============================================================================
-- Proportional Discharge Speed
-- ============================================================================

--- Apply proportional discharge speed based on capacity multiplier
--- Called after capacity is changed to scale the discharge speed proportionally
---@param fillUnitIndex number The fill unit index that was modified
---@param newCapacity number The new capacity that was set
function RmVehicleStorageCapacity:applyProportionalDischargeSpeed(fillUnitIndex, newCapacity)
    -- Check if auto-scale is enabled
    if not RmAdjustStorageCapacity.autoScaleSpeed then
        return
    end

    local spec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        return
    end

    local dischargeSpec = self.spec_dischargeable
    if dischargeSpec == nil or dischargeSpec.dischargeNodes == nil then
        return
    end

    local vehicleName = self:getName() or "Unknown"

    -- Find discharge nodes that use this fill unit
    for nodeIndex, nodeData in pairs(spec.originalDischargeSpeeds) do
        if nodeData.fillUnitIndex == fillUnitIndex then
            local originalCapacity = spec.originalCapacities[fillUnitIndex]
            if originalCapacity ~= nil and originalCapacity > 0 then
                local multiplier = newCapacity / originalCapacity
                local originalSpeed = nodeData.emptySpeedLitersPerSec
                local newSpeed = originalSpeed * multiplier

                -- Apply to discharge node
                local dischargeNode = dischargeSpec.dischargeNodes[nodeIndex]
                if dischargeNode ~= nil then
                    local oldSpeedMS = dischargeNode.emptySpeed
                    dischargeNode.emptySpeed = newSpeed / 1000  -- Convert l/sec to l/ms
                    Log:debug("Applied discharge speed %.0f -> %.0f l/sec (%.1fx) to %s node %d",
                        oldSpeedMS * 1000, newSpeed, multiplier, vehicleName, nodeIndex)
                end
            end
        end
    end
end

--- Reset discharge speed to original for a specific fill unit
---@param fillUnitIndex number|nil The fill unit index (nil = reset all)
function RmVehicleStorageCapacity:resetDischargeSpeed(fillUnitIndex)
    local spec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil or spec.originalDischargeSpeeds == nil then
        return
    end

    local dischargeSpec = self.spec_dischargeable
    if dischargeSpec == nil or dischargeSpec.dischargeNodes == nil then
        return
    end

    local vehicleName = self:getName() or "Unknown"

    -- Reset discharge nodes
    for nodeIndex, nodeData in pairs(spec.originalDischargeSpeeds) do
        -- Reset if fillUnitIndex matches or if resetting all (nil)
        if fillUnitIndex == nil or nodeData.fillUnitIndex == fillUnitIndex then
            local dischargeNode = dischargeSpec.dischargeNodes[nodeIndex]
            if dischargeNode ~= nil then
                dischargeNode.emptySpeed = nodeData.emptySpeedLitersPerSec / 1000
                Log:debug("Reset discharge speed to %.0f l/sec for %s node %d",
                    nodeData.emptySpeedLitersPerSec, vehicleName, nodeIndex)
            end
        end
    end
end

-- ============================================================================
-- Savegame XML Save Hook
-- NOTE: For vehicles, loading happens in onLoad(savegame), NOT via loadFromXMLFile event
-- saveToXMLFile IS called for vehicles - it's invoked from Vehicle:saveToXMLFile
-- ============================================================================

--- Save custom capacity to vehicle's embedded savegame section
--- Called from Vehicle:saveToXMLFile which passes key = "vehicles.vehicle(N).MODNAME.specName"
---@param xmlFile table XMLFile object (new API with methods)
---@param key string The full key including specialization path
---@param usedModNames table Array to add mod name if we write data
function RmVehicleStorageCapacity:saveToXMLFile(xmlFile, key, usedModNames)
    local uniqueId = self.uniqueId
    if uniqueId == nil then
        return
    end

    local entry = RmAdjustStorageCapacity.vehicleCapacities[uniqueId]
    if entry == nil or next(entry) == nil then
        return  -- No custom capacity for this vehicle
    end

    local vehicleName = self:getName() or "Unknown"

    -- Write fill unit capacities directly under the specialization key
    -- key is already "vehicles.vehicle(N).MODNAME.rmVehicleStorageCapacity"
    local fuIndex = 0
    for fillUnitIndex, capacity in pairs(entry) do
        local fuKey = string.format("%s.fillUnits.fillUnit(%d)", key, fuIndex)
        xmlFile:setValue(fuKey .. "#index", fillUnitIndex)
        xmlFile:setValue(fuKey .. "#capacity", capacity)
        fuIndex = fuIndex + 1
    end

    -- Mark mod as used in this savegame
    table.insert(usedModNames, RmAdjustStorageCapacity.modName)

    Log:info("SAVE_XML: Wrote vehicle capacity to embedded data for %s (%d fillUnits, key=%s)",
        vehicleName, fuIndex, key)
end
