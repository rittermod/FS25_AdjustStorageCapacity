-- RmMenuIntegration - In-game menu button integration for AdjustStorageCapacity
-- Author: Ritter
--
-- Adds "Adjust Capacity" button (K key) to production and husbandry menu pages.
-- When pressed, opens the storage capacity dialog for the selected placeable.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

---@class RmMenuIntegration
RmMenuIntegration = {}

--- Initialize menu hooks
-- Called after map is loaded to hook into game menus
function RmMenuIntegration.init()
    Log:debug("RmMenuIntegration: Initializing menu hooks...")

    -- Validate required game classes exist
    if InGameMenuProductionFrame == nil then
        Log:warning("InGameMenuProductionFrame not available - production menu integration disabled")
    else
        -- Hook into production menu updateMenuButtons
        InGameMenuProductionFrame.updateMenuButtons = Utils.appendedFunction(
            InGameMenuProductionFrame.updateMenuButtons,
            RmMenuIntegration.onProductionMenuButtons
        )
        Log:debug("RmMenuIntegration: Hooked into InGameMenuProductionFrame.updateMenuButtons")
    end

    if InGameMenuAnimalsFrame == nil then
        Log:warning("InGameMenuAnimalsFrame not available - animals menu integration disabled")
    else
        -- Hook into animals/husbandry menu updateMenuButtons
        InGameMenuAnimalsFrame.updateMenuButtons = Utils.appendedFunction(
            InGameMenuAnimalsFrame.updateMenuButtons,
            RmMenuIntegration.onAnimalsMenuButtons
        )
        Log:debug("RmMenuIntegration: Hooked into InGameMenuAnimalsFrame.updateMenuButtons")
    end

    Log:info("RmMenuIntegration: Menu hooks initialized")
end

--- Callback for production menu updateMenuButtons
-- Adds "Adjust Capacity" button when a production is selected
---@param frame table The InGameMenuProductionFrame instance
function RmMenuIntegration.onProductionMenuButtons(frame)
    -- Only show button when viewing OWNED productions (not "all productions" which includes other farms)
    -- This check is important for MP where players can view other farms' productions
    if frame.pointsSelector ~= nil then
        local selectorState = frame.pointsSelector:getState()
        if selectorState ~= InGameMenuProductionFrame.POINTS_OWNED then
            return
        end
    end

    -- Get the selected production point
    local _, productionPoint = frame:getSelectedProduction()

    if productionPoint ~= nil and productionPoint.owningPlaceable ~= nil then
        local placeable = productionPoint.owningPlaceable

        -- Only show button if placeable has modifiable storage
        if RmAdjustStorageCapacity:hasModifiableStorage(placeable) then
            -- Check permission (includes ownership, admin, and farm manager checks)
            local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(placeable)

            if canModify then
                table.insert(frame.menuButtonInfo, {
                    inputAction = InputAction.RM_ADJUST_STORAGE_CAPACITY,
                    text = g_i18n:getText("rm_asc_action_adjustCapacity"),
                    callback = function()
                        RmMenuIntegration.openCapacityDialog(placeable)
                    end
                })
                Log:trace("RmMenuIntegration: Added button to production menu for %s", placeable:getName())
            end
        end
    end
end

--- Callback for animals/husbandry menu updateMenuButtons
-- Adds "Adjust Capacity" button when a husbandry is selected
---@param frame table The InGameMenuAnimalsFrame instance
function RmMenuIntegration.onAnimalsMenuButtons(frame)
    -- Get the selected husbandry from the page
    -- The husbandry IS the placeable (extends Placeable class)
    local selectedHusbandry = nil

    -- Access via g_inGameMenu.pageAnimals (common pattern from reference mods)
    if g_inGameMenu ~= nil and g_inGameMenu.pageAnimals ~= nil then
        selectedHusbandry = g_inGameMenu.pageAnimals.selectedHusbandry
    end

    -- Fallback: try frame directly (some FS25 versions)
    if selectedHusbandry == nil and frame.selectedHusbandry ~= nil then
        selectedHusbandry = frame.selectedHusbandry
    end

    if selectedHusbandry ~= nil then
        local placeable = selectedHusbandry -- The husbandry IS the placeable

        -- Only show button if placeable has modifiable storage
        if RmAdjustStorageCapacity:hasModifiableStorage(placeable) then
            -- Check permission
            local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(placeable)

            if canModify then
                table.insert(frame.menuButtonInfo, {
                    inputAction = InputAction.RM_ADJUST_STORAGE_CAPACITY,
                    text = g_i18n:getText("rm_asc_action_adjustCapacity"),
                    callback = function()
                        RmMenuIntegration.openCapacityDialog(placeable)
                    end
                })
                Log:trace("RmMenuIntegration: Added button to animals menu for %s", placeable:getName())
            end
        end
    end
end

--- Opens the capacity dialog for a placeable
---@param placeable table The storage placeable
function RmMenuIntegration.openCapacityDialog(placeable)
    if placeable == nil then
        Log:warning("RmMenuIntegration.openCapacityDialog: placeable is nil")
        return
    end

    Log:debug("RmMenuIntegration: Opening capacity dialog for %s", placeable:getName())
    RmStorageCapacityDialog.show(placeable)
end
