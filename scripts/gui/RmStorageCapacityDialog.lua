-- RmStorageCapacityDialog - GUI dialog for viewing and editing storage capacity
-- Author: Ritter
--
-- Dialog showing fill types and their capacities with inline editing.
-- Uses SmoothList with DataSource pattern. Double-click a row to edit capacity.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

---@class RmStorageCapacityDialog : MessageDialog
---@field fillTypeEntries table[] List of fill type entries for display
---@field fillTypeList table GUI list element
---@field listSlider table GUI slider element
---@field emptyListText table GUI text element for empty state
---@field dialogTitleElement table GUI text element for title
---@field editingIndex number|nil Index of row being edited (1-based)
---@field editingEntry table|nil Entry being edited
---@field editingOriginalValue number|nil Original capacity before editing
---@field editingInputElement table|nil Reference to the active TextInputElement
RmStorageCapacityDialog = {}
local RmStorageCapacityDialog_mt = Class(RmStorageCapacityDialog, MessageDialog)

RmStorageCapacityDialog.CONTROLS = {
    "fillTypeList",
    "listSlider",
    "emptyListText",
    "dialogTitleElement"
}

-- Dialog state
RmStorageCapacityDialog.placeable = nil
RmStorageCapacityDialog.fillTypeEntries = {}
RmStorageCapacityDialog.isSharedCapacityMode = false

-- Editing state
RmStorageCapacityDialog.editingIndex = nil
RmStorageCapacityDialog.editingEntry = nil
RmStorageCapacityDialog.editingOriginalValue = nil
RmStorageCapacityDialog.editingInputElement = nil
RmStorageCapacityDialog.lastSelectedIndex = nil

--- Creates a new RmStorageCapacityDialog instance
---@param target table|nil the target object
---@param custom_mt table|nil optional custom metatable
---@return RmStorageCapacityDialog the new dialog instance
function RmStorageCapacityDialog.new(target, custom_mt)
    Log:trace("RmStorageCapacityDialog:new()")
    ---@type RmStorageCapacityDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, custom_mt or RmStorageCapacityDialog_mt)
    self.fillTypeEntries = {}
    self.placeable = nil
    -- Initialize editing state
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil
    self.lastSelectedIndex = nil
    return self
end

function RmStorageCapacityDialog:onGuiSetupFinished()
    Log:trace("RmStorageCapacityDialog:onGuiSetupFinished()")
    RmStorageCapacityDialog:superClass().onGuiSetupFinished(self)
    self.fillTypeList:setDataSource(self)
end

function RmStorageCapacityDialog:onCreate()
    Log:trace("RmStorageCapacityDialog:onCreate()")
    RmStorageCapacityDialog:superClass().onCreate(self)
end

function RmStorageCapacityDialog:onOpen()
    Log:trace("RmStorageCapacityDialog:onOpen()")
    RmStorageCapacityDialog:superClass().onOpen(self)

    -- Clear any previous editing state
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil
    self.lastSelectedIndex = nil

    -- Update title with function name (action dialog pattern)
    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(g_i18n:getText("rm_asc_dialog_title"))
    end

    -- Build list of fill type entries
    self:refreshFillTypeList()

    -- Show/hide empty state message
    self:updateEmptyState()

    -- Reload the list data
    self.fillTypeList:reloadData()

    -- Set focus to the list
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillTypeList)
    self:setSoundSuppressed(false)
end

function RmStorageCapacityDialog:onClose()
    Log:trace("RmStorageCapacityDialog:onClose()")
    -- Clear editing state
    self:cancelEditing()
    self.fillTypeEntries = {}
    self.placeable = nil
    RmStorageCapacityDialog:superClass().onClose(self)
end

--- Refreshes the fill type entries list from the placeable
function RmStorageCapacityDialog:refreshFillTypeList()
    self.fillTypeEntries = {}
    self.isSharedCapacityMode = false

    if self.placeable == nil then
        return
    end

    -- Get all fill types from the placeable
    local fillTypes = RmAdjustStorageCapacity:getAllFillTypes(self.placeable)

    -- Get custom capacities for this placeable (to show * marker)
    local uniqueId = self.placeable.uniqueId
    local customCapacity = uniqueId and RmAdjustStorageCapacity.customCapacities[uniqueId] or nil

    -- Check if this is a shared capacity storage (all entries have isSharedCapacity = true)
    local hasSharedCapacity = false
    local sharedCapacityValue = 0
    local totalFillLevel = 0

    for _, ft in ipairs(fillTypes) do
        if ft.isSharedCapacity then
            hasSharedCapacity = true
            sharedCapacityValue = ft.capacity
        end
        totalFillLevel = totalFillLevel + (ft.fillLevel or 0)
    end

    -- If all fill types share capacity, use shared capacity mode
    if hasSharedCapacity and #fillTypes > 0 then
        self.isSharedCapacityMode = true

        -- Check if shared capacity has been modified
        local hasCustomSharedCapacity = customCapacity ~= nil and customCapacity.sharedCapacity ~= nil

        -- Insert header row for shared capacity (fillTypeIndex = 0 is special marker)
        table.insert(self.fillTypeEntries, {
            fillTypeIndex = 0, -- Special marker for shared capacity header
            fillTypeName = g_i18n:getText("rm_asc_sharedCapacity") or "Shared Capacity",
            capacity = sharedCapacityValue,
            fillLevel = totalFillLevel,
            isSharedCapacityHeader = true,
            hasCustomCapacity = hasCustomSharedCapacity
        })

        -- Add fill type entries (they will only show fill level, not capacity)
        for _, ft in ipairs(fillTypes) do
            local entry = {
                fillTypeIndex = ft.fillTypeIndex,
                fillTypeName = ft.fillTypeName,
                capacity = nil, -- Don't show capacity for individual fill types in shared mode
                fillLevel = ft.fillLevel,
                storageType = ft.storageType,
                isSharedCapacity = true
            }
            table.insert(self.fillTypeEntries, entry)
        end

        -- Sort fill types alphabetically (but keep header at top)
        table.sort(self.fillTypeEntries, function(a, b)
            -- Header always stays at top
            if a.isSharedCapacityHeader then return true end
            if b.isSharedCapacityHeader then return false end
            return (a.fillTypeName or "") < (b.fillTypeName or "")
        end)
    else
        -- Per-filltype mode (original behavior)
        for _, ft in ipairs(fillTypes) do
            -- Check if this fill type has custom capacity
            local hasCustom = false
            if ft.fillTypeIndex == -1 then
                -- Husbandry food
                hasCustom = customCapacity ~= nil and customCapacity.husbandryFood ~= nil
            else
                -- Regular fill type
                hasCustom = customCapacity ~= nil and customCapacity.fillTypes ~= nil
                    and customCapacity.fillTypes[ft.fillTypeIndex] ~= nil
            end

            local entry = {
                fillTypeIndex = ft.fillTypeIndex,
                fillTypeName = ft.fillTypeName,
                capacity = ft.capacity,
                fillLevel = ft.fillLevel,
                storageType = ft.storageType,
                hasCustomCapacity = hasCustom
            }
            table.insert(self.fillTypeEntries, entry)
        end

        -- Sort alphabetically by fill type name
        table.sort(self.fillTypeEntries, function(a, b)
            return (a.fillTypeName or "") < (b.fillTypeName or "")
        end)
    end

    Log:debug("Refreshed fill type list: %d entries", #self.fillTypeEntries)
end

--- Updates the visibility of the empty state message
function RmStorageCapacityDialog:updateEmptyState()
    local isEmpty = #self.fillTypeEntries == 0
    self.emptyListText:setVisible(isEmpty)
    self.fillTypeList:setVisible(not isEmpty)
end

-- DataSource methods

function RmStorageCapacityDialog:getNumberOfItemsInSection(list, section)
    if list == self.fillTypeList then
        return #self.fillTypeEntries
    end
    return 0
end

function RmStorageCapacityDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.fillTypeList then
        local entry = self.fillTypeEntries[index]
        if entry then
            local iconElement = cell:getAttribute("fillTypeIcon")
            local nameElement = cell:getAttribute("fillTypeName")
            local secondaryElement = cell:getAttribute("capacityText")
            local rightElement = cell:getAttribute("fillLevelText")
            local inputElement = cell:getAttribute("capacityInput")

            -- Check if this row is being edited
            local isEditing = (self.editingIndex == index)
            local isEditable = self:isEntryEditable(entry)

            -- Show/hide input element based on editing state
            if inputElement ~= nil then
                if isEditing then
                    -- Show input, hide text
                    inputElement:setVisible(true)
                    inputElement:setText(tostring(math.floor(entry.capacity or 0)))
                    rightElement:setVisible(false)
                    -- Store reference (activation happens after reloadData in startEditing)
                    self.editingInputElement = inputElement
                else
                    -- Show text, hide input
                    inputElement:setVisible(false)
                    rightElement:setVisible(true)
                end
            end

            if entry.isSharedCapacityHeader then
                -- Shared capacity header row
                if iconElement ~= nil then
                    iconElement:setVisible(false)
                end
                nameElement:setText(entry.fillTypeName or "Shared Capacity")
                secondaryElement:setText(string.format("Total Fill: %s", g_i18n:formatVolume(entry.fillLevel)))
                if not isEditing then
                    local capacityText = g_i18n:formatVolume(entry.capacity)
                    if entry.hasCustomCapacity then
                        capacityText = capacityText .. " *"
                    end
                    rightElement:setText(capacityText)
                end

            elseif entry.isSharedCapacity then
                -- Fill type row in shared capacity mode (show fill level on right, no capacity)
                if iconElement ~= nil then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(entry.fillTypeIndex)
                    if fillType ~= nil and fillType.hudOverlayFilename ~= nil then
                        iconElement:setImageFilename(fillType.hudOverlayFilename)
                        iconElement:setVisible(true)
                    else
                        iconElement:setVisible(false)
                    end
                end
                nameElement:setText(entry.fillTypeName or "Unknown")
                secondaryElement:setText("") -- No secondary text needed
                rightElement:setText(g_i18n:formatVolume(entry.fillLevel))
                -- Not editable in shared mode (only header is)
                if inputElement ~= nil then
                    inputElement:setVisible(false)
                end

            else
                -- Per-filltype mode (original behavior)
                if iconElement ~= nil then
                    if entry.fillTypeIndex ~= -1 and entry.fillTypeIndex ~= 0 then
                        local fillType = g_fillTypeManager:getFillTypeByIndex(entry.fillTypeIndex)
                        if fillType ~= nil and fillType.hudOverlayFilename ~= nil then
                            iconElement:setImageFilename(fillType.hudOverlayFilename)
                            iconElement:setVisible(true)
                        else
                            iconElement:setVisible(false)
                        end
                    else
                        -- Husbandry food (fillTypeIndex == -1) or special entries
                        iconElement:setVisible(false)
                    end
                end
                nameElement:setText(entry.fillTypeName or "Unknown")
                secondaryElement:setText(string.format("Fill: %s", g_i18n:formatVolume(entry.fillLevel)))
                if not isEditing then
                    local capacityText = g_i18n:formatVolume(entry.capacity)
                    if entry.hasCustomCapacity then
                        capacityText = capacityText .. " *"
                    end
                    rightElement:setText(capacityText)
                end
            end
        end
    end
end

-- Button handlers

function RmStorageCapacityDialog:onClickClose()
    Log:trace("RmStorageCapacityDialog:onClickClose()")
    -- Cancel any active editing before closing
    if self.editingIndex ~= nil then
        self:cancelEditing()
    end
    self:close()
end

-- Editing methods

--- Checks if an entry can be edited
---@param entry table The fill type entry
---@return boolean True if editable
function RmStorageCapacityDialog:isEntryEditable(entry)
    if entry == nil then
        return false
    end
    -- In shared capacity mode, only the header row is editable
    if self.isSharedCapacityMode then
        return entry.isSharedCapacityHeader == true
    end
    -- In per-filltype mode, all entries with capacity are editable
    return entry.capacity ~= nil
end

--- Starts editing a row
---@param index number The 1-based index of the row to edit
function RmStorageCapacityDialog:startEditing(index)
    local entry = self.fillTypeEntries[index]
    if entry == nil then
        Log:warning("startEditing: invalid index %d", index)
        return
    end

    if not self:isEntryEditable(entry) then
        Log:debug("startEditing: entry at index %d is not editable", index)
        return
    end

    Log:debug("startEditing: index=%d, fillType=%s, capacity=%d",
        index, entry.fillTypeName or "?", entry.capacity or 0)

    -- Cancel any existing edit first
    if self.editingIndex ~= nil then
        self:cancelEditing()
    end

    -- Set editing state
    self.editingIndex = index
    self.editingEntry = entry
    self.editingOriginalValue = entry.capacity

    -- Reload list to show input element (this calls populateCellForItemInSection)
    self.fillTypeList:reloadData()

    -- Set focus to the input element
    -- TODO: TextInputElement cursor activation not working programmatically.
    -- User needs to press Enter/click once more after input is shown to activate cursor.
    -- Attempted: setForcePressed, onFocusActivate, mouseEvent, onClickSelf - none activate cursor.
    -- Needs further research into FS25 TextInputElement internals.
    local inputElement = self.editingInputElement
    if inputElement ~= nil then
        FocusManager:setFocus(inputElement)
        inputElement:setForcePressed(true)
        Log:debug("startEditing: input element shown, awaiting user activation")
    else
        Log:warning("startEditing: editingInputElement is nil after reload")
    end
end

--- Cancels the current edit
function RmStorageCapacityDialog:cancelEditing()
    if self.editingIndex == nil then
        return
    end

    Log:debug("cancelEditing: index=%d", self.editingIndex)

    -- Deactivate the input element if it exists
    if self.editingInputElement ~= nil then
        self.editingInputElement:setForcePressed(false)
    end

    -- Clear editing state
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil

    -- Reload list to hide input element
    self.fillTypeList:reloadData()

    -- Return focus to list
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillTypeList)
    self:setSoundSuppressed(false)
end

--- Applies the edited value
function RmStorageCapacityDialog:applyEditing()
    if self.editingIndex == nil or self.editingEntry == nil then
        return
    end

    -- Get the new value from the input element
    local newValueStr = ""
    if self.editingInputElement ~= nil then
        newValueStr = self.editingInputElement:getText() or ""
    end

    local newValue = tonumber(newValueStr)
    if newValue == nil or newValue < 0 then
        Log:warning("applyEditing: invalid value '%s'", newValueStr)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("rm_asc_error_invalidCapacity"))
        -- Cancel instead of applying invalid value
        self:cancelEditing()
        return
    end

    -- Round to integer
    newValue = math.floor(newValue)

    Log:debug("applyEditing: fillType=%s, oldValue=%d, newValue=%d",
        self.editingEntry.fillTypeName or "?", self.editingOriginalValue or 0, newValue)

    -- Determine the fill type index to use
    local fillTypeIndex
    if self.editingEntry.isSharedCapacityHeader then
        -- For shared capacity, use fillTypeIndex 0 (special marker)
        fillTypeIndex = 0
    else
        fillTypeIndex = self.editingEntry.fillTypeIndex
    end

    -- Send the capacity change via network event
    RmStorageCapacitySyncEvent.sendSetCapacity(self.placeable, fillTypeIndex, newValue)

    -- Save index before clearing state
    local editedIndex = self.editingIndex

    -- Deactivate input
    if self.editingInputElement ~= nil then
        self.editingInputElement:setForcePressed(false)
    end

    -- Clear editing state
    self.editingIndex = nil
    self.editingEntry = nil
    self.editingOriginalValue = nil
    self.editingInputElement = nil

    -- Update the entry directly for immediate visual feedback
    -- (Don't call refreshFillTypeList - it reads from storage which may not be updated yet in MP)
    if editedIndex ~= nil and self.fillTypeEntries[editedIndex] ~= nil then
        self.fillTypeEntries[editedIndex].capacity = newValue
        self.fillTypeEntries[editedIndex].hasCustomCapacity = true
    end

    -- Reload list to show updated value
    self.fillTypeList:reloadData()

    -- Return focus to list
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.fillTypeList)
    self:setSoundSuppressed(false)
end

-- List event handlers

--- Called when user clicks a list row (or presses Enter on selected row)
---@param list table The SmoothList element
---@param section number Section index
---@param index number Row index (1-based)
function RmStorageCapacityDialog:onListClick(list, section, index)
    Log:debug("onListClick: section=%d, index=%d, lastSelectedIndex=%s",
        section or 0, index or 0, tostring(self.lastSelectedIndex))

    if index == nil or index < 1 or index > #self.fillTypeEntries then
        return
    end

    -- If clicking the same row that was already selected, start editing
    if self.lastSelectedIndex == index then
        local entry = self.fillTypeEntries[index]
        if entry and self:isEntryEditable(entry) then
            self:startEditing(index)
            return
        end
    end

    -- Update last selected index
    self.lastSelectedIndex = index
end

--- Called when user double-clicks a list row
---@param list table The SmoothList element
---@param section number Section index
---@param index number Row index (1-based)
function RmStorageCapacityDialog:onListDoubleClick(list, section, index)
    Log:debug("onListDoubleClick: section=%d, index=%d", section or 0, index or 0)

    if index == nil or index < 1 or index > #self.fillTypeEntries then
        return
    end

    local entry = self.fillTypeEntries[index]
    if entry and self:isEntryEditable(entry) then
        self:startEditing(index)
    end
end

-- TextInput callbacks

--- Called when Enter is pressed in the capacity input
---@param element table The TextInputElement
function RmStorageCapacityDialog:onCapacityInputEnter(element)
    Log:debug("onCapacityInputEnter")
    self:applyEditing()
end

--- Called when Escape is pressed in the capacity input
---@param element table The TextInputElement
function RmStorageCapacityDialog:onCapacityInputEscape(element)
    Log:debug("onCapacityInputEscape")
    self:cancelEditing()
end

--- Called to validate each character input (numbers only)
---@param unicode number Unicode value of the character
---@return boolean True if character is allowed
function RmStorageCapacityDialog:onCapacityIsUnicodeAllowed(unicode)
    -- Allow only digits 0-9 (unicode 48-57)
    return unicode >= 48 and unicode <= 57
end

-- Static methods

--- Sets the placeable context before showing the dialog
---@param placeable table The storage placeable to display
function RmStorageCapacityDialog.setPlaceable(placeable)
    local dialogEntry = g_gui.guis["RmStorageCapacityDialog"]
    if dialogEntry ~= nil and dialogEntry.target ~= nil then
        dialogEntry.target.placeable = placeable
    end
end

--- Registers the dialog with the GUI system
function RmStorageCapacityDialog.register()
    Log:trace("RmStorageCapacityDialog.register()")
    -- Load GUI profiles first
    g_gui:loadProfiles(RmAdjustStorageCapacity.modDirectory .. "gui/guiProfiles.xml")
    -- Then register the dialog
    local dialog = RmStorageCapacityDialog.new(g_i18n)
    g_gui:loadGui(RmAdjustStorageCapacity.modDirectory .. "gui/RmStorageCapacityDialog.xml", "RmStorageCapacityDialog", dialog)
    Log:info("RmStorageCapacityDialog registered")
end

--- Shows the dialog for a placeable
---@param placeable table The storage placeable
function RmStorageCapacityDialog.show(placeable)
    Log:trace("RmStorageCapacityDialog.show()")

    if placeable == nil then
        Log:warning("RmStorageCapacityDialog.show: placeable is nil")
        return
    end

    -- Set context before showing
    RmStorageCapacityDialog.setPlaceable(placeable)
    g_gui:showDialog("RmStorageCapacityDialog")
end
