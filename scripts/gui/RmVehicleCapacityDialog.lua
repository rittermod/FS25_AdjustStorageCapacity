-- RmVehicleCapacityDialog - GUI dialog for viewing and editing vehicle capacity
-- Author: Ritter
--
-- Dialog showing fill units and their capacities with inline editing.
-- Similar to RmStorageCapacityDialog but adapted for vehicle fill units.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

---@class RmVehicleCapacityDialog : MessageDialog
RmVehicleCapacityDialog = {}
local RmVehicleCapacityDialog_mt = Class(RmVehicleCapacityDialog, MessageDialog)

RmVehicleCapacityDialog.CONTROLS = {
    "fillUnitList",
    "listSlider",
    "emptyListText",
    "dialogTitleElement"
}

-- Dialog state
RmVehicleCapacityDialog.vehicle = nil
RmVehicleCapacityDialog.fillUnitEntries = {}

-- Editing state
RmVehicleCapacityDialog.editingIndex = nil
RmVehicleCapacityDialog.editingEntry = nil
RmVehicleCapacityDialog.editingOriginalValue = nil
RmVehicleCapacityDialog.editingInputElement = nil
RmVehicleCapacityDialog.lastSelectedIndex = nil

--- Creates a new RmVehicleCapacityDialog instance
---@param target table|nil the target object
---@param custom_mt table|nil optional custom metatable
---@return RmVehicleCapacityDialog the new dialog instance
function RmVehicleCapacityDialog.new(target, custom_mt)
    Log:trace("RmVehicleCapacityDialog:new()")
    ---@type RmVehicleCapacityDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, custom_mt or RmVehicleCapacityDialog_mt)
    self.fillUnitEntries = {}
    self.vehicle = nil
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil
    self.lastSelectedIndex = nil
    return self
end

function RmVehicleCapacityDialog:onGuiSetupFinished()
    Log:trace("RmVehicleCapacityDialog:onGuiSetupFinished()")
    RmVehicleCapacityDialog:superClass().onGuiSetupFinished(self)
    self.fillUnitList:setDataSource(self)
end

function RmVehicleCapacityDialog:onCreate()
    Log:trace("RmVehicleCapacityDialog:onCreate()")
    RmVehicleCapacityDialog:superClass().onCreate(self)
end

function RmVehicleCapacityDialog:onOpen()
    Log:trace("RmVehicleCapacityDialog:onOpen()")
    RmVehicleCapacityDialog:superClass().onOpen(self)

    -- Clear any previous editing state
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil
    self.lastSelectedIndex = nil

    -- Update title
    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(g_i18n:getText("rm_asc_vehicle_dialog_title"))
    end

    -- Build list of fill unit entries
    self:refreshFillUnitList()

    -- Show/hide empty state message
    self:updateEmptyState()

    -- Reload the list data
    self.fillUnitList:reloadData()

    -- Set focus to the list
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillUnitList)
    self:setSoundSuppressed(false)
end

function RmVehicleCapacityDialog:onClose()
    Log:trace("RmVehicleCapacityDialog:onClose()")
    self:cancelEditing()
    self.fillUnitEntries = {}
    self.vehicle = nil
    RmVehicleCapacityDialog:superClass().onClose(self)
end

--- Refreshes the fill unit entries list from the vehicle
function RmVehicleCapacityDialog:refreshFillUnitList()
    self.fillUnitEntries = {}

    if self.vehicle == nil then
        return
    end

    -- Check if vehicle has our specialization
    local spec = self.vehicle[RmVehicleStorageCapacity.SPEC_TABLE_NAME]
    if spec == nil then
        Log:warning("Vehicle %s does not have RmVehicleStorageCapacity specialization", self.vehicle:getName())
        return
    end

    -- Get fill unit info from specialization
    local fillUnits = RmVehicleStorageCapacity.getAllFillUnitInfo(self.vehicle)

    for _, fu in ipairs(fillUnits) do
        -- Get original capacity for reset functionality
        local originalCapacity = spec.originalCapacities[fu.index] or fu.capacity

        -- Check if this fill unit has custom capacity
        local customCapacity = nil
        local uniqueId = self.vehicle.uniqueId
        if uniqueId ~= nil and RmAdjustStorageCapacity.vehicleCapacities[uniqueId] ~= nil then
            customCapacity = RmAdjustStorageCapacity.vehicleCapacities[uniqueId][fu.index]
        end

        table.insert(self.fillUnitEntries, {
            fillUnitIndex = fu.index,
            name = fu.name,
            capacity = fu.capacity,
            originalCapacity = originalCapacity,
            customCapacity = customCapacity,
            fillLevel = fu.fillLevel,
            fillType = fu.fillType,
            supportedFillTypes = fu.supportedFillTypes
        })
    end

    Log:debug("Refreshed fill unit list: %d entries", #self.fillUnitEntries)
end

--- Updates the visibility of the empty state message
function RmVehicleCapacityDialog:updateEmptyState()
    local isEmpty = #self.fillUnitEntries == 0
    self.emptyListText:setVisible(isEmpty)
    self.fillUnitList:setVisible(not isEmpty)
end

-- DataSource methods

function RmVehicleCapacityDialog:getNumberOfItemsInSection(list, section)
    if list == self.fillUnitList then
        return #self.fillUnitEntries
    end
    return 0
end

function RmVehicleCapacityDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.fillUnitList then
        local entry = self.fillUnitEntries[index]
        if entry then
            local iconElement = cell:getAttribute("fillTypeIcon")
            local nameElement = cell:getAttribute("fillTypeName")
            local secondaryElement = cell:getAttribute("capacityText")
            local rightElement = cell:getAttribute("fillLevelText")
            local inputElement = cell:getAttribute("capacityInput")

            local isEditing = (self.editingIndex == index)

            -- Show/hide input element based on editing state
            if inputElement ~= nil then
                if isEditing then
                    inputElement:setVisible(true)
                    inputElement:setText(tostring(math.floor(entry.capacity or 0)))
                    rightElement:setVisible(false)
                    self.editingInputElement = inputElement
                else
                    inputElement:setVisible(false)
                    rightElement:setVisible(true)
                end
            end

            -- Set fill type icon
            if iconElement ~= nil then
                local fillType = g_fillTypeManager:getFillTypeByIndex(entry.fillType)
                if fillType ~= nil and fillType.hudOverlayFilename ~= nil then
                    iconElement:setImageFilename(fillType.hudOverlayFilename)
                    iconElement:setVisible(true)
                else
                    iconElement:setVisible(false)
                end
            end

            -- Set name
            nameElement:setText(entry.name or "Unknown")

            -- Set secondary text (fill level)
            secondaryElement:setText(string.format("Fill: %s", g_i18n:formatVolume(entry.fillLevel)))

            -- Set right text (capacity) - with custom marker if modified
            if not isEditing then
                local capacityText = g_i18n:formatVolume(entry.capacity)
                if entry.customCapacity ~= nil then
                    capacityText = capacityText .. " *"
                end
                rightElement:setText(capacityText)
            end
        end
    end
end

-- Button handlers

function RmVehicleCapacityDialog:onClickClose()
    Log:trace("RmVehicleCapacityDialog:onClickClose()")
    if self.editingIndex ~= nil then
        self:cancelEditing()
    end
    self:close()
end

function RmVehicleCapacityDialog:onClickResetAll()
    Log:debug("RmVehicleCapacityDialog:onClickResetAll()")

    if self.vehicle == nil then
        return
    end

    -- Reset all fill units
    RmVehicleCapacitySyncEvent.sendResetCapacity(self.vehicle, nil)

    -- Refresh the list
    self:refreshFillUnitList()
    self.fillUnitList:reloadData()
end

-- Editing methods

--- Starts editing a row
---@param index number The 1-based index of the row to edit
function RmVehicleCapacityDialog:startEditing(index)
    local entry = self.fillUnitEntries[index]
    if entry == nil then
        Log:warning("startEditing: invalid index %d", index)
        return
    end

    Log:debug("startEditing: index=%d, name=%s, capacity=%d",
        index, entry.name or "?", entry.capacity or 0)

    if self.editingIndex ~= nil then
        self:cancelEditing()
    end

    self.editingIndex = index
    self.editingEntry = entry
    self.editingOriginalValue = entry.capacity

    self.fillUnitList:reloadData()

    local inputElement = self.editingInputElement
    if inputElement ~= nil then
        FocusManager:setFocus(inputElement)
        inputElement:setForcePressed(true)
        Log:debug("startEditing: input element shown")
    end
end

--- Cancels the current edit
function RmVehicleCapacityDialog:cancelEditing()
    if self.editingIndex == nil then
        return
    end

    Log:debug("cancelEditing: index=%d", self.editingIndex)

    if self.editingInputElement ~= nil then
        self.editingInputElement:setForcePressed(false)
    end

    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil

    self.fillUnitList:reloadData()

    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillUnitList)
    self:setSoundSuppressed(false)
end

--- Applies the edited value
function RmVehicleCapacityDialog:applyEditing()
    if self.editingIndex == nil or self.editingEntry == nil then
        return
    end

    local newValueStr = ""
    if self.editingInputElement ~= nil then
        newValueStr = self.editingInputElement:getText() or ""
    end

    local newValue = tonumber(newValueStr)
    if newValue == nil or newValue < 0 then
        Log:warning("applyEditing: invalid value '%s'", newValueStr)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("rm_asc_error_invalidCapacity"))
        self:cancelEditing()
        return
    end

    newValue = math.floor(newValue)

    -- Clamp to minimum capacity (current fill level) to prevent data loss
    local minCapacity = math.floor(self.editingEntry.fillLevel or 0)
    local wasClamped = false
    if newValue < minCapacity then
        Log:info("Capacity clamped from %d to %d (current fill level)", newValue, minCapacity)
        newValue = minCapacity
        wasClamped = true
    end

    Log:debug("applyEditing: fillUnit=%d, oldValue=%d, newValue=%d%s",
        self.editingEntry.fillUnitIndex, self.editingOriginalValue or 0, newValue,
        wasClamped and " (clamped)" or "")

    -- Send the capacity change via network event (pass wasClamped so notification shows correctly)
    RmVehicleCapacitySyncEvent.sendSetCapacity(self.vehicle, self.editingEntry.fillUnitIndex, newValue, wasClamped)

    local editedIndex = self.editingIndex

    if self.editingInputElement ~= nil then
        self.editingInputElement:setForcePressed(false)
    end

    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil

    -- Update entry for immediate feedback
    if editedIndex ~= nil and self.fillUnitEntries[editedIndex] ~= nil then
        self.fillUnitEntries[editedIndex].capacity = newValue
        self.fillUnitEntries[editedIndex].customCapacity = newValue
    end

    self.fillUnitList:reloadData()

    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillUnitList)
    self:setSoundSuppressed(false)
end

-- List event handlers

function RmVehicleCapacityDialog:onListClick(list, section, index)
    Log:debug("onListClick: section=%d, index=%d", section or 0, index or 0)

    if index == nil or index < 1 or index > #self.fillUnitEntries then
        return
    end

    if self.lastSelectedIndex == index then
        self:startEditing(index)
        return
    end

    self.lastSelectedIndex = index
end

function RmVehicleCapacityDialog:onListDoubleClick(list, section, index)
    Log:debug("onListDoubleClick: section=%d, index=%d", section or 0, index or 0)

    if index == nil or index < 1 or index > #self.fillUnitEntries then
        return
    end

    self:startEditing(index)
end

-- TextInput callbacks

function RmVehicleCapacityDialog:onCapacityInputEnter(element)
    Log:debug("onCapacityInputEnter")
    self:applyEditing()
end

function RmVehicleCapacityDialog:onCapacityInputEscape(element)
    Log:debug("onCapacityInputEscape")
    self:cancelEditing()
end

function RmVehicleCapacityDialog:onCapacityIsUnicodeAllowed(unicode)
    return unicode >= 48 and unicode <= 57
end

-- Static methods

--- Sets the vehicle context before showing the dialog
---@param vehicle table The vehicle to display
function RmVehicleCapacityDialog.setVehicle(vehicle)
    local dialogEntry = g_gui.guis["RmVehicleCapacityDialog"]
    if dialogEntry ~= nil and dialogEntry.target ~= nil then
        dialogEntry.target.vehicle = vehicle
    end
end

--- Registers the dialog with the GUI system
function RmVehicleCapacityDialog.register()
    Log:trace("RmVehicleCapacityDialog.register()")
    local dialog = RmVehicleCapacityDialog.new(g_i18n)
    g_gui:loadGui(RmAdjustStorageCapacity.modDirectory .. "gui/RmVehicleCapacityDialog.xml", "RmVehicleCapacityDialog", dialog)
    Log:info("RmVehicleCapacityDialog registered")
end

--- Shows the dialog for a vehicle
---@param vehicle table The vehicle
function RmVehicleCapacityDialog.show(vehicle)
    Log:trace("RmVehicleCapacityDialog.show()")

    if vehicle == nil then
        Log:warning("RmVehicleCapacityDialog.show: vehicle is nil")
        return
    end

    RmVehicleCapacityDialog.setVehicle(vehicle)
    g_gui:showDialog("RmVehicleCapacityDialog")
end
