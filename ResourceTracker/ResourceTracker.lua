-- ResourceTracker.lua
local addonName = "ResourceTracker"
local RT = {}
_G.ResourceTracker = RT

-- Account-wide saved variables (both position and tracked items)
ResourceTrackerAccountDB = ResourceTrackerAccountDB or {}
ResourceTrackerAccountDB.anchorX = ResourceTrackerAccountDB.anchorX or 100
ResourceTrackerAccountDB.anchorY = ResourceTrackerAccountDB.anchorY or -200
ResourceTrackerAccountDB.slots = ResourceTrackerAccountDB.slots or {}
ResourceTrackerAccountDB.isLocked = ResourceTrackerAccountDB.isLocked or false
ResourceTrackerAccountDB.slotsPerRow = ResourceTrackerAccountDB.slotsPerRow or 4


-- Frame references
local mainFrame
local slots = {}
local dropdownMenu
local configDialog
local goalDialog
local optionsDialog

-- Constants
local SLOT_SIZE = 37
local SLOT_SPACING = 4
local TAB_HEIGHT = 24

-- Helper function to format numbers
local function FormatCount(count)
    if count >= 1000000 then
        return string.format("%.1fm", count / 1000000)
    elseif count >= 100000 then
        return string.format("%dk", math.floor(count / 1000))
    elseif count >= 10000 then
        return string.format("%.1fk", count / 1000)
    elseif count >= 1000 then
        return string.format("%.1fk", count / 1000)
    else
        return tostring(count)
    end
end

-- Get total count of an item across all sources
local function GetTotalItemCount(itemId)
    local total = 0
    total = GetItemCount(itemId, true)
    
    if GetCustomGameData then
        local resourceBankCount = GetCustomGameData(13, itemId)
        if resourceBankCount and type(resourceBankCount) == "number" then
            total = total + resourceBankCount
        end
    end
    
    return total
end

-- Forward declarations
local UpdateSlot
local UpdateAllSlots
local RebuildSlots
local ShowGoalDialog

-- Update a single slot's display
UpdateSlot = function(slotIndex)
    local slot = slots[slotIndex]
    if not slot then return end
    
    local data = ResourceTrackerAccountDB.slots[slotIndex]
    
    if not data or not data.id then
        -- Empty slot with green +
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.icon:SetDesaturated(true)
        slot.count:SetText("")
        slot.goalText:Hide()
        slot.checkMark:Hide()
        slot.plusSign:Show()
        return
    end
    
    slot.plusSign:Hide()
    
    -- Request item info if not cached
    local itemName, _, _, _, _, _, _, _, _, texture = GetItemInfo(data.id)
    
    if not texture then
        -- Item not in cache yet, request it and show loading state
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.icon:SetDesaturated(false)
        slot.count:SetText("...")
        slot.goalText:Hide()
        slot.checkMark:Hide()
        -- Queue this slot for retry
        if not mainFrame.pendingSlots then
            mainFrame.pendingSlots = {}
        end
        mainFrame.pendingSlots[slotIndex] = true
        return
    end
    
    -- Item is cached, display it normally
    local count = GetTotalItemCount(data.id)
    
    slot.icon:SetTexture(texture)
    slot.icon:SetDesaturated(false)
    slot.count:SetText(FormatCount(count))
    
    if data.goal then
        slot.goalText:SetText(FormatCount(data.goal))
        slot.goalText:Show()
        
        if count >= data.goal then
            slot.checkMark:Show()
        else
            slot.checkMark:Hide()
        end
    else
        slot.goalText:Hide()
        slot.checkMark:Hide()
    end
    
    -- Remove from pending list if it was there
    if mainFrame.pendingSlots then
        mainFrame.pendingSlots[slotIndex] = nil
    end
end

-- Update all slots
UpdateAllSlots = function()
    if not mainFrame then return end
    
    for i = 1, #slots do
        UpdateSlot(i)
    end
end

-- Get number of filled slots
local function GetFilledSlotCount()
    local count = 0
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            count = count + 1
        end
    end
    return count
end

-- Common validation function for item IDs
local function ValidateItemId(id)
    if not id or id <= 0 then
        return false, "|cffff0000Please enter a valid Item ID|r"
    end
    
    local itemName = GetItemInfo(id)
    if not itemName then
        return false, "|cffff0000Invalid Item ID: " .. id .. "|r"
    end
    
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id == id then
            return false, "|cffff0000Item already tracked in another slot!|r"
        end
    end
    
    return true
end

-- Common function to update dialog after validation
local function UpdateDialogAfterValidation(dialog, slotIndex)
    ResourceTrackerAccountDB.slots[slotIndex] = {
        type = "item",
        id = dialog.editBox:GetNumber()
    }
    RebuildSlots()
    dialog:Hide()
end

-- Show config dialog for a slot
local function ShowConfigDialog(slotIndex)
    if not configDialog then
        configDialog = CreateFrame("Frame", "RTConfigDialog", UIParent)
        configDialog:SetSize(280, 130)
        configDialog:SetPoint("CENTER")
        configDialog:SetFrameStrata("DIALOG")
        configDialog:EnableMouse(true)
        configDialog:SetMovable(true)
        configDialog:RegisterForDrag("LeftButton")
        configDialog:SetClampedToScreen(true)
        
        configDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        configDialog:SetBackdropColor(0, 0, 0, 0.9)
        
        configDialog.title = configDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        configDialog.title:SetPoint("TOP", 0, -15)
        configDialog.title:SetText("Enter Item ID")
        
        configDialog.editBox = CreateFrame("EditBox", "RTEditBox", configDialog, "InputBoxTemplate")
        configDialog.editBox:SetSize(200, 20)
        configDialog.editBox:SetPoint("TOP", configDialog.title, "BOTTOM", 0, -20)
        configDialog.editBox:SetAutoFocus(false)
        configDialog.editBox:SetMaxLetters(10)
        configDialog.editBox:SetNumeric(true)
        
        configDialog.editBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        
        configDialog.editBox:SetScript("OnEnterPressed", function(self)
            local id = tonumber(self:GetText())
            local isValid, errorMsg = ValidateItemId(id)
            if isValid then
                UpdateDialogAfterValidation(configDialog, configDialog.currentSlot)
            else
                print(errorMsg)
            end
        end)
        
        configDialog.okButton = CreateFrame("Button", "RTOkButton", configDialog, "UIPanelButtonTemplate")
        configDialog.okButton:SetSize(80, 22)
        configDialog.okButton:SetPoint("BOTTOM", -45, 15)
        configDialog.okButton:SetText("OK")
        configDialog.okButton:SetScript("OnClick", function()
            local id = tonumber(configDialog.editBox:GetText())
            local isValid, errorMsg = ValidateItemId(id)
            if isValid then
                UpdateDialogAfterValidation(configDialog, configDialog.currentSlot)
            else
                print(errorMsg)
            end
        end)
        
        configDialog.cancelButton = CreateFrame("Button", "RTCancelButton", configDialog, "UIPanelButtonTemplate")
        configDialog.cancelButton:SetSize(80, 22)
        configDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        configDialog.cancelButton:SetText("Cancel")
        configDialog.cancelButton:SetScript("OnClick", function()
            configDialog:Hide()
        end)
        
        configDialog:SetScript("OnDragStart", configDialog.StartMoving)
        configDialog:SetScript("OnDragStop", configDialog.StopMovingOrSizing)
        
        configDialog:Hide()
    end
    
    configDialog.currentSlot = slotIndex
    configDialog.editBox:SetText("")
    configDialog:Show()
    configDialog.editBox:SetFocus()
end

-- Show goal dialog for a slot
ShowGoalDialog = function(slotIndex)
    if not goalDialog then
        goalDialog = CreateFrame("Frame", "RTGoalDialog", UIParent)
        goalDialog:SetSize(280, 130)
        goalDialog:SetPoint("CENTER")
        goalDialog:SetFrameStrata("DIALOG")
        goalDialog:EnableMouse(true)
        goalDialog:SetMovable(true)
        goalDialog:RegisterForDrag("LeftButton")
        goalDialog:SetClampedToScreen(true)
        
        goalDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        goalDialog:SetBackdropColor(0, 0, 0, 0.9)
        
        goalDialog.title = goalDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        goalDialog.title:SetPoint("TOP", 0, -15)
        goalDialog.title:SetText("Set Goal Amount")
        
        goalDialog.editBox = CreateFrame("EditBox", "RTGoalEditBox", goalDialog, "InputBoxTemplate")
        goalDialog.editBox:SetSize(200, 20)
        goalDialog.editBox:SetPoint("TOP", goalDialog.title, "BOTTOM", 0, -20)
        goalDialog.editBox:SetAutoFocus(false)
        goalDialog.editBox:SetMaxLetters(10)
        goalDialog.editBox:SetNumeric(true)
        
        goalDialog.editBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        
        goalDialog.editBox:SetScript("OnEnterPressed", function(self)
            local goal = tonumber(self:GetText())
            if goal and goal > 0 then
                if ResourceTrackerAccountDB.slots[goalDialog.currentSlot] then
                    ResourceTrackerAccountDB.slots[goalDialog.currentSlot].goal = goal
                    UpdateSlot(goalDialog.currentSlot)
                end
                goalDialog:Hide()
            else
                print("|cffff0000Please enter a valid goal amount|r")
            end
        end)
        
        goalDialog.okButton = CreateFrame("Button", "RTGoalOkButton", goalDialog, "UIPanelButtonTemplate")
        goalDialog.okButton:SetSize(80, 22)
        goalDialog.okButton:SetPoint("BOTTOM", -45, 15)
        goalDialog.okButton:SetText("OK")
        goalDialog.okButton:SetScript("OnClick", function()
            local goal = tonumber(goalDialog.editBox:GetText())
            if goal and goal > 0 then
                if ResourceTrackerAccountDB.slots[goalDialog.currentSlot] then
                    ResourceTrackerAccountDB.slots[goalDialog.currentSlot].goal = goal
                    UpdateSlot(goalDialog.currentSlot)
                end
                goalDialog:Hide()
            else
                print("|cffff0000Please enter a valid goal amount|r")
            end
        end)
        
        goalDialog.cancelButton = CreateFrame("Button", "RTGoalCancelButton", goalDialog, "UIPanelButtonTemplate")
        goalDialog.cancelButton:SetSize(80, 22)
        goalDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        goalDialog.cancelButton:SetText("Cancel")
        goalDialog.cancelButton:SetScript("OnClick", function()
            goalDialog:Hide()
        end)
        
        goalDialog:SetScript("OnDragStart", goalDialog.StartMoving)
        goalDialog:SetScript("OnDragStop", goalDialog.StopMovingOrSizing)
        
        goalDialog:Hide()
    end
    
    goalDialog.currentSlot = slotIndex
    local data = ResourceTrackerAccountDB.slots[slotIndex]
    goalDialog.editBox:SetText(data and data.goal and tostring(data.goal) or "")
    goalDialog:Show()
    goalDialog.editBox:SetFocus()
end

local function ShowOptionsDialog()
    if not optionsDialog then
        optionsDialog = CreateFrame("Frame", "RTOptionsDialog", UIParent)
        optionsDialog:SetSize(300, 150)
        optionsDialog:SetPoint("CENTER")
        optionsDialog:SetFrameStrata("DIALOG")
        optionsDialog:EnableMouse(true)
        optionsDialog:SetMovable(true)
        optionsDialog:RegisterForDrag("LeftButton")
        optionsDialog:SetClampedToScreen(true)
        
        optionsDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        optionsDialog:SetBackdropColor(0, 0, 0, 0.9)
        
        optionsDialog.title = optionsDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        optionsDialog.title:SetPoint("TOP", 0, -15)
        optionsDialog.title:SetText("Options")
        
        optionsDialog.label = optionsDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        optionsDialog.label:SetPoint("TOP", optionsDialog.title, "BOTTOM", 0, -20)
        optionsDialog.label:SetText("Slots per row:")
        
        optionsDialog.editBox = CreateFrame("EditBox", "RTOptionsEditBox", optionsDialog, "InputBoxTemplate")
        optionsDialog.editBox:SetSize(60, 20)
        optionsDialog.editBox:SetPoint("TOP", optionsDialog.label, "BOTTOM", 0, -10)
        optionsDialog.editBox:SetAutoFocus(false)
        optionsDialog.editBox:SetMaxLetters(2)
        optionsDialog.editBox:SetNumeric(true)
        
        optionsDialog.editBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        
        optionsDialog.okButton = CreateFrame("Button", "RTOptionsOkButton", optionsDialog, "UIPanelButtonTemplate")
        optionsDialog.okButton:SetSize(80, 22)
        optionsDialog.okButton:SetPoint("BOTTOM", -45, 15)
        optionsDialog.okButton:SetText("OK")
        optionsDialog.okButton:SetScript("OnClick", function()
            local value = tonumber(optionsDialog.editBox:GetText())
            if value and value > 0 and value <= 20 then
                ResourceTrackerAccountDB.slotsPerRow = value
                RebuildSlots()
            else
                print("|cffff0000ResourceTracker: Please enter a number between 1 and 20|r")
            end
            optionsDialog:Hide()
        end)
        
        optionsDialog.cancelButton = CreateFrame("Button", "RTOptionsCancelButton", optionsDialog, "UIPanelButtonTemplate")
        optionsDialog.cancelButton:SetSize(80, 22)
        optionsDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        optionsDialog.cancelButton:SetText("Cancel")
        optionsDialog.cancelButton:SetScript("OnClick", function()
            optionsDialog:Hide()
        end)
        
        optionsDialog:SetScript("OnDragStart", optionsDialog.StartMoving)
        optionsDialog:SetScript("OnDragStop", optionsDialog.StopMovingOrSizing)
        
        optionsDialog:Hide()
    end
    
    optionsDialog.editBox:SetText(tostring(ResourceTrackerAccountDB.slotsPerRow))
    optionsDialog:Show()
    optionsDialog.editBox:SetFocus()
end

-- Create a slot button
local function CreateSlot(parent, index)
    local slot = CreateFrame("Button", "RTSlot" .. index, parent)
    slot:SetSize(SLOT_SIZE, SLOT_SIZE)
    
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints()
    slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    slot.icon:SetDesaturated(true)
    
    slot.plusSign = slot:CreateFontString(nil, "OVERLAY")
    slot.plusSign:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
    slot.plusSign:SetPoint("CENTER", 0, 0)
    slot.plusSign:SetText("+")
    slot.plusSign:SetTextColor(0, 1, 0)
    slot.plusSign:Show()
    
    slot.count = slot:CreateFontString(nil, "OVERLAY")
    slot.count:SetFont("Fonts\\ARIALN.TTF", 16, "OUTLINE")
    slot.count:SetPoint("BOTTOMRIGHT", -2, 2)
    slot.count:SetTextColor(1, 1, 1)
    
    slot.goalText = slot:CreateFontString(nil, "OVERLAY")
    slot.goalText:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    slot.goalText:SetPoint("TOPLEFT", 2, -2)
    slot.goalText:SetTextColor(1, 0.82, 0)
    slot.goalText:Hide()
    
    slot.checkMark = CreateFrame("Frame", nil, slot)
    slot.checkMark:SetAllPoints()
    slot.checkMark:SetFrameLevel(slot:GetFrameLevel() + 1)
    slot.checkMark:Hide()
    
    slot.checkMark.texture = slot.checkMark:CreateTexture(nil, "OVERLAY")
    slot.checkMark.texture:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    slot.checkMark.texture:SetPoint("CENTER", 0, 0)
    slot.checkMark.texture:SetSize(SLOT_SIZE * 0.95, SLOT_SIZE * 0.95)
    slot.checkMark.texture:SetVertexColor(0, 1, 0, 1.0)
    
    slot.checkMark.shadow = slot.checkMark:CreateTexture(nil, "ARTWORK")
    slot.checkMark.shadow:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    slot.checkMark.shadow:SetPoint("CENTER", 1, -1)
    slot.checkMark.shadow:SetSize(SLOT_SIZE * 0.95, SLOT_SIZE * 0.95)
    slot.checkMark.shadow:SetVertexColor(0, 0, 0, 0.5)
    
    slot:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            ShowConfigDialog(index)
        elseif button == "RightButton" then
            local data = ResourceTrackerAccountDB.slots[index]
            if data and data.id then
                if not dropdownMenu then
                    dropdownMenu = CreateFrame("Frame", "RTDropdownMenu", UIParent, "UIDropDownMenuTemplate")
                end
                
                local menuList = {
                    {
                        text = "Add Goal",
                        func = function()
                            ShowGoalDialog(index)
                        end,
                        notCheckable = true
                    },
                    {
                        text = "Clear Slot",
                        func = function()
                            ResourceTrackerAccountDB.slots[index] = nil
                            RebuildSlots()
                        end,
                        notCheckable = true
                    },
                    {
                        text = "Cancel",
                        func = function() end,
                        notCheckable = true
                    }
                }
                EasyMenu(menuList, dropdownMenu, "cursor", 0, 0, "MENU")
            end
        end
    end)
    
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    return slot
end

-- Rebuild all slots based on current data
RebuildSlots = function()
    if not mainFrame then return end
    
    for i = 1, #slots do
        slots[i]:Hide()
        slots[i]:ClearAllPoints()
    end
    
    local consolidated = {}
    local sortedIndices = {}
    
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            table.insert(sortedIndices, i)
        end
    end
    table.sort(sortedIndices)
    
    for newIndex, oldIndex in ipairs(sortedIndices) do
        consolidated[newIndex] = ResourceTrackerAccountDB.slots[oldIndex]
    end
    
    ResourceTrackerAccountDB.slots = consolidated
    
    local filledCount = 0
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            filledCount = filledCount + 1
        end
    end
    
    local totalSlots = filledCount + 1
    
    for i = 1, totalSlots do
        if not slots[i] then
            slots[i] = CreateSlot(mainFrame, i)
        end
    end
    
    local slotsPerRow = ResourceTrackerAccountDB.slotsPerRow or 4
    
    for i = 1, totalSlots do
        local slot = slots[i]
        local row = math.floor((i - 1) / slotsPerRow)
        local col = (i - 1) % slotsPerRow
        
        slot:ClearAllPoints()
        slot:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 
            col * (SLOT_SIZE + SLOT_SPACING),
            -(TAB_HEIGHT + row * (SLOT_SIZE + SLOT_SPACING)))
        slot:SetParent(mainFrame)
        slot:Show()
        
        UpdateSlot(i)
    end
    
    if mainFrame.tab and slots[1] then
        mainFrame.tab:ClearAllPoints()
        mainFrame.tab:SetPoint("BOTTOMLEFT", slots[1], "TOPLEFT", -1, 0)
    end
    
    for i = 1, totalSlots do
        if slots[i]:IsShown() then
            slots[i]:SetScript("OnEnter", function(self)
                mainFrame.tab:Show()
                local data = ResourceTrackerAccountDB.slots[i]
                if data and data.id then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink("item:" .. data.id)
                    GameTooltip:Show()
                end
            end)
            
            slots[i]:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
                mainFrame.tabHideTimer = 0.1
            end)
        end
    end
end

-- Save frame position to account-wide saved variables
local function SaveFramePosition()
    if not mainFrame then 
        return 
    end
    
    local left, top = mainFrame:GetLeft(), mainFrame:GetTop()
    if left and top then
        ResourceTrackerAccountDB.anchorX = math.floor(left * 100 + 0.5) / 100
        ResourceTrackerAccountDB.anchorY = math.floor((top - UIParent:GetHeight()) * 100 + 0.5) / 100
    end
end

-- Load frame position from account-wide saved variables
local function LoadFramePosition()
    if not mainFrame then return end
    
    mainFrame:ClearAllPoints()
    local x = type(ResourceTrackerAccountDB.anchorX) == "number" and ResourceTrackerAccountDB.anchorX or 100
    local y = type(ResourceTrackerAccountDB.anchorY) == "number" and ResourceTrackerAccountDB.anchorY or -200
    mainFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
end

-- Force save position after a delay
local positionSaveFrame = CreateFrame("Frame")
positionSaveFrame.delay = 0
positionSaveFrame.func = nil

positionSaveFrame:SetScript("OnUpdate", function(self, elapsed)
    if self.delay > 0 then
        self.delay = self.delay - elapsed
        if self.delay <= 0 then
            if self.func then
                self.func()
                self.func = nil
            end
            self:Hide()
        end
    end
end)

-- Function to save position with a delay
local function SavePositionDelayed(func, delay)
    positionSaveFrame.func = func
    positionSaveFrame.delay = delay or 0.1
    positionSaveFrame:Show()
end

-- Create main frame
local function CreateMainFrame()
    mainFrame = CreateFrame("Frame", "ResourceTrackerFrame", UIParent)
    mainFrame:SetSize(SLOT_SIZE, TAB_HEIGHT)
    
    LoadFramePosition()
    
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetClampedToScreen(true)
    
    mainFrame.isLocked = ResourceTrackerAccountDB.isLocked or false
    
    mainFrame:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing()
        SaveFramePosition()
    end)
    
    slots[1] = CreateSlot(mainFrame, 1)
    slots[1]:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -TAB_HEIGHT)
    
    mainFrame.tab = CreateFrame("Frame", nil, mainFrame)
    mainFrame.tab:SetSize(SLOT_SIZE + 2, TAB_HEIGHT)
    mainFrame.tab:SetPoint("BOTTOMLEFT", slots[1], "TOPLEFT", -1, 0)
    mainFrame.tab:Hide()
    
    mainFrame.tab.bgLeft = mainFrame.tab:CreateTexture(nil, "BACKGROUND")
    mainFrame.tab.bgLeft:SetTexture("Interface\\ChatFrame\\ChatFrameTab-BGLeft")
    mainFrame.tab.bgLeft:SetPoint("LEFT", 0, 0)
    mainFrame.tab.bgLeft:SetSize((SLOT_SIZE + 2) / 3, TAB_HEIGHT)
    
    mainFrame.tab.bgMid = mainFrame.tab:CreateTexture(nil, "BACKGROUND")
    mainFrame.tab.bgMid:SetTexture("Interface\\ChatFrame\\ChatFrameTab-BGMid")
    mainFrame.tab.bgMid:SetPoint("LEFT", mainFrame.tab.bgLeft, "RIGHT", 0, 0)
    mainFrame.tab.bgMid:SetSize((SLOT_SIZE + 2) / 3, TAB_HEIGHT)
    
    mainFrame.tab.bgRight = mainFrame.tab:CreateTexture(nil, "BACKGROUND")
    mainFrame.tab.bgRight:SetTexture("Interface\\ChatFrame\\ChatFrameTab-BGRight")
    mainFrame.tab.bgRight:SetPoint("LEFT", mainFrame.tab.bgMid, "RIGHT", 0, 0)
    mainFrame.tab.bgRight:SetSize((SLOT_SIZE + 2) / 3, TAB_HEIGHT)
    
    mainFrame.tab.text = mainFrame.tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mainFrame.tab.text:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    mainFrame.tab.text:SetPoint("CENTER", 0, -2)
    mainFrame.tab.text:SetText("Move")
    mainFrame.tab.text:SetTextColor(0.75, 0.61, 0.43)
    
    mainFrame.tab:EnableMouse(true)
    mainFrame.tab:RegisterForDrag("LeftButton")
    mainFrame.isDragging = false
    
    mainFrame.tab:SetScript("OnDragStart", function(self)
        if not mainFrame.isLocked then
            mainFrame.isDragging = true
            mainFrame:StartMoving()
        end
    end)
    mainFrame.tab:SetScript("OnDragStop", function(self)
        mainFrame.isDragging = false
        mainFrame:StopMovingOrSizing()
        SaveFramePosition()
    end)
    
    mainFrame.tab:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            if not dropdownMenu then
                dropdownMenu = CreateFrame("Frame", "RTDropdownMenu", UIParent, "UIDropDownMenuTemplate")
            end
            
            local menuList = {
                {
                    text = mainFrame.isLocked and "Unlock Bar" or "Lock Bar",
                    func = function()
                        mainFrame.isLocked = not mainFrame.isLocked
                        ResourceTrackerAccountDB.isLocked = mainFrame.isLocked
                    end,
                    notCheckable = true
                },
                {
                    text = "Options",
                    func = function()
                        ShowOptionsDialog()
                    end,
                    notCheckable = true
                },
                {
                    text = "Cancel",
                    func = function() end,
                    notCheckable = true
                }
            }
            EasyMenu(menuList, dropdownMenu, "cursor", 0, 0, "MENU")
        end
    end)
    
    mainFrame.tab:SetScript("OnLeave", function(self)
        mainFrame.tabHideTimer = 0.1
    end)
    
    mainFrame.tabHideTimer = 0
    mainFrame:SetScript("OnUpdate", function(self, elapsed)
        if self.tabHideTimer > 0 then
            self.tabHideTimer = self.tabHideTimer - elapsed
            if self.tabHideTimer <= 0 then
                self.tabHideTimer = 0
                if not self.isDragging then
                    if not self.tab:IsMouseOver() then
                        local mouseOverSlot = false
                        for j = 1, #slots do
                            if slots[j]:IsShown() and slots[j]:IsMouseOver() then
                                mouseOverSlot = true
                                break
                            end
                        end
                        if not mouseOverSlot then
                            self.tab:Hide()
                        end
                    end
                end
            end
        end
    end)
    
    return mainFrame
end

-- Event handler
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

-- Separate update timer
local updateTimer = 0
local pendingRetryTimer = 0
local updateFrame = CreateFrame("Frame")
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    updateTimer = updateTimer + elapsed
    if updateTimer >= 2 then
        updateTimer = 0
        UpdateAllSlots()
    end
    
    -- Retry pending slots more frequently
    pendingRetryTimer = pendingRetryTimer + elapsed
    if pendingRetryTimer >= 0.5 then
        pendingRetryTimer = 0
        if mainFrame and mainFrame.pendingSlots then
            for slotIndex, _ in pairs(mainFrame.pendingSlots) do
                UpdateSlot(slotIndex)
            end
        end
    end
end)

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if not ResourceTrackerAccountDB.slotsPerRow then
            ResourceTrackerAccountDB.slotsPerRow = 4
        end
        if not ResourceTrackerAccountDB.slots then
            ResourceTrackerAccountDB.slots = {}
        end
        
        if not ResourceTrackerAccountDB.anchorX then
            ResourceTrackerAccountDB.anchorX = 100
            ResourceTrackerAccountDB.anchorY = -200
        end
        
        CreateMainFrame()
        RebuildSlots()
        
        SavePositionDelayed(function()
            LoadFramePosition()
        end, 0.5)
    elseif event == "PLAYER_ENTERING_WORLD" then
        RebuildSlots()
        SavePositionDelayed(function()
            LoadFramePosition()
        end, 0.5)
    elseif event == "BAG_UPDATE" or event == "CURRENCY_DISPLAY_UPDATE" then
        UpdateAllSlots()
    elseif event == "PLAYER_LOGOUT" then
        SaveFramePosition()
    end
end)

print("|cff00ff00ResourceTracker loaded! Drag the frame to move it.|r")