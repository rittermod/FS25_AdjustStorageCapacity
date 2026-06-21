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

    -- Drop a vehicle whose EVERY fill unit is owned/re-derived by another spec (a pure
    -- baler/baleLoader/consumable/strawblower/leveler): nothing is left for ASC to adjust, so the K prompt,
    -- picker, menu, and console list all skip it. Runs last - after no_fill_units guarantees
    -- #fillUnits > 0 - so a zero-fill-unit vehicle is never labelled "no_adjustable_fill_units".
    local excludedFillUnits = RmVehicleStorageCapacity.getExcludedFillUnitIndices(vehicle)
    local adjustableCount = 0
    for i = 1, #fillUnitSpec.fillUnits do
        if not excludedFillUnits[i] then
            adjustableCount = adjustableCount + 1
        end
    end
    if adjustableCount == 0 then
        return false, "no_adjustable_fill_units"
    end

    return true, nil
end

-- The base-game formed-bale fill-type NAMES (the ROUNDBALE* / SQUAREBALE* family). A fill unit whose
-- EVERY supported fill type is one of these holds a bale COUNT, never liters. Names are stable; the
-- indices they resolve to are session-assigned at map load, so resolve lazily (never at file-source
-- time). Re-sweep this list if a DLC introduces a new formed-bale fill type.
RmVehicleStorageCapacity.FORMED_BALE_FILL_TYPE_NAMES = {
    "ROUNDBALE", "ROUNDBALE_GRASS", "ROUNDBALE_DRYGRASS", "ROUNDBALE_COTTON", "ROUNDBALE_WOOD",
    "SQUAREBALE", "SQUAREBALE_GRASS", "SQUAREBALE_DRYGRASS", "SQUAREBALE_COTTON", "SQUAREBALE_WOOD",
}

--- Resolve the formed-bale fill-type NAMES to a set of fill-type indices, ONCE g_fillTypeManager is
--- ready, and cache it then (indices are stable per session). If the manager is absent, return an
--- UN-cached {} so the rule is inert this call but re-checks readiness next time - memoizing the empty
--- set would freeze the rule off for the whole session (an early call from support detection would
--- leak the carriers forever). Logs once if zero names resolve (a modded/renamed-fill-type context).
---@return table set A set { [fillTypeIndex] = true } of formed-bale fill-type indices (possibly empty, uncached)
function RmVehicleStorageCapacity.getFormedBaleFillTypeSet()
    if RmVehicleStorageCapacity._formedBaleFillTypeSet ~= nil then
        return RmVehicleStorageCapacity._formedBaleFillTypeSet
    end
    if g_fillTypeManager == nil then
        return {}  -- inert this call; do NOT memoize, so readiness is re-checked next time
    end
    local set = {}
    for _, name in ipairs(RmVehicleStorageCapacity.FORMED_BALE_FILL_TYPE_NAMES) do
        local idx = g_fillTypeManager:getFillTypeIndexByName(name)
        if idx ~= nil then
            set[idx] = true
        end
    end
    if next(set) == nil then
        -- Manager present but nothing resolved (renamed/removed fill types, or called before fill types
        -- are registered): return the empty set UN-cached, exactly like the manager-absent path, so the
        -- rule is inert this call but re-checks next time. Memoizing it here would freeze the rule off
        -- for the whole session - the same trap the "never memoize an empty set" Boundary guards against.
        Log:warning("getFormedBaleFillTypeSet: no formed-bale fill types resolved - carrier exclusion inert this call")
        return set
    end
    RmVehicleStorageCapacity._formedBaleFillTypeSet = set
    return set
end

--- Build the set of fill-unit indices that ASC must NOT adjust because a base specialization
--- OWNS or RE-DERIVES their capacity, or because the unit holds a discrete count rather than liters.
--- Excluded families:
---   - leveler buffers (main + per node);
---   - the baler bale chamber (+ the overload buffer only when the game re-derives it from
---     capacityPercentage);
---   - bale-loader platform units (capacity is a bale COUNT, not liters);
---   - consumable slot-count units;
---   - the strawblower blow buffer;
---   - tree-planter sapling magazines (a sapling COUNT, re-derived from the mounted pallet);
---   - feller-buncher tree-grab units (a tree COUNT via getNumLoadedTrees; fillUnitIndex has no XML default);
---   - any fill unit whose EVERY supported fill type is a FORMED-BALE type (ROUNDBALE* / SQUAREBALE*) -
---     a bale COUNT; the only signal that reaches dynamic-mount carriers (kroeger/pwo24, farmtech/dpw1800)
---     whose bale unit no spec owns.
--- Baler ADDITIVES and a fixed-capacity baler buffer (no capacityPercentage) are NOT excluded - they are
--- genuine adjustable storage. This is the single SSOT consulted at the offer list, support detection,
--- and the apply/persist chokepoints. Every spec table and field is nil-guarded; an index claimed by two
--- rules is idempotent (set semantics - any excluding rule wins).
---@param vehicle table The vehicle to classify
---@return table excluded A set { [fillUnitIndex] = true } of indices ASC must leave alone
function RmVehicleStorageCapacity.getExcludedFillUnitIndices(vehicle)
    local excluded = {}
    if vehicle == nil then
        return excluded
    end

    -- Leveler: the main fill unit plus each node's fill unit - internal buffers for pushing /
    -- leveling material in bunker silos.
    local levelerSpec = vehicle.spec_leveler
    if levelerSpec ~= nil then
        if levelerSpec.fillUnitIndex ~= nil then
            excluded[levelerSpec.fillUnitIndex] = true
        end
        if levelerSpec.nodes ~= nil then
            for _, node in pairs(levelerSpec.nodes) do
                if node.fillUnitIndex ~= nil then
                    excluded[node.fillUnitIndex] = true
                end
            end
        end
    end

    -- Baler: the bale chamber (the game always re-derives it from the bale being formed) and the
    -- overload buffer ONLY when the game re-derives it. Per the buffer's XML schema, a buffer with
    -- capacityPercentage set is re-sized to that share of the bale capacity; with none it keeps its
    -- fixed XML capacity (a stationary material bunker, e.g. VARIO-Master V140 [2] = 20000 L) and
    -- stays genuine adjustable storage. NOT the additives tank, which stays adjustable.
    local balerSpec = vehicle.spec_baler
    if balerSpec ~= nil then
        if balerSpec.fillUnitIndex ~= nil then
            excluded[balerSpec.fillUnitIndex] = true
        end
        if balerSpec.buffer ~= nil and balerSpec.buffer.fillUnitIndex ~= nil
            and balerSpec.buffer.capacityPercentage ~= nil then
            excluded[balerSpec.buffer.fillUnitIndex] = true
        end
    end

    -- BaleLoader: the platform fill unit holds formed bales (capacity is a bale COUNT, not liters);
    -- the loader OWNS it (only reads capacity, never re-derives) and drives visual bale slots that must
    -- match the count. Each per-bale-type unit may target its own fill unit. Applies to self-loading
    -- balers AND dedicated bale-autoload trailers.
    local baleLoaderSpec = vehicle.spec_baleLoader
    if baleLoaderSpec ~= nil then
        if baleLoaderSpec.fillUnitIndex ~= nil then
            excluded[baleLoaderSpec.fillUnitIndex] = true
        end
        if baleLoaderSpec.baleTypes ~= nil then
            for _, baleType in pairs(baleLoaderSpec.baleTypes) do
                if baleType.fillUnitIndex ~= nil then
                    excluded[baleType.fillUnitIndex] = true
                end
            end
        end
    end

    -- Consumable: each type's fill unit holds a slot count, not a liter capacity - meaningless to
    -- edit. The per-type fillUnitIndex may be nil; guard it.
    local consumableSpec = vehicle.spec_consumable
    if consumableSpec ~= nil and consumableSpec.types ~= nil then
        for _, consumableType in pairs(consumableSpec.types) do
            if consumableType.fillUnitIndex ~= nil then
                excluded[consumableType.fillUnitIndex] = true
            end
        end
    end

    -- StrawBlower: the single fill unit is re-derived to the bale currently being blown.
    local strawBlowerSpec = vehicle.spec_strawBlower
    if strawBlowerSpec ~= nil and strawBlowerSpec.fillUnitIndex ~= nil then
        excluded[strawBlowerSpec.fillUnitIndex] = true
    end

    -- TreePlanter: the sapling magazine (default fillUnitIndex 1) holds a sapling COUNT - re-derived
    -- from the mounted sapling pallet, or 0 -> unbounded when empty. Meaningless to edit, same class as
    -- a consumable slot count. @see TreePlanter.spec_treePlanter.fillUnitIndex
    local treePlanterSpec = vehicle.spec_treePlanter
    if treePlanterSpec ~= nil and treePlanterSpec.fillUnitIndex ~= nil then
        excluded[treePlanterSpec.fillUnitIndex] = true
    end

    -- FellerBuncher: the tree-grab unit's capacity is the max trees the head holds (a count via
    -- FellerBuncher:getNumLoadedTrees), not liters. fillUnitIndex has NO XML default - nil-guard it.
    -- Diesel/DEF on the same machine stay adjustable.
    local fellerBuncherSpec = vehicle.spec_fellerBuncher
    if fellerBuncherSpec ~= nil and fellerBuncherSpec.fillUnitIndex ~= nil then
        excluded[fellerBuncherSpec.fillUnitIndex] = true
    end

    -- Unowned formed-bale carriers: a fill unit whose EVERY supported fill type is a formed bale is a
    -- bale COUNT (capacity = 1..N bales, never liters). On dynamic-mount carriers (kroeger/pwo24,
    -- farmtech/dpw1800) NO spec owns the index, so the spec_baleLoader branch above never reaches it -
    -- this fill-type rule is the only one that does. ALL (not any) supported types must be formed bales,
    -- so a mixed liter+bale unit stays adjustable. Idempotent with the bale spec branches above. The
    -- ipairs position i IS the fill-unit index (dense 1-based array, same as getAllFillUnitInfo's loop).
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
        local formedBales = RmVehicleStorageCapacity.getFormedBaleFillTypeSet()
        if next(formedBales) ~= nil then
            for i, fillUnit in ipairs(fillUnitSpec.fillUnits) do
                local supported = fillUnit.supportedFillTypes
                if supported ~= nil and next(supported) ~= nil then
                    local allFormedBales = true
                    for fillTypeIndex in pairs(supported) do
                        if not formedBales[fillTypeIndex] then
                            allFormedBales = false
                            break
                        end
                    end
                    if allFormedBales then
                        excluded[i] = true
                    end
                end
            end
        end
    end

    return excluded
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

--- Register overwritten functions for this specialization
--- This is the correct way to override cross-specialization functions in FS25.
--- Utils.overwrittenFunction on the class table does NOT work because the specialization
--- system has already built the function chain per vehicle type by initSpecialization time.
function RmVehicleStorageCapacity.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getAdditionalComponentMass", RmVehicleStorageCapacity.getAdditionalComponentMassOverride)
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
                    -- Defensive [0, MAX] clamp: heal a pre-fix / hand-edited save (over-max or wrapped-negative).
                    capacity = math.max(0, (RmAdjustStorageCapacity.clampToMax(capacity)))
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

            -- Excluded indices are owned/re-derived by a base spec; skip applying (and saveToXMLFile
            -- skips persisting) so a pre-fix / stale override on a now-excluded unit self-cleans on
            -- the next save instead of being re-asserted. self IS the vehicle in this onLoad method.
            local excludedFillUnits = RmVehicleStorageCapacity.getExcludedFillUnitIndices(self)
            if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
                for fillUnitIndex, capacity in pairs(entry) do
                    if excludedFillUnits[fillUnitIndex] then
                        Log:debug("LOAD_SAVEGAME: %s fillUnit[%d] excluded (owned by base spec) - skip apply",
                            vehicleName, fillUnitIndex)
                    else
                        local fillUnit = fillUnitSpec.fillUnits[fillUnitIndex]
                        if fillUnit then
                            local oldCapacity = fillUnit.capacity
                            fillUnit.capacity = capacity
                            -- Retarget the reset baseline: a loader/shovel bucket snaps its
                            -- capacity back to its stored default after a scoop; moving the default too
                            -- makes that snap land on ASC's value. Harmless for units with no such reset.
                            fillUnit.defaultCapacity = capacity
                            Log:info("LOAD_SAVEGAME: %s fillUnit[%d] %d -> %d (BEFORE fill levels load)",
                                vehicleName, fillUnitIndex, oldCapacity, capacity)

                            -- Apply proportional discharge speed
                            RmVehicleStorageCapacity.applyProportionalDischargeSpeed(self, fillUnitIndex, capacity)

                            -- Update FillVolume capacity and recreate 3D fill plane mesh
                            -- FillVolume:onLoad already ran with original capacity, so fillVolume.capacity
                            -- and the mesh are stale. Recreate now so fill levels loaded in onPostLoad
                            -- render with correct proportions. Fill is 0 at this point (loaded later).
                            RmAdjustStorageCapacity:updateVehicleFillVolumeCapacity(self, fillUnitIndex, capacity)
                        else
                            Log:warning("LOAD_SAVEGAME: %s fillUnit[%d] not found", vehicleName, fillUnitIndex)
                        end
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

    if g_server ~= nil then
        -- Load-time excess-fill heal: fill levels are already loaded by the time this runs, so
        -- clamp any fill that loaded ABOVE the (already onLoad-bounded) fill-unit capacity DOWN to
        -- capacity. Loaded fill is already within cap for healthy entities EXCEPT a cap-0 unit: a
        -- fill unit with capacity 0 is treated as unbounded and loads its stored fill without
        -- clamping, so it can finish loading overfilled (corrupt capacity healed to 0, or a user-set
        -- 0 then filled while it was treated as unbounded). The heal empties that unit so the vehicle
        -- dialog lower bound is no longer stuck above 0. No-op for healthy (cap>0) units.
        local rmSpec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
        if rmSpec ~= nil and rmSpec.loadedFromSavegame then
            -- Contain a heal throw so it cannot abort the rest of onPostLoad / the load chain
            -- (symmetric with the placeable hook's per-storage pcall).
            local healOk, healErr = pcall(function()
                RmAdjustStorageCapacity:clampExcessVehicleFill(self)
            end)
            if not healOk then
                Log:error("onPostLoad: Failed to heal excess fill for %s: %s",
                    vehicleName, tostring(healErr))
            end
        end

        -- Log current state for debugging
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

    -- Exclude indices owned/re-derived by a base spec from the MP sync entirely: an excluded
    -- override (e.g. a stale pre-fix one still in the map) must never reach a joining client,
    -- where it would be stored and its carried fill replayed onto the owning spec's unit. Filter
    -- at this write source so onReadStream receives only genuine units - the same apply/persist
    -- chokepoint discipline, extended to the MP write path. self IS the vehicle here.
    local excludedFillUnits = RmVehicleStorageCapacity.getExcludedFillUnitIndices(self)

    -- Count only the NON-excluded custom capacities so the bool reflects whether anything real
    -- ships and onReadStream reads exactly as many entries as are written (cursor stays aligned).
    local count = 0
    if customCaps ~= nil then
        for fillUnitIndex in pairs(customCaps) do
            if not excludedFillUnits[fillUnitIndex] then
                count = count + 1
            end
        end
    end

    -- Write whether we have (non-excluded) custom capacities
    if streamWriteBool(streamId, count > 0) then
        streamWriteInt32(streamId, count)

        -- Write each fill unit's custom capacity PLUS the server's TRUE fill level, so a
        -- joining client can re-establish it AFTER ASC raises the capacity. Base
        -- FillUnit:onReadStream deserializes + clamps fill to the ORIGINAL capacity before
        -- ASC's spec runs, discarding everything above it; carrying the truth here lets the
        -- client top the unit back up once the capacity is raised. One float per written
        -- entry; value is fu.fillLevel for an existing synchronized unit, else 0 (a 0 is
        -- never re-applied on read, so it cannot erase a real client fill).
        local fillUnits = self.spec_fillUnit and self.spec_fillUnit.fillUnits
        for fillUnitIndex, capacity in pairs(customCaps) do
            if not excludedFillUnits[fillUnitIndex] then
                streamWriteInt32(streamId, fillUnitIndex)
                streamWriteInt32(streamId, capacity)
                local fillLevel = 0
                local fu = fillUnits and fillUnits[fillUnitIndex]
                if fu ~= nil and fu.synchronizeFillLevel then
                    fillLevel = fu.fillLevel or 0
                end
                streamWriteFloat32(streamId, fillLevel)
            end
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
        local fills = {} -- transient carried fills keyed by fillUnitIndex; never persisted
        local count = streamReadInt32(streamId)

        -- Read each fill unit's custom capacity AND the carried server fill level. Decode is
        -- UNCONDITIONAL (before the uniqueId gate) so the cursor stays aligned for every later
        -- object even when uniqueId is nil; only the re-apply below is gated.
        for _ = 1, count do
            local fillUnitIndex = streamReadInt32(streamId)
            local capacity = streamReadInt32(streamId)
            local fillLevel = streamReadFloat32(streamId)
            -- Defensive [0, MAX] clamp: a pre-fix server could send a wrapped-negative capacity.
            entry[fillUnitIndex] = math.max(0, (RmAdjustStorageCapacity.clampToMax(capacity)))
            fills[fillUnitIndex] = fillLevel
        end

        if uniqueId ~= nil then
            RmAdjustStorageCapacity.vehicleCapacities[uniqueId] = entry

            -- Apply the custom capacities (raises capacity)
            RmAdjustStorageCapacity:applyVehicleCapacities(self)

            -- Re-establish the server's TRUE fill on each raised unit, AFTER the capacity raise.
            -- Base FillUnit:onReadStream already deserialized + clamped fill to the ORIGINAL
            -- capacity; the delta tops the unit up via the engine's own path, which runs full
            -- client bookkeeping (mass, listeners, fill plane), clamps to the raised capacity,
            -- and does NOT re-broadcast on a client (the dirty-flag raise is isServer-gated).
            -- Skip phantom (no client unit), zero, and non-synchronized units (base did not
            -- sync those, so their fillType/fillLevel are not authoritative here).
            local fillUnits = self.spec_fillUnit and self.spec_fillUnit.fillUnits
            for fillUnitIndex, fillLevel in pairs(fills) do
                local fu = fillUnits and fillUnits[fillUnitIndex]
                if fu ~= nil and fillLevel > 0 and fu.synchronizeFillLevel then
                    local delta = fillLevel - fu.fillLevel
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), fillUnitIndex, delta,
                        fu.fillType, ToolType.UNDEFINED, nil)
                    Log:debug("ReadStream: Re-applied carried fill %.0f to %s fillUnit[%d] (delta %.0f)",
                        fillLevel, self:getName(), fillUnitIndex, delta)
                end
            end

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

    -- Build the set of fill units ASC must not offer (leveler / baler chamber + re-derived buffer /
    -- bale-loader platform / consumable slots / strawblower) via the shared SSOT. self IS the vehicle
    -- here (called dot-style with an explicit vehicle, e.g. from RmVehiclePickerDialog).
    local excludedFillUnits = RmVehicleStorageCapacity.getExcludedFillUnitIndices(self)

    for i, fillUnit in ipairs(fillUnitSpec.fillUnits) do
        -- Skip excluded fill units - internal buffers / re-derived units another spec owns;
        -- adjusting their capacity would be fought by the owning spec or is meaningless.
        if excludedFillUnits[i] then
            Log:trace("Skipping excluded fill unit %d (capacity=%d L)", i, fillUnit.capacity)
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
-- Proportional Mass Scaling
-- ============================================================================

--- Override for FillUnit.getAdditionalComponentMass
--- Applies proportional mass scaling for vehicles with expanded capacity.
--- Uses delta calculation to preserve other specialization chains.
---@param superFunc function Original function
---@param component table Vehicle component
---@return number additionalMass Adjusted additional mass
function RmVehicleStorageCapacity:getAdditionalComponentMassOverride(superFunc, component)
    local originalResult = superFunc(self, component)

    if not RmAdjustStorageCapacity.autoScaleMass then
        return originalResult
    end

    local rmSpec = self[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if rmSpec == nil or rmSpec.originalCapacities == nil then
        return originalResult
    end

    local spec = self.spec_fillUnit
    if spec == nil or spec.fillUnits == nil then
        return originalResult
    end

    local massAdjustment = 0

    for i, fillUnit in ipairs(spec.fillUnits) do
        if fillUnit.updateMass and fillUnit.fillMassNode == component.node
           and fillUnit.fillType ~= nil and fillUnit.fillType ~= FillType.UNKNOWN then
            local origCap = rmSpec.originalCapacities[i]

            -- Only scale when capacity was EXPANDED (not reduced)
            if origCap ~= nil and fillUnit.capacity > origCap then
                local desc = g_fillTypeManager:getFillTypeByIndex(fillUnit.fillType)
                if desc ~= nil then
                    local originalMass = fillUnit.fillLevel * desc.massPerLiter
                    local massMultiplier = origCap / fillUnit.capacity
                    local scaledMass = fillUnit.fillLevel * desc.massPerLiter * massMultiplier
                    massAdjustment = massAdjustment + (scaledMass - originalMass)
                end
            end
        end
    end

    return originalResult + massAdjustment
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

    -- Skip excluded indices so a stale override on a now-excluded unit is not re-persisted (it
    -- self-cleans on this save). self IS the vehicle in this saveToXMLFile method.
    local excludedFillUnits = RmVehicleStorageCapacity.getExcludedFillUnitIndices(self)

    -- Write fill unit capacities directly under the specialization key
    -- key is already "vehicles.vehicle(N).MODNAME.rmVehicleStorageCapacity"
    local fuIndex = 0
    for fillUnitIndex, capacity in pairs(entry) do
        if not excludedFillUnits[fillUnitIndex] then
            local fuKey = string.format("%s.fillUnits.fillUnit(%d)", key, fuIndex)
            xmlFile:setValue(fuKey .. "#index", fillUnitIndex)
            xmlFile:setValue(fuKey .. "#capacity", capacity)
            fuIndex = fuIndex + 1
        end
    end

    -- Mark mod as used in this savegame only if we actually wrote a fill unit (an all-excluded
    -- entry writes nothing and must not claim the savegame slot).
    if fuIndex > 0 then
        table.insert(usedModNames, RmAdjustStorageCapacity.modName)
    end

    Log:info("SAVE_XML: Wrote vehicle capacity to embedded data for %s (%d fillUnits, key=%s)",
        vehicleName, fuIndex, key)
end
