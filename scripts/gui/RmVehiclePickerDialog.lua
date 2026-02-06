-- RmVehiclePickerDialog - Vehicle selection dialog for in-vehicle capacity adjustment
-- Author: Ritter
--
-- Shows a list of eligible vehicles (driven vehicle + attached implements) when pressing
-- K while in a vehicle. Selecting a vehicle opens the RmVehicleCapacityDialog for it.

-- Get logger for this module
local Log = RmLogging.getLogger("AdjustStorageCapacity")

---@class RmVehiclePickerDialog : MessageDialog
RmVehiclePickerDialog = {}
local RmVehiclePickerDialog_mt = Class(RmVehiclePickerDialog, MessageDialog)

RmVehiclePickerDialog.CONTROLS = {
    "vehicleList",
    "listSlider",
    "dialogTitleElement"
}

--- Creates a new RmVehiclePickerDialog instance
---@param target table|nil the target object
---@param custom_mt table|nil optional custom metatable
---@return RmVehiclePickerDialog the new dialog instance
function RmVehiclePickerDialog.new(target, custom_mt)
    ---@type RmVehiclePickerDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, custom_mt or RmVehiclePickerDialog_mt)
    self.vehicleEntries = {}
    return self
end

function RmVehiclePickerDialog:onGuiSetupFinished()
    RmVehiclePickerDialog:superClass().onGuiSetupFinished(self)
    self.vehicleList:setDataSource(self)
end

function RmVehiclePickerDialog:onCreate()
    RmVehiclePickerDialog:superClass().onCreate(self)
end

function RmVehiclePickerDialog:onOpen()
    RmVehiclePickerDialog:superClass().onOpen(self)

    -- Build list of vehicle entries
    self:refreshVehicleList()

    -- Reload the list data
    self.vehicleList:reloadData()

    -- Set focus to the list
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.vehicleList)
    self:setSoundSuppressed(false)
end

function RmVehiclePickerDialog:onClose()
    self.vehicleEntries = {}
    RmVehiclePickerDialog:superClass().onClose(self)
end

--- Refreshes the vehicle entries list
function RmVehiclePickerDialog:refreshVehicleList()
    self.vehicleEntries = {}

    local vehicles = RmVehiclePickerDialog.pendingVehicles
    if vehicles == nil then
        return
    end

    for _, vehicle in ipairs(vehicles) do
        local fillUnitInfo = RmVehicleStorageCapacity.getAllFillUnitInfo(vehicle)
        local fillUnitCount = #fillUnitInfo
        local imageFilename = vehicle.getImageFilename ~= nil and vehicle:getImageFilename() or nil

        table.insert(self.vehicleEntries, {
            vehicle = vehicle,
            name = vehicle:getName() or "Unknown",
            fillUnitCount = fillUnitCount,
            imageFilename = imageFilename
        })
    end

    Log:debug("Vehicle picker: %d entries", #self.vehicleEntries)
end

-- DataSource methods

function RmVehiclePickerDialog:getNumberOfItemsInSection(list, section)
    if list == self.vehicleList then
        return #self.vehicleEntries
    end
    return 0
end

function RmVehiclePickerDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.vehicleList then
        local entry = self.vehicleEntries[index]
        if entry then
            local iconElement = cell:getAttribute("vehicleIcon")
            local nameElement = cell:getAttribute("vehicleName")
            local infoElement = cell:getAttribute("vehicleInfo")

            -- Set vehicle store icon
            if iconElement ~= nil then
                if entry.imageFilename ~= nil and entry.imageFilename ~= "" then
                    iconElement:setImageFilename(entry.imageFilename)
                    iconElement:setVisible(true)
                else
                    iconElement:setVisible(false)
                end
            end

            -- Set vehicle name
            if nameElement ~= nil then
                nameElement:setText(entry.name)
            end

            -- Set fill unit count info
            if infoElement ~= nil then
                infoElement:setText(string.format(g_i18n:getText("rm_asc_picker_fillUnits"), entry.fillUnitCount))
            end
        end
    end
end

--- Called when a list item is clicked - opens the capacity dialog for the selected vehicle
function RmVehiclePickerDialog:onListClick(list, section, index, cell)
    if list ~= self.vehicleList then
        return
    end

    local entry = self.vehicleEntries[index]
    if entry == nil or entry.vehicle == nil then
        return
    end

    -- Permission check
    local canModify, errorKey = RmAdjustStorageCapacity:canModifyVehicleCapacity(entry.vehicle)
    if not canModify then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(errorKey)
        )
        return
    end

    Log:debug("Vehicle picker: selected %s", entry.name)

    -- Close picker and open capacity dialog for the selected vehicle
    self:close()
    RmVehicleCapacityDialog.show(entry.vehicle)
end

--- Called when close button is clicked
function RmVehiclePickerDialog:onClickClose()
    self:close()
end

-- Static methods

--- Registers the dialog with the GUI system
function RmVehiclePickerDialog.register()
    local dialog = RmVehiclePickerDialog.new(g_i18n)
    g_gui:loadGui(RmAdjustStorageCapacity.modDirectory .. "gui/RmVehiclePickerDialog.xml", "RmVehiclePickerDialog", dialog)
    Log:info("RmVehiclePickerDialog registered")
end

--- Shows the picker dialog for a list of eligible vehicles
---@param vehicles table Array of eligible vehicle objects
function RmVehiclePickerDialog.show(vehicles)
    if vehicles == nil or #vehicles == 0 then
        return
    end

    RmVehiclePickerDialog.pendingVehicles = vehicles
    g_gui:showDialog("RmVehiclePickerDialog")
end
