-- RmAscSettings - Game settings integration for AdjustStorageCapacity
-- Author: Ritter
--
-- Adds a toggle to the Game Settings page to show/hide the shortcut at triggers.
-- Follows the EAS/RL pattern: clone BinaryOption from gameSettingsLayout.

local Log = RmLogging.getLogger("AdjustStorageCapacity")

RmAscSettings = {}

-- Runtime state (1 = OFF, 2 = ON; BinaryOption convention)
RmAscSettings.showTriggerShortcutState = 2  -- default: enabled

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
        xmlFile:delete()
        Log:debug("RmAscSettings: Loaded from %s (showTriggerShortcut=%s)",
            filePath, tostring(shortcutEnabled))
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
