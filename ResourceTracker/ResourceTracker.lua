-- ResourceTracker.lua
local addonName = "ResourceTracker"
local RT = {}
_G.ResourceTracker = RT

-- Account-wide saved variables
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
local PENDING_TIMEOUT = 10
local POLLING_TIMEOUT = 10
local POLLING_INTERVAL = 1.0

-- Saved item counts (to detect changes)
local savedCounts = {}

-- Item info cache
local itemCache = {}

-- Session tracking
local hasLoadedOnce = false

-- Cache API availability (checked once at load)
local hasResourceBankAPI = false

-- Reusable tables for consolidation (avoid GC pressure)
local consolidationTemp = {}
local sortedIndicesTemp = {}

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

-- Cached GetItemInfo
local function GetCachedItemInfo(id)
    if not itemCache[id] then
        local name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture = GetItemInfo(id)
        if texture then  -- Only cache if successfully retrieved
            itemCache[id] = {name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture}
        else
            return nil  -- Not cached yet
        end
    end
    return unpack(itemCache[id])
end

-- Get total count of an item across all sources (optimized)
local function GetTotalItemCount(itemId)
    local total = GetItemCount(itemId, true)
    
    if hasResourceBankAPI then
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
local UpdateSlotPositions
local ShowGoalDialog
local CleanupStaleData

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
    
    -- Request item info using cached version
    local itemName, _, _, _, _, _, _, _, _, texture = GetCachedItemInfo(data.id)
    
    if not texture then
        -- Item not in cache yet, request it and show loading state
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.icon:SetDesaturated(false)
        slot.count:SetText("...")
        slot.goalText:Hide()
        slot.checkMark:Hide()
        -- Queue this slot for retry with timestamp
        if not mainFrame.pendingSlots then
            mainFrame.pendingSlots = {}
        end
        mainFrame.pendingSlots[slotIndex] = GetTime()
        return
    end
    
    -- Item is cached, display it normally
    local count = GetTotalItemCount(data.id)
    
    -- Save the count
    savedCounts[data.id] = count
    
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

-- Clean up stale data from memory (optimized single-pass)
CleanupStaleData = function()
    -- Single pass: check each saved/polled item against current slots
    for itemId in pairs(savedCounts) do
        local isTracked = false
        for _, data in pairs(ResourceTrackerAccountDB.slots) do
            if data and data.id == itemId then
                isTracked = true
                break
            end
        end
        if not isTracked then
            savedCounts[itemId] = nil
            pollingItems[itemId] = nil
        end
    end
    
    -- Check pollingItems for any that aren't in savedCounts
    for itemId in pairs(pollingItems) do
        if not savedCounts[itemId] then
            pollingItems[itemId] = nil
        end
    end
end

-- Common validation function for item IDs
local function ValidateItemId(id)
    if not id or id <= 0 then
        return false, "|cffff0000Please enter a valid Item ID|r"
    end
    
    local itemName = GetCachedItemInfo(id)
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

-- Common function to update dialog after validation (optimized - no rebuild)
local function UpdateDialogAfterValidation(dialog, slotIndex)
    local itemId = dialog.editBox:GetNumber()
    ResourceTrackerAccountDB.slots[slotIndex] = {
        type = "item",
        id = itemId
    }
    
    -- Only update this specific slot and save its count (no full rebuild)
    savedCounts[itemId] = GetTotalItemCount(itemId)
    
    -- If adding to a new slot position, we may need to add the empty slot after it
    local filledCount = 0
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            filledCount = filledCount + 1
        end
    end
    
    local totalSlots = filledCount + 1
    if totalSlots > #slots then
        -- Need to create a new slot
        slots[totalSlots] = CreateSlot(mainFrame, totalSlots)
    end
    
    -- Reposition slots (lightweight - no count queries)
    UpdateSlotPositions()
    
    -- Update only the new slot
    UpdateSlot(slotIndex)
    
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

-- Show options dialog
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
                -- Just reposition, no need to rebuild counts
                UpdateSlotPositions()
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

-- Slot OnEnter handler (created once, reused)
local function Slot_OnEnter(self)
    mainFrame.tab:Show()
    local data = ResourceTrackerAccountDB.slots[self.slotIndex]
    if data and data.id then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. data.id)
        GameTooltip:Show()
    end
end

-- Slot OnLeave handler (created once, reused)
local function Slot_OnLeave(self)
    GameTooltip:Hide()
    mainFrame.tabHideTimer = 0.1
end

-- Create a slot button
local function CreateSlot(parent, index)
    local slot = CreateFrame("Button", "RTSlot" .. index, parent)
    slot:SetSize(SLOT_SIZE, SLOT_SIZE)
    slot.slotIndex = index  -- Store index for tooltip handlers
    
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
                            local clearedItemId = ResourceTrackerAccountDB.slots[index].id
                            ResourceTrackerAccountDB.slots[index] = nil
                            -- Stop polling this item if it was being polled
                            if clearedItemId then
                                pollingItems[clearedItemId] = nil
                            end
                            -- Must do full rebuild on slot deletion (consolidation needed)
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
    
    -- Set tooltip handlers once (not recreated on rebuild)
    slot:SetScript("OnEnter", Slot_OnEnter)
    slot:SetScript("OnLeave", Slot_OnLeave)
    
    return slot
end

-- Lightweight slot repositioning (no count queries)
UpdateSlotPositions = function()
    if not mainFrame then return end
    
    -- Count filled slots
    local filledCount = 0
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            filledCount = filledCount + 1
        end
    end
    
    local totalSlots = filledCount + 1
    local slotsPerRow = ResourceTrackerAccountDB.slotsPerRow or 4
    
    -- Hide extra slots if we have too many
    for i = totalSlots + 1, #slots do
        slots[i]:Hide()
    end
    
    -- Position and show needed slots
    for i = 1, totalSlots do
        if not slots[i] then
            slots[i] = CreateSlot(mainFrame, i)
        end
        
        local slot = slots[i]
        slot.slotIndex = i
        
        local row = math.floor((i - 1) / slotsPerRow)
        local col = (i - 1) % slotsPerRow
        
        slot:ClearAllPoints()
        slot:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 
            col * (SLOT_SIZE + SLOT_SPACING),
            -(TAB_HEIGHT + row * (SLOT_SIZE + SLOT_SPACING)))
        slot:SetParent(mainFrame)
        slot:Show()
    end
    
    -- Position tab
    if mainFrame.tab and slots[1] then
        mainFrame.tab:ClearAllPoints()
        mainFrame.tab:SetPoint("BOTTOMLEFT", slots[1], "TOPLEFT", -1, 0)
    end
end

-- Rebuild all slots (full consolidation + count refresh)
RebuildSlots = function()
    if not mainFrame then return end
    
    -- Clean up stale data first
    CleanupStaleData()
    
    -- Clear reusable tables
    for k in pairs(consolidationTemp) do
        consolidationTemp[k] = nil
    end
    for k in pairs(sortedIndicesTemp) do
        sortedIndicesTemp[k] = nil
    end
    
    -- Consolidate slots (remove gaps)
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            table.insert(sortedIndicesTemp, i)
        end
    end
    table.sort(sortedIndicesTemp)
    
    for newIndex, oldIndex in ipairs(sortedIndicesTemp) do
        consolidationTemp[newIndex] = ResourceTrackerAccountDB.slots[oldIndex]
    end
    
    ResourceTrackerAccountDB.slots = consolidationTemp
    -- Create new reference (old one is now saved)
    consolidationTemp = {}
    
    -- Rebuild savedCounts to match current slots
    savedCounts = {}
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            savedCounts[data.id] = GetTotalItemCount(data.id)
        end
    end
    
    -- Reposition slots
    UpdateSlotPositions()
    
    -- Update all slot displays
    UpdateAllSlots()
end

-- Save frame position
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

-- Load frame position
local function LoadFramePosition()
    if not mainFrame then return end
    
    mainFrame:ClearAllPoints()
    local x = type(ResourceTrackerAccountDB.anchorX) == "number" and ResourceTrackerAccountDB.anchorX or 100
    local y = type(ResourceTrackerAccountDB.anchorY) == "number" and ResourceTrackerAccountDB.anchorY or -200
    mainFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
end

-- Delayed position save frame (reused)
local positionSaveFrame = CreateFrame("Frame")
positionSaveFrame.delay = 0
positionSaveFrame.func = nil
positionSaveFrame:Hide()

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
    mainFrame.isDragging = false
    
    -- Make tab draggable by propagating to mainFrame
    mainFrame.tab:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not mainFrame.isLocked then
            mainFrame.isDragging = true
            mainFrame:StartMoving()
        end
    end)
    
    mainFrame.tab:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and mainFrame.isDragging then
            mainFrame.isDragging = false
            mainFrame:StopMovingOrSizing()
            SaveFramePosition()
        elseif button == "RightButton" then
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
        
        -- Handle pending slots with timeout
        if self.pendingSlots then
            local currentTime = GetTime()
            for slotIndex, startTime in pairs(self.pendingSlots) do
                if currentTime - startTime > PENDING_TIMEOUT then
                    -- Timeout reached, stop retrying
                    self.pendingSlots[slotIndex] = nil
                else
                    -- Try to update again
                    UpdateSlot(slotIndex)
                end
            end
        end
    end)
    
    return mainFrame
end

-- Polling system for waiting on server updates
pollingItems = {}
local pollingFrame = CreateFrame("Frame")
pollingFrame:Hide()
pollingFrame:SetScript("OnUpdate", function(self, elapsed)
    local currentTime = GetTime()
    
    for itemId, pollData in pairs(pollingItems) do
        pollData.timer = pollData.timer + elapsed
        pollData.totalTime = pollData.totalTime + elapsed
        
        -- Stop polling after timeout
        if pollData.totalTime >= POLLING_TIMEOUT then
            pollingItems[itemId] = nil
        elseif pollData.timer >= POLLING_INTERVAL then
            pollData.timer = 0
            local currentCount = GetTotalItemCount(itemId)
            
            if currentCount ~= pollData.oldCount then
                -- Value changed! Update only this item's slot and stop polling
                savedCounts[itemId] = currentCount
                
                -- Find and update the slot for this item
                for slotIndex, data in pairs(ResourceTrackerAccountDB.slots) do
                    if data and data.id == itemId then
                        UpdateSlot(slotIndex)
                        break
                    end
                end
                
                pollingItems[itemId] = nil
            end
        end
    end
    
    -- Hide frame if no more items to poll
    local hasItems = false
    for _ in pairs(pollingItems) do
        hasItems = true
        break
    end
    if not hasItems then
        self:Hide()
    end
end)

-- Event handler
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Cache resource bank API availability (checked once)
        hasResourceBankAPI = (GetCustomGameData ~= nil)
        
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
        -- CRITICAL FIX: Only trigger on first login/reload, not zone changes
        if not hasLoadedOnce then
            hasLoadedOnce = true
            
            -- Condition #1: Player logging in - update all slots and save counts
            -- Delay to let resource bank API become ready
            SavePositionDelayed(function()
                LoadFramePosition()
                -- Update all tracked items and save their counts
                UpdateAllSlots()
            end, 1.0)
        end
        
    elseif event == "CHAT_MSG_LOOT" then
        -- Condition #3: Loot message - OPTIMIZED with item ID extraction
        local lootText = arg1
        
        -- Extract item ID from loot link (faster and locale-safe)
        local lootedItemId = tonumber(lootText:match("item:(%d+)"))
        
        if lootedItemId then
            -- Check if this item is tracked
            for slotIndex, data in pairs(ResourceTrackerAccountDB.slots) do
                if data and data.id == lootedItemId then
                    -- Found a match! Check if value updated yet
                    local currentCount = GetTotalItemCount(lootedItemId)
                    local oldCount = savedCounts[lootedItemId] or 0
                    
                    if currentCount ~= oldCount then
                        -- Value already changed, update and save
                        savedCounts[lootedItemId] = currentCount
                        UpdateSlot(slotIndex)
                    else
                        -- Value hasn't changed yet, start polling
                        if not pollingItems[lootedItemId] then
                            pollingItems[lootedItemId] = {
                                slotIndex = slotIndex,
                                oldCount = oldCount,
                                timer = 0,
                                totalTime = 0
                            }
                            pollingFrame:Show()
                        end
                    end
                    
                    -- Only update the specific slot that was looted
                    break
                end
            end
        end
        
    elseif event == "PLAYER_LOGOUT" then
        SaveFramePosition()
    end
end)

print("|cff00ff00ResourceTracker loaded! Drag the frame to move it.|r")
