-- RmAscSettings - Game settings integration for AdjustStorageCapacity
-- Author: Ritter
--
-- Adds a toggle to the Game Settings page to show/hide the shortcut at triggers.
-- Follows the EAS/RL pattern: clone BinaryOption from gameSettingsLayout.

local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmAscSettings = {}

-- Runtime state (1 = OFF, 2 = ON; BinaryOption convention)
RmAscSettings.showTriggerShortcutState = 2  -- default: enabled
RmAscSettings.autoScaleMassState = 2  -- default: enabled
RmAscSettings.autoScaleSpeedState = 2  -- default: enabled

-- GUI element reference
RmAscSettings.uiInitialized = false

-- ============================================================================
-- Public API
-- ============================================================================

--- Check if trigger shortcuts are enabled
---@return boolean
function RmAscSettings.isShortcutEnabled()
    return RmAscSettings.showTriggerShortcutState == 2
end

-- ============================================================================
-- GUI Initialization
-- ============================================================================

--- Initialize GUI elements by cloning from existing game settings
-- Called at source time (g_inGameMenu is available)
function RmAscSettings.initGui()
    local settingsPage = g_inGameMenu.pageSettings
    if settingsPage == nil then
        Log:warning("RmAscSettings: g_inGameMenu.pageSettings not available")
        return
    end

    local scrollPanel = settingsPage.gameSettingsLayout
    if scrollPanel == nil then
        Log:warning("RmAscSettings: gameSettingsLayout not available")
        return
    end

    -- Find templates: section header and BinaryOption container
    local sectionHeaderTemplate = nil
    local binaryOptionTemplate = nil

    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeaderTemplate == nil then
            sectionHeaderTemplate = element
        end
        if element.typeName == "Bitmap" and binaryOptionTemplate == nil then
            if element.elements[1] ~= nil and element.elements[1].typeName == "BinaryOption" then
                binaryOptionTemplate = element
            end
        end
        if sectionHeaderTemplate ~= nil and binaryOptionTemplate ~= nil then
            break
        end
    end

    if sectionHeaderTemplate == nil or binaryOptionTemplate == nil then
        Log:warning("RmAscSettings: Could not find UI templates in gameSettingsLayout")
        return
    end

    -- Clone section header
    local header = sectionHeaderTemplate:clone(scrollPanel)
    header:setText(g_i18n:getText("rm_asc_settings_section"))

    -- Clone BinaryOption for trigger shortcut toggle
    local container = binaryOptionTemplate:clone(scrollPanel)
    container.id = nil  -- clear cloned ID to avoid conflicts

    local binaryOption = container.elements[1]
    local titleText = container.elements[2]

    titleText:setText(g_i18n:getText("rm_asc_settings_showTriggerShortcut"))
    binaryOption.elements[1]:setText(g_i18n:getText("rm_asc_settings_showTriggerShortcut_tooltip"))
    binaryOption.id = "rmAscShowTriggerShortcut"
    binaryOption.onClickCallback = RmAscSettings.onToggleChanged

    -- Store reference for state updates
    settingsPage.rmAscShowTriggerShortcut = binaryOption

    container:setVisible(true)
    container:setDisabled(false)

    -- Clone BinaryOption for auto-scale mass toggle
    local massContainer = binaryOptionTemplate:clone(scrollPanel)
    massContainer.id = nil

    local massBinaryOption = massContainer.elements[1]
    local massTitleText = massContainer.elements[2]

    massTitleText:setText(g_i18n:getText("rm_asc_settings_autoScaleMass"))
    massBinaryOption.elements[1]:setText(g_i18n:getText("rm_asc_settings_autoScaleMass_tooltip"))
    massBinaryOption.id = "rmAscAutoScaleMass"
    massBinaryOption.onClickCallback = RmAscSettings.onAutoScaleMassChanged

    settingsPage.rmAscAutoScaleMass = massBinaryOption

    massContainer:setVisible(true)
    massContainer:setDisabled(false)

    -- Clone BinaryOption for auto-scale speed toggle
    local speedContainer = binaryOptionTemplate:clone(scrollPanel)
    speedContainer.id = nil

    local speedBinaryOption = speedContainer.elements[1]
    local speedTitleText = speedContainer.elements[2]

    speedTitleText:setText(g_i18n:getText("rm_asc_settings_autoScaleSpeed"))
    speedBinaryOption.elements[1]:setText(g_i18n:getText("rm_asc_settings_autoScaleSpeed_tooltip"))
    speedBinaryOption.id = "rmAscAutoScaleSpeed"
    speedBinaryOption.onClickCallback = RmAscSettings.onAutoScaleSpeedChanged

    settingsPage.rmAscAutoScaleSpeed = speedBinaryOption

    speedContainer:setVisible(true)
    speedContainer:setDisabled(false)

    scrollPanel:invalidateLayout()

    RmAscSettings.uiInitialized = true
    Log:debug("RmAscSettings: GUI initialized")
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

--- Set up all lifecycle hooks
function RmAscSettings.setupHooks()
    -- Load settings from savegame XML after items are loaded
    Mission00.loadItemsFinished = Utils.appendedFunction(
        Mission00.loadItemsFinished,
        RmAscSettings.loadFromXMLFile
    )

    -- Save settings to savegame XML
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        RmAscSettings.saveToXMLFile
    )

    -- Sync settings to joining clients
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        RmAscSettings.sendInitialClientState
    )

    -- Update UI state when settings frame opens
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings,
        RmAscSettings.updateGameSettings
    )

    Log:debug("RmAscSettings: Lifecycle hooks registered")
end

-- ============================================================================
-- Settings Change Handling
-- ============================================================================

--- Called when BinaryOption is clicked
---@param _ table element (unused)
---@param state number New state (1 = OFF, 2 = ON)
function RmAscSettings.onToggleChanged(_, state)
    RmAscSettings.updateShowTriggerShortcut(state)
end

--- Update setting state and sync
---@param state number New state (1 = OFF, 2 = ON)
---@param noEventSend boolean|nil If true, skip network event (used during sync)
function RmAscSettings.updateShowTriggerShortcut(state, noEventSend)
    if state ~= RmAscSettings.showTriggerShortcutState then
        RmAscSettings.showTriggerShortcutState = state
        local enabled = (state == 2)
        Log:info("RmAscSettings: Trigger shortcut %s", enabled and "enabled" or "disabled")

        RmSettingsSyncEvent.sendEvent(noEventSend)
    end
end

--- Called when auto-scale mass BinaryOption is clicked
---@param _ table element (unused)
---@param state number New state (1 = OFF, 2 = ON)
function RmAscSettings.onAutoScaleMassChanged(_, state)
    RmAscSettings.updateAutoScaleMass(state)
end

--- Update auto-scale mass setting and sync
---@param state number New state (1 = OFF, 2 = ON)
---@param noEventSend boolean|nil If true, skip network event (used during sync)
function RmAscSettings.updateAutoScaleMass(state, noEventSend)
    if state ~= RmAscSettings.autoScaleMassState then
        RmAscSettings.autoScaleMassState = state
        RmAdjustStorageCapacity.autoScaleMass = (state == 2)
        local enabled = (state == 2)
        Log:info("RmAscSettings: Auto-scale mass %s", enabled and "enabled" or "disabled")

        -- Dirty mass on all vehicles so updateMass() recalculates with new setting
        RmAscSettings.dirtyAllVehicleMass()

        RmSettingsSyncEvent.sendEvent(noEventSend)
    end
end

--- Force mass recalculation on all vehicles with expanded capacities
function RmAscSettings.dirtyAllVehicleMass()
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return
    end

    local count = 0
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle.setMassDirty ~= nil and vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME] ~= nil then
            vehicle:setMassDirty()
            count = count + 1
        end
    end

    if count > 0 then
        Log:debug("RmAscSettings: Dirtied mass on %d vehicles", count)
    end
end

--- Called when auto-scale speed BinaryOption is clicked
---@param _ table element (unused)
---@param state number New state (1 = OFF, 2 = ON)
function RmAscSettings.onAutoScaleSpeedChanged(_, state)
    RmAscSettings.updateAutoScaleSpeed(state)
end

--- Update auto-scale speed setting and sync
---@param state number New state (1 = OFF, 2 = ON)
---@param noEventSend boolean|nil If true, skip network event (used during sync)
function RmAscSettings.updateAutoScaleSpeed(state, noEventSend)
    if state ~= RmAscSettings.autoScaleSpeedState then
        RmAscSettings.autoScaleSpeedState = state
        RmAdjustStorageCapacity.autoScaleSpeed = (state == 2)
        local enabled = (state == 2)
        Log:info("RmAscSettings: Auto-scale speed %s", enabled and "enabled" or "disabled")

        RmAscSettings.reapplyAllSpeeds()

        RmSettingsSyncEvent.sendEvent(noEventSend)
    end
end

--- Re-apply or reset all load/discharge speeds based on current autoScaleSpeed setting
function RmAscSettings.reapplyAllSpeeds()
    local enabled = RmAdjustStorageCapacity.autoScaleSpeed
    local placeableCount = 0
    local vehicleCount = 0

    -- Handle placeables (load speed)
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
            local uniqueId = placeable.uniqueId
            if uniqueId ~= nil and RmAdjustStorageCapacity.customCapacities[uniqueId] ~= nil then
                if enabled then
                    local customCapacity = RmAdjustStorageCapacity.customCapacities[uniqueId]
                    local multiplier = RmAdjustStorageCapacity:getMaxCapacityMultiplier(placeable, customCapacity)
                    if multiplier ~= 1.0 then
                        RmAdjustStorageCapacity:applyProportionalLoadSpeed(placeable, multiplier)
                    end
                else
                    RmAdjustStorageCapacity:resetLoadSpeed(placeable)
                end
                placeableCount = placeableCount + 1
            end
        end
    end

    -- Handle vehicles (discharge speed)
    if g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil then
        for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles or {}) do
            local spec = vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
            if spec ~= nil then
                local uniqueId = vehicle.uniqueId
                if uniqueId ~= nil and RmAdjustStorageCapacity.vehicleCapacities[uniqueId] ~= nil then
                    if enabled then
                        for fillUnitIndex, capacity in pairs(RmAdjustStorageCapacity.vehicleCapacities[uniqueId]) do
                            RmVehicleStorageCapacity.applyProportionalDischargeSpeed(vehicle, fillUnitIndex, capacity)
                        end
                    else
                        RmVehicleStorageCapacity.resetDischargeSpeed(vehicle, nil)
                    end
                    vehicleCount = vehicleCount + 1
                end
            end
        end
    end

    if placeableCount > 0 or vehicleCount > 0 then
        Log:debug("RmAscSettings: Reapplied speeds on %d placeables, %d vehicles (enabled=%s)",
            placeableCount, vehicleCount, tostring(enabled))
    end
end

-- ============================================================================
-- UI State Update
-- ============================================================================

--- Called via updateGameSettings hook when settings frame opens
---@param settingsPage table InGameMenuSettingsFrame instance
function RmAscSettings.updateGameSettings(settingsPage)
    local element = settingsPage.rmAscShowTriggerShortcut
    if element ~= nil then
        element:setState(RmAscSettings.showTriggerShortcutState)
    end

    local massElement = settingsPage.rmAscAutoScaleMass
    if massElement ~= nil then
        massElement:setState(RmAscSettings.autoScaleMassState)
    end

    local speedElement = settingsPage.rmAscAutoScaleSpeed
    if speedElement ~= nil then
        speedElement:setState(RmAscSettings.autoScaleSpeedState)
    end
end

-- ============================================================================
-- Save/Load
-- ============================================================================

--- Load settings from savegame XML (server only)
function RmAscSettings.loadFromXMLFile()
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        return
    end

    local filePath = savegameDir .. "/rm_AscSettings.xml"
    local xmlFile = XMLFile.loadIfExists("rm_AscSettings", filePath, "rmAscSettings")

    if xmlFile ~= nil then
        local shortcutEnabled = xmlFile:getBool("rmAscSettings#showTriggerShortcut", true)
        RmAscSettings.showTriggerShortcutState = shortcutEnabled and 2 or 1

        local autoScaleMass = xmlFile:getBool("rmAscSettings#autoScaleMass", true)
        RmAscSettings.autoScaleMassState = autoScaleMass and 2 or 1
        RmAdjustStorageCapacity.autoScaleMass = autoScaleMass

        local autoScaleSpeed = xmlFile:getBool("rmAscSettings#autoScaleSpeed", true)
        RmAscSettings.autoScaleSpeedState = autoScaleSpeed and 2 or 1
        RmAdjustStorageCapacity.autoScaleSpeed = autoScaleSpeed

        xmlFile:delete()
        Log:debug("RmAscSettings: Loaded from %s (showTriggerShortcut=%s, autoScaleMass=%s, autoScaleSpeed=%s)",
            filePath, tostring(shortcutEnabled), tostring(autoScaleMass), tostring(autoScaleSpeed))
    end
end

--- Save settings to savegame XML (server only, called via FSCareerMissionInfo hook)
function RmAscSettings.saveToXMLFile()
    if g_server == nil then
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        return
    end

    local filePath = savegameDir .. "/rm_AscSettings.xml"
    local xmlFile = XMLFile.create("rm_AscSettings", filePath, "rmAscSettings")

    if xmlFile ~= nil then
        xmlFile:setBool("rmAscSettings#showTriggerShortcut",
            RmAscSettings.showTriggerShortcutState == 2)
        xmlFile:setBool("rmAscSettings#autoScaleMass",
            RmAscSettings.autoScaleMassState == 2)
        xmlFile:setBool("rmAscSettings#autoScaleSpeed",
            RmAscSettings.autoScaleSpeedState == 2)
        xmlFile:save()
        xmlFile:delete()
        Log:debug("RmAscSettings: Saved to %s", filePath)
    end
end

-- ============================================================================
-- Multiplayer Sync
-- ============================================================================

--- Send settings to a joining client
---@param _ table mission (unused)
---@param connection table Client connection
function RmAscSettings.sendInitialClientState(_, connection)
    connection:sendEvent(RmSettingsSyncEvent.new())
end

-- ============================================================================
-- Module Initialization (runs at source time)
-- ============================================================================

RmAscSettings.initGui()
RmAscSettings.setupHooks()
