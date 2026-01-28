-- RmMenuIntegration - In-game menu button integration for AdjustStorageCapacity
-- Author: Ritter
--
-- Adds "Adjust Capacity" button (K key) to:
-- - Production menu: Opens storage dialog for selected production point
-- - Animals menu: Opens storage dialog for selected husbandry
-- - Workshop/repair screen: Opens vehicle dialog for selected vehicle
-- - Placeable info dialog: Opens storage dialog when viewing placeable in construction mode

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

---@class RmMenuIntegration
RmMenuIntegration = {}

--- Initialize menu hooks
-- Called after map is loaded to hook into game menus
function RmMenuIntegration.init()
    Log:debug("RmMenuIntegration: Initializing menu hooks...")

    -- Register our input action with the GUI system so K key works in menus/dialogs
    -- Gui.NAV_ACTIONS controls which actions are dispatched to screens via inputEvent
    if Gui ~= nil and Gui.NAV_ACTIONS ~= nil then
        table.insert(Gui.NAV_ACTIONS, InputAction.RM_ADJUST_STORAGE_CAPACITY)
        Log:debug("RmMenuIntegration: Registered RM_ADJUST_STORAGE_CAPACITY in Gui.NAV_ACTIONS")
    end

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

    -- Hook into WorkshopScreen (vehicle repair/sell screen)
    RmMenuIntegration.initWorkshopScreen()

    -- Hook into PlaceableInfoDialog (construction mode placeable info)
    RmMenuIntegration.initPlaceableInfoDialog()

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

-- ============================================================================
-- WorkshopScreen Integration (Vehicle Repair/Sell Screen)
-- ============================================================================

--- Initialize WorkshopScreen hooks
-- Adds K button to the vehicle repair/sell screen
function RmMenuIntegration.initWorkshopScreen()
    if WorkshopScreen == nil then
        Log:warning("WorkshopScreen not available - workshop menu integration disabled")
        return
    end

    -- Hook into setVehicle to add/update our button when a vehicle is selected
    -- Note: WorkshopScreen is a singleton, button persists across opens/closes
    WorkshopScreen.setVehicle = Utils.appendedFunction(
        WorkshopScreen.setVehicle,
        RmMenuIntegration.onWorkshopSetVehicle
    )

    Log:debug("RmMenuIntegration: Hooked into WorkshopScreen.setVehicle")
end

--- Callback when WorkshopScreen.setVehicle is called
-- Creates the button on first call, then updates visibility/disabled state
---@param workshopScreen table The WorkshopScreen instance (self)
---@param vehicle table|nil The selected vehicle
function RmMenuIntegration.onWorkshopSetVehicle(workshopScreen, vehicle)
    -- Create button on first call (button persists across vehicle selections)
    if workshopScreen.rmAdjustCapacityButton == nil then
        -- Clone the repair button as template (has correct profile/styling)
        local btn = workshopScreen.repairButton:clone()
        btn:setText(g_i18n:getText("rm_asc_action_adjustVehicleCapacity"))
        btn.inputActionName = InputAction.RM_ADJUST_STORAGE_CAPACITY
        btn:loadInputGlyph(true)
        btn.onClickCallback = function()
            RmMenuIntegration.onWorkshopAdjustCapacity(workshopScreen)
        end

        -- Add to button container (same parent as repair button)
        workshopScreen.repairButton.parent:addElement(btn)
        workshopScreen.rmAdjustCapacityButton = btn

        Log:debug("RmMenuIntegration: Created adjust capacity button in WorkshopScreen")
    end

    -- Update button visibility and disabled state based on selected vehicle
    local btn = workshopScreen.rmAdjustCapacityButton

    if vehicle == nil then
        -- No vehicle selected
        btn:setDisabled(true)
        btn:setVisible(false)
    else
        -- Check if vehicle is supported for capacity adjustment
        local isSupported, _ = RmVehicleStorageCapacity.isVehicleSupported(vehicle)

        if not isSupported then
            -- Vehicle not supported (pallet, big bag, no fill units, etc.)
            btn:setDisabled(true)
            btn:setVisible(false)
        else
            -- Check if player has permission to modify
            local canModify, _ = RmAdjustStorageCapacity:canModifyVehicleCapacity(vehicle)

            btn:setVisible(true)
            btn:setDisabled(not canModify)
        end
    end

    -- Re-layout buttons to accommodate new/changed button
    workshopScreen.buttonsBox:invalidateLayout()
end

--- Callback when adjust capacity button is clicked in WorkshopScreen
---@param workshopScreen table The WorkshopScreen instance
function RmMenuIntegration.onWorkshopAdjustCapacity(workshopScreen)
    if workshopScreen.vehicle == nil then
        Log:warning("RmMenuIntegration.onWorkshopAdjustCapacity: No vehicle selected")
        return
    end

    Log:debug("RmMenuIntegration: Opening vehicle capacity dialog from WorkshopScreen for %s",
        workshopScreen.vehicle:getName())
    RmVehicleCapacityDialog.show(workshopScreen.vehicle)
end

-- ============================================================================
-- PlaceableInfoDialog Integration (Construction Mode Placeable Info)
-- ============================================================================

--- Initialize PlaceableInfoDialog hooks
-- Adds K button to the placeable info dialog shown in construction mode
function RmMenuIntegration.initPlaceableInfoDialog()
    if PlaceableInfoDialog == nil then
        Log:warning("PlaceableInfoDialog not available - construction mode integration disabled")
        return
    end

    -- Hook into setPlaceable to add/update our button when a placeable is shown
    PlaceableInfoDialog.setPlaceable = Utils.appendedFunction(
        PlaceableInfoDialog.setPlaceable,
        RmMenuIntegration.onPlaceableInfoSetPlaceable
    )

    Log:debug("RmMenuIntegration: Hooked into PlaceableInfoDialog.setPlaceable")
end

--- Callback when PlaceableInfoDialog.setPlaceable is called
-- Creates the button on first call, then updates visibility/disabled state
---@param dialog table The PlaceableInfoDialog instance (self)
---@param placeable table The placeable being shown
function RmMenuIntegration.onPlaceableInfoSetPlaceable(dialog, placeable)
    -- Create button on first call (button persists since dialog is singleton)
    if dialog.rmAdjustCapacityButton == nil then
        -- Clone the sell button as template (has correct profile/styling)
        local btn = dialog.sellButton:clone()
        btn:setText(g_i18n:getText("rm_asc_action_capacity"))
        btn.inputActionName = InputAction.RM_ADJUST_STORAGE_CAPACITY
        btn:loadInputGlyph(true)

        -- Insert at beginning for left positioning (before other buttons)
        -- Note: GuiElement has no insertElement method, so we manually insert into elements table
        local parent = dialog.sellButton.parent
        table.insert(parent.elements, 1, btn)
        btn.parent = parent
        dialog.rmAdjustCapacityButton = btn

        Log:debug("RmMenuIntegration: Created adjust capacity button in PlaceableInfoDialog")
    end

    -- Update button callback to use current placeable (captured in closure)
    local btn = dialog.rmAdjustCapacityButton
    btn.onClickCallback = function()
        RmMenuIntegration.onPlaceableInfoAdjustCapacity(placeable)
    end

    -- Update button visibility and disabled state based on placeable
    if placeable == nil then
        btn:setDisabled(true)
        btn:setVisible(false)
    else
        -- Check if placeable has modifiable storage
        local hasStorage = RmAdjustStorageCapacity:hasModifiableStorage(placeable)

        if not hasStorage then
            -- Placeable has no modifiable storage (decoration, house, etc.)
            btn:setDisabled(true)
            btn:setVisible(false)
        else
            -- Check if player has permission to modify
            local canModify, _ = RmAdjustStorageCapacity:canModifyCapacity(placeable)

            btn:setVisible(true)
            btn:setDisabled(not canModify)
        end
    end

    -- Re-layout buttons to accommodate new/changed button
    dialog.sellButton.parent:invalidateLayout()
end

--- Callback when adjust capacity button is clicked in PlaceableInfoDialog
---@param placeable table The placeable to adjust
function RmMenuIntegration.onPlaceableInfoAdjustCapacity(placeable)
    if placeable == nil then
        Log:warning("RmMenuIntegration.onPlaceableInfoAdjustCapacity: placeable is nil")
        return
    end

    Log:debug("RmMenuIntegration: Opening capacity dialog from PlaceableInfoDialog for %s",
        placeable:getName())
    RmStorageCapacityDialog.show(placeable)
end
