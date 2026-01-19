-- AdjustStorageCapacity - Main entry point (loader only)
-- Author: Ritter
--
-- This file is a LOADER ONLY. It loads dependencies and registers the specialization.
-- All mod logic belongs in scripts/RmAdjustStorageCapacity.lua

local modName = g_currentModName
local modDirectory = g_currentModDirectory

-- Load dependencies in order
-- NOTE: Specialization files are sourced by addSpecialization() - don't source them manually
source(modDirectory .. "scripts/rmlib/RmLogging.lua")
source(modDirectory .. "scripts/RmAdjustStorageCapacity.lua")
source(modDirectory .. "scripts/events/RmStorageCapacitySyncEvent.lua")
source(modDirectory .. "scripts/events/RmVehicleCapacitySyncEvent.lua")
source(modDirectory .. "scripts/gui/RmStorageCapacityDialog.lua")
source(modDirectory .. "scripts/gui/RmVehicleCapacityDialog.lua")
source(modDirectory .. "scripts/RmMenuIntegration.lua")
source(modDirectory .. "scripts/vehicles/RmVehicleCapacityActivatable.lua")
source(modDirectory .. "scripts/vehicles/RmVehicleDetectionHandler.lua")
source(modDirectory .. "scripts/placeables/RmPlaceableCapacityActivatable.lua")

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

--- Validate and inject specialization into storage placeable types
local function validatePlaceableTypes(typeManager)
    if typeManager.typeName == "placeable" then
        local specializationName = RmPlaceableStorageCapacity.SPEC_NAME
        local specializationObject = g_placeableSpecializationManager:getSpecializationObjectByName(specializationName)

        if specializationObject ~= nil then
            local numInserted = 0

            for typeName, typeEntry in pairs(typeManager:getTypes()) do
                if specializationObject.prerequisitesPresent(typeEntry.specializations) then
                    typeManager:addSpecialization(typeName, specializationName)
                    numInserted = numInserted + 1
                    Log:debug("Injected placeable specialization into type: %s", typeName)
                end
            end

            if numInserted > 0 then
                Log:info("Injected placeable specialization into %d types", numInserted)
            end
        else
            Log:warning("Placeable specialization object not found: %s", specializationName)
        end
    end
end

--- Validate and inject vehicle specialization into FillUnit vehicle types
--- Uses pattern from FS25_BulkFill: g_specializationManager at init, g_vehicleTypeManager at validate
local function validateVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local specializationName = modName .. ".rmVehicleStorageCapacity"
    local numInserted = 0

    -- Inject specialization into all vehicle types that have FillUnit
    for vehicleName, vehicleType in pairs(g_vehicleTypeManager.types) do
        if SpecializationUtil.hasSpecialization(FillUnit, vehicleType.specializations) then
            g_vehicleTypeManager:addSpecialization(vehicleName, specializationName)
            numInserted = numInserted + 1
            Log:debug("Injected vehicle specialization into type: %s", vehicleName)
        end
    end

    if numInserted > 0 then
        Log:info("Injected vehicle specialization into %d vehicle types", numInserted)
    end
end

--- Initialize mod - register specializations and hooks
local function init()
    Log:info("Initializing AdjustStorageCapacity mod...")

    -- Register the placeable specialization
    g_placeableSpecializationManager:addSpecialization(
        "storageCapacity",
        "RmPlaceableStorageCapacity",
        modDirectory .. "scripts/placeables/RmPlaceableStorageCapacity.lua",
        nil
    )
    Log:info("Placeable specialization registered")

    -- Register the vehicle specialization using g_specializationManager (available at init time)
    -- This is the correct FS25 pattern per BulkFill mod
    -- NOTE: Savegame schema registration is done in RmVehicleStorageCapacity.initSpecialization()
    -- which is automatically called by SpecializationManager:initSpecializations()
    g_specializationManager:addSpecialization(
        "rmVehicleStorageCapacity",
        "RmVehicleStorageCapacity",
        Utils.getFilename("scripts/vehicles/RmVehicleStorageCapacity.lua", modDirectory),
        nil
    )
    Log:info("Vehicle specialization registered")

    -- Hook to inject specializations into appropriate types
    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validatePlaceableTypes)
    TypeManager.validateTypes = Utils.appendedFunction(TypeManager.validateTypes, validateVehicleTypes)
end

init()
