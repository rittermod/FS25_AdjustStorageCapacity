-- AdjustStorageCapacity - Main entry point (loader only)
-- Author: Ritter
--
-- This file is a LOADER ONLY. It loads dependencies and registers the specialization.
-- All mod logic belongs in scripts/RmAdjustStorageCapacity.lua

local modName = g_currentModName
local modDirectory = g_currentModDirectory

-- Load dependencies in order
-- NOTE: Do NOT source the specialization file here - addSpecialization() will load it
source(modDirectory .. "scripts/rmlib/RmLogging.lua")
source(modDirectory .. "scripts/RmAdjustStorageCapacity.lua")
source(modDirectory .. "scripts/events/RmStorageCapacitySyncEvent.lua")
source(modDirectory .. "scripts/gui/RmStorageCapacityDialog.lua")
source(modDirectory .. "scripts/RmMenuIntegration.lua")

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

--- Validate and inject specialization into storage placeable types
local function validateTypes(typeManager)
    if typeManager.typeName == "placeable" then
        local specializationName = RmPlaceableStorageCapacity.SPEC_NAME
        local specializationObject = g_placeableSpecializationManager:getSpecializationObjectByName(specializationName)

        if specializationObject ~= nil then
            local numInserted = 0

            for typeName, typeEntry in pairs(typeManager:getTypes()) do
                if specializationObject.prerequisitesPresent(typeEntry.specializations) then
                    typeManager:addSpecialization(typeName, specializationName)
                    numInserted = numInserted + 1
                    Log:debug("Injected specialization into type: %s", typeName)
                end
            end

            if numInserted > 0 then
                Log:info("Injected specialization into %d placeable types", numInserted)
            end
        else
            Log:warning("Specialization object not found: %s", specializationName)
        end
    end
end

--- Initialize mod - register specialization and hooks
local function init()
    Log:info("Initializing AdjustStorageCapacity mod...")

    -- Register the specialization
    g_placeableSpecializationManager:addSpecialization(
        "storageCapacity",
        "RmPlaceableStorageCapacity",
        modDirectory .. "scripts/placeables/RmPlaceableStorageCapacity.lua",
        nil
    )

    -- Hook to inject specialization into storage types
    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validateTypes)

    Log:info("AdjustStorageCapacity specialization registered")
end

init()
