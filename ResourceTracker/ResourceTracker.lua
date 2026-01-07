local addonName = "ResourceTracker"
local RT = {}
_G.ResourceTracker = RT

ResourceTrackerAccountDB = ResourceTrackerAccountDB or {}
ResourceTrackerAccountDB.anchorX = ResourceTrackerAccountDB.anchorX or 100
ResourceTrackerAccountDB.anchorY = ResourceTrackerAccountDB.anchorY or -200
ResourceTrackerAccountDB.slots = ResourceTrackerAccountDB.slots or {}
ResourceTrackerAccountDB.isLocked = ResourceTrackerAccountDB.isLocked or false
ResourceTrackerAccountDB.slotsPerRow = ResourceTrackerAccountDB.slotsPerRow or 4
ResourceTrackerAccountDB.knownRecipes = ResourceTrackerAccountDB.knownRecipes or {}

local mainFrame, dropdownMenu, configDialog, goalDialog, optionsDialog, reagentDialog, recipePromptDialog, clearAllDialog
local slots = {}
local savedCounts = {}
local itemCache = {}
local pollingItems = {}
local addQueue = {}
local isProcessingQueue = false
local currentQueueItem = nil
local hasLoadedOnce = false
local hasResourceBankAPI = false

local SLOT_SIZE = 37
local SLOT_SPACING = 4
local TAB_HEIGHT = 24
local PENDING_TIMEOUT = 10
local POLLING_TIMEOUT = 10
local POLLING_INTERVAL = 1.0

local PROFESSIONS = {
    "Alchemy", "Blacksmithing", "Enchanting", "Engineering",
    "Inscription", "Jewelcrafting", "Leatherworking", "Mining",
    "Tailoring", "Cooking", "First Aid"
}

local RECIPE_BLACKLIST = {
    [35622] = true, [35623] = true, [35624] = true, [35625] = true,
    [35627] = true, [36860] = true, [21884] = true, [21885] = true,
    [21886] = true, [22451] = true, [22452] = true, [22456] = true,
    [22457] = true, [22573] = true, [22574] = true, [7076] = true,
    [7078] = true, [7080] = true, [7082] = true, [12803] = true,
    [12808] = true
}

local ELEMENTAL_CONVERSIONS = {
    [35622] = {component = 37705, count = 10},
    [35623] = {component = 37700, count = 10},
    [35624] = {component = 37701, count = 10},
    [35625] = {component = 37704, count = 10},
    [35627] = {component = 37703, count = 10},
    [36860] = {component = 37702, count = 10},
    [21884] = {component = 22574, count = 10},
    [21885] = {component = 22578, count = 10},
    [21886] = {component = 22575, count = 10},
    [22451] = {component = 22572, count = 10},
    [22452] = {component = 22573, count = 10},
    [22456] = {component = 22577, count = 10},
    [22457] = {component = 22576, count = 10}
}

local function FormatCount(count)
    if count >= 1000000 then
        return string.format("%.1fm", count / 1000000)
    elseif count >= 10000 then
        return string.format("%.1fk", count / 1000)
    elseif count >= 1000 then
        return string.format("%.1fk", count / 1000)
    else
        return tostring(count)
    end
end

local function GetCachedItemInfo(id)
    if not itemCache[id] then
        local name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture = GetItemInfo(id)
        if texture then
            itemCache[id] = {name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture}
        else
            return nil
        end
    end
    return unpack(itemCache[id])
end

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

local function GetItemIdFromLink(link)
    if not link then return nil end
    local itemId = link:match("item:(%d+)")
    return tonumber(itemId)
end

local function ScanTradeSkillRecipes(professionName)
    if not professionName then return end
    local recipesData = {}
    local numSkills = GetNumTradeSkills()
    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" then
            local link = GetTradeSkillItemLink(i)
            if link then
                local recipeItemId = GetItemIdFromLink(link)
                if recipeItemId then
                    local reagents = {}
                    local numReagents = GetTradeSkillNumReagents(i)
                    for r = 1, numReagents do
                        local reagentLink = GetTradeSkillReagentItemLink(i, r)
                        local _, _, reagentCount = GetTradeSkillReagentInfo(i, r)
                        local reagentId = GetItemIdFromLink(reagentLink)
                        if reagentId and reagentCount then
                            table.insert(reagents, {id = reagentId, count = reagentCount})
                        end
                    end
                    recipesData[recipeItemId] = {name = skillName, reagents = reagents}
                end
            end
        end
    end
    ResourceTrackerAccountDB.knownRecipes[professionName] = recipesData
end

local function GetMissingProfessions()
    local missing = {}
    for _, prof in ipairs(PROFESSIONS) do
        if not ResourceTrackerAccountDB.knownRecipes[prof] or not next(ResourceTrackerAccountDB.knownRecipes[prof]) then
            table.insert(missing, prof)
        end
    end
    return missing
end

local function ShowRecipePrompt(missingProfessions)
    if not recipePromptDialog then
        recipePromptDialog = CreateFrame("Frame", "RTRecipePromptDialog", UIParent)
        recipePromptDialog:SetSize(360, 280)
        recipePromptDialog:SetPoint("CENTER")
        recipePromptDialog:SetFrameStrata("DIALOG")
        recipePromptDialog:EnableMouse(true)
        recipePromptDialog:SetMovable(true)
        recipePromptDialog:RegisterForDrag("LeftButton")
        recipePromptDialog:SetClampedToScreen(true)
        recipePromptDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        recipePromptDialog:SetBackdropColor(0, 0, 0, 0.9)
        recipePromptDialog.title = recipePromptDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        recipePromptDialog.title:SetPoint("TOP", 0, -15)
        recipePromptDialog.title:SetText("Recipe Data Needed")
        recipePromptDialog.text = recipePromptDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        recipePromptDialog.text:SetPoint("TOP", recipePromptDialog.title, "BOTTOM", 0, -15)
        recipePromptDialog.text:SetWidth(320)
        recipePromptDialog.text:SetJustifyH("LEFT")
        recipePromptDialog.okButton = CreateFrame("Button", nil, recipePromptDialog, "UIPanelButtonTemplate")
        recipePromptDialog.okButton:SetSize(80, 22)
        recipePromptDialog.okButton:SetPoint("BOTTOM", 0, 15)
        recipePromptDialog.okButton:SetText("OK")
        recipePromptDialog.okButton:SetScript("OnClick", function() recipePromptDialog:Hide() end)
        recipePromptDialog:SetScript("OnDragStart", recipePromptDialog.StartMoving)
        recipePromptDialog:SetScript("OnDragStop", recipePromptDialog.StopMovingOrSizing)
        recipePromptDialog:Hide()
    end
    local promptText = "Please open the following profession windows to cache recipe data:\n\n"
    for i, prof in ipairs(missingProfessions) do
        promptText = promptText .. "  " .. prof .. "\n"
    end
    recipePromptDialog.text:SetText(promptText)
    recipePromptDialog:Show()
end

local function CheckRecipeDataAndPrompt()
    local missing = GetMissingProfessions()
    if #missing > 0 then
        ShowRecipePrompt(missing)
    end
end

local function FindRecipeForItem(itemId)
    if not itemId or RECIPE_BLACKLIST[itemId] then return nil end
    for profName, recipes in pairs(ResourceTrackerAccountDB.knownRecipes) do
        if recipes[itemId] then
            return recipes[itemId].reagents
        end
    end
    return nil
end

local UpdateSlot, UpdateAllSlots, RebuildSlots, UpdateSlotPositions, ShowGoalDialog
local AddItemToSlot, QueueItemAdd, ProcessNextQueueItem, CreateSlot, ShowReagentDialog, ShowElementalDialog, ShowClearAllDialog

local function CleanupStaleData()
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
end

AddItemToSlot = function(itemId, slotIndex, goalAmount)
    for existingSlot, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id == itemId then
            if goalAmount and goalAmount > 0 then
                ResourceTrackerAccountDB.slots[existingSlot].goal = (data.goal or 0) + goalAmount
                UpdateSlot(existingSlot)
            end
            return
        end
    end
    if not slotIndex then
        slotIndex = 1
        for i, data in pairs(ResourceTrackerAccountDB.slots) do
            if data and data.id then
                slotIndex = math.max(slotIndex, i + 1)
            end
        end
    end
    ResourceTrackerAccountDB.slots[slotIndex] = {type = "item", id = itemId, goal = goalAmount}
    savedCounts[itemId] = GetTotalItemCount(itemId)
    local filledCount = 0
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then
            filledCount = filledCount + 1
        end
    end
    local totalSlots = filledCount + 1
    if totalSlots > #slots then
        slots[totalSlots] = CreateSlot(mainFrame, totalSlots)
    end
    UpdateSlotPositions()
    UpdateSlot(slotIndex)
end

QueueItemAdd = function(itemId, slotIndex, goalAmount)
    table.insert(addQueue, {itemId = itemId, slotIndex = slotIndex, goalAmount = goalAmount})
    if not isProcessingQueue then
        ProcessNextQueueItem()
    end
end

ProcessNextQueueItem = function()
    if #addQueue == 0 then
        isProcessingQueue = false
        currentQueueItem = nil
        return
    end
    isProcessingQueue = true
    currentQueueItem = table.remove(addQueue, 1)
    local elementalConversion = ELEMENTAL_CONVERSIONS[currentQueueItem.itemId]
    if elementalConversion then
        ShowElementalDialog(currentQueueItem.itemId, elementalConversion)
        return
    end
    local reagents = FindRecipeForItem(currentQueueItem.itemId)
    if reagents and #reagents > 0 then
        ShowReagentDialog(currentQueueItem.itemId, reagents)
    else
        AddItemToSlot(currentQueueItem.itemId, currentQueueItem.slotIndex, currentQueueItem.goalAmount)
        ProcessNextQueueItem()
    end
end
ShowReagentDialog = function(craftedItemId, reagents)
    if not reagentDialog then
        reagentDialog = CreateFrame("Frame", "RTReagentDialog", UIParent)
        reagentDialog:SetSize(340, 280)
        reagentDialog:SetPoint("CENTER")
        reagentDialog:SetFrameStrata("DIALOG")
        reagentDialog:EnableMouse(true)
        reagentDialog:SetMovable(true)
        reagentDialog:RegisterForDrag("LeftButton")
        reagentDialog:SetClampedToScreen(true)
        reagentDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        reagentDialog:SetBackdropColor(0, 0, 0, 0.9)
        reagentDialog.title = reagentDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        reagentDialog.title:SetPoint("TOP", 0, -15)
        reagentDialog.text = reagentDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        reagentDialog.text:SetPoint("TOP", reagentDialog.title, "BOTTOM", 0, -15)
        reagentDialog.text:SetWidth(300)
        reagentDialog.text:SetJustifyH("LEFT")
        reagentDialog.scrollFrame = CreateFrame("ScrollFrame", nil, reagentDialog)
        reagentDialog.scrollFrame:SetSize(300, 150)
        reagentDialog.scrollFrame:SetPoint("TOP", reagentDialog.text, "BOTTOM", 0, -10)
        reagentDialog.scrollChild = CreateFrame("Frame", nil, reagentDialog.scrollFrame)
        reagentDialog.scrollChild:SetSize(280, 1)
        reagentDialog.scrollFrame:SetScrollChild(reagentDialog.scrollChild)
        reagentDialog.checkboxes = {}
        reagentDialog.yesButton = CreateFrame("Button", nil, reagentDialog, "UIPanelButtonTemplate")
        reagentDialog.yesButton:SetSize(80, 22)
        reagentDialog.yesButton:SetPoint("BOTTOM", -45, 15)
        reagentDialog.yesButton:SetText("Yes")
        reagentDialog.noButton = CreateFrame("Button", nil, reagentDialog, "UIPanelButtonTemplate")
        reagentDialog.noButton:SetSize(80, 22)
        reagentDialog.noButton:SetPoint("BOTTOM", 45, 15)
        reagentDialog.noButton:SetText("No")
        reagentDialog:SetScript("OnDragStart", reagentDialog.StartMoving)
        reagentDialog:SetScript("OnDragStop", reagentDialog.StopMovingOrSizing)
        reagentDialog:Hide()
    end
    reagentDialog:SetSize(340, 280)
    reagentDialog.title:SetText("Add Reagents?")
    if reagentDialog.scrollFrame then reagentDialog.scrollFrame:Show() end
    for _, cb in ipairs(reagentDialog.checkboxes) do cb:Hide() end
    local itemName = GetCachedItemInfo(craftedItemId) or ("Item " .. craftedItemId)
    reagentDialog.text:SetText(itemName .. " requires:")
    for i, reagent in ipairs(reagents) do
        if not reagentDialog.checkboxes[i] then
            local cb = CreateFrame("CheckButton", nil, reagentDialog.scrollChild, "UICheckButtonTemplate")
            cb:SetSize(24, 24)
            cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            cb.text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
            reagentDialog.checkboxes[i] = cb
        end
        local cb = reagentDialog.checkboxes[i]
        cb:SetPoint("TOPLEFT", 10, -(i - 1) * 30)
        local reagentName = GetCachedItemInfo(reagent.id) or ("Item " .. reagent.id)
        cb.text:SetText(reagentName .. " x" .. reagent.count)
        cb:SetChecked(true)
        cb.reagentData = reagent
        cb:Show()
    end
    reagentDialog.scrollChild:SetHeight(math.max(#reagents * 30, 1))
    reagentDialog.currentReagents = reagents
    reagentDialog.yesButton:SetScript("OnClick", function()
        reagentDialog:Hide()
        AddItemToSlot(currentQueueItem.itemId, currentQueueItem.slotIndex, currentQueueItem.goalAmount)
        for i, reagent in ipairs(reagentDialog.currentReagents) do
            local cb = reagentDialog.checkboxes[i]
            if cb and cb:GetChecked() then
                local multipliedCount = reagent.count
                if currentQueueItem.goalAmount then
                    multipliedCount = reagent.count * currentQueueItem.goalAmount
                end
                QueueItemAdd(reagent.id, nil, multipliedCount)
            end
        end
        ProcessNextQueueItem()
    end)
    reagentDialog.noButton:SetScript("OnClick", function()
        reagentDialog:Hide()
        AddItemToSlot(currentQueueItem.itemId, currentQueueItem.slotIndex, currentQueueItem.goalAmount)
        ProcessNextQueueItem()
    end)
    reagentDialog:Show()
end

ShowElementalDialog = function(parentItemId, conversion)
    if not reagentDialog then
        reagentDialog = CreateFrame("Frame", "RTReagentDialog", UIParent)
        reagentDialog:SetSize(340, 180)
        reagentDialog:SetPoint("CENTER")
        reagentDialog:SetFrameStrata("DIALOG")
        reagentDialog:EnableMouse(true)
        reagentDialog:SetMovable(true)
        reagentDialog:RegisterForDrag("LeftButton")
        reagentDialog:SetClampedToScreen(true)
        reagentDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        reagentDialog:SetBackdropColor(0, 0, 0, 0.9)
        reagentDialog.title = reagentDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        reagentDialog.title:SetPoint("TOP", 0, -15)
        reagentDialog.text = reagentDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        reagentDialog.text:SetPoint("TOP", reagentDialog.title, "BOTTOM", 0, -15)
        reagentDialog.text:SetWidth(300)
        reagentDialog.text:SetJustifyH("LEFT")
        reagentDialog.yesButton = CreateFrame("Button", nil, reagentDialog, "UIPanelButtonTemplate")
        reagentDialog.yesButton:SetSize(80, 22)
        reagentDialog.yesButton:SetPoint("BOTTOM", -45, 15)
        reagentDialog.yesButton:SetText("Yes")
        reagentDialog.noButton = CreateFrame("Button", nil, reagentDialog, "UIPanelButtonTemplate")
        reagentDialog.noButton:SetSize(80, 22)
        reagentDialog.noButton:SetPoint("BOTTOM", 45, 15)
        reagentDialog.noButton:SetText("No")
        reagentDialog:SetScript("OnDragStart", reagentDialog.StartMoving)
        reagentDialog:SetScript("OnDragStop", reagentDialog.StopMovingOrSizing)
        reagentDialog:Hide()
    end
    for _, cb in ipairs(reagentDialog.checkboxes or {}) do cb:Hide() end
    if reagentDialog.scrollFrame then reagentDialog.scrollFrame:Hide() end
    reagentDialog:SetSize(340, 180)
    reagentDialog.title:SetText("Add Component?")
    local parentName = GetCachedItemInfo(parentItemId) or ("Item " .. parentItemId)
    local componentName = GetCachedItemInfo(conversion.component) or ("Item " .. conversion.component)
    reagentDialog.text:SetText(parentName .. " can be created from:\n\n  " .. componentName .. " x" .. conversion.count .. "\n\nAdd this component to the tracker?")
    reagentDialog.yesButton:SetScript("OnClick", function()
        reagentDialog:Hide()
        AddItemToSlot(currentQueueItem.itemId, currentQueueItem.slotIndex, currentQueueItem.goalAmount)
        local componentGoal = currentQueueItem.goalAmount and (currentQueueItem.goalAmount * conversion.count) or nil
        QueueItemAdd(conversion.component, nil, componentGoal)
        ProcessNextQueueItem()
    end)
    reagentDialog.noButton:SetScript("OnClick", function()
        reagentDialog:Hide()
        AddItemToSlot(currentQueueItem.itemId, currentQueueItem.slotIndex, currentQueueItem.goalAmount)
        ProcessNextQueueItem()
    end)
    reagentDialog:Show()
end

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
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        configDialog:SetBackdropColor(0, 0, 0, 0.9)
        configDialog.title = configDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        configDialog.title:SetPoint("TOP", 0, -15)
        configDialog.title:SetText("Enter Item ID")
        configDialog.editBox = CreateFrame("EditBox", nil, configDialog, "InputBoxTemplate")
        configDialog.editBox:SetSize(200, 20)
        configDialog.editBox:SetPoint("TOP", configDialog.title, "BOTTOM", 0, -20)
        configDialog.editBox:SetAutoFocus(false)
        configDialog.editBox:SetMaxLetters(10)
        configDialog.editBox:SetNumeric(true)
        configDialog.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        configDialog.editBox:SetScript("OnEnterPressed", function(self)
            local id = tonumber(self:GetText())
            if id and id > 0 and GetCachedItemInfo(id) then
                configDialog:Hide()
                addQueue = {}
                QueueItemAdd(id, configDialog.currentSlot, nil)
            else
                print("|cffff0000Invalid Item ID|r")
            end
        end)
        configDialog.okButton = CreateFrame("Button", nil, configDialog, "UIPanelButtonTemplate")
        configDialog.okButton:SetSize(80, 22)
        configDialog.okButton:SetPoint("BOTTOM", -45, 15)
        configDialog.okButton:SetText("OK")
        configDialog.okButton:SetScript("OnClick", function()
            local id = tonumber(configDialog.editBox:GetText())
            if id and id > 0 and GetCachedItemInfo(id) then
                configDialog:Hide()
                addQueue = {}
                QueueItemAdd(id, configDialog.currentSlot, nil)
            else
                print("|cffff0000Invalid Item ID|r")
            end
        end)
        configDialog.cancelButton = CreateFrame("Button", nil, configDialog, "UIPanelButtonTemplate")
        configDialog.cancelButton:SetSize(80, 22)
        configDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        configDialog.cancelButton:SetText("Cancel")
        configDialog.cancelButton:SetScript("OnClick", function() configDialog:Hide() end)
        configDialog:SetScript("OnDragStart", configDialog.StartMoving)
        configDialog:SetScript("OnDragStop", configDialog.StopMovingOrSizing)
        configDialog:Hide()
    end
    configDialog.currentSlot = slotIndex
    configDialog.editBox:SetText("")
    configDialog:Show()
    configDialog.editBox:SetFocus()
end

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
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        goalDialog:SetBackdropColor(0, 0, 0, 0.9)
        goalDialog.title = goalDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        goalDialog.title:SetPoint("TOP", 0, -15)
        goalDialog.title:SetText("Set Goal Amount")
        goalDialog.editBox = CreateFrame("EditBox", nil, goalDialog, "InputBoxTemplate")
        goalDialog.editBox:SetSize(200, 20)
        goalDialog.editBox:SetPoint("TOP", goalDialog.title, "BOTTOM", 0, -20)
        goalDialog.editBox:SetAutoFocus(false)
        goalDialog.editBox:SetMaxLetters(10)
        goalDialog.editBox:SetNumeric(true)
        goalDialog.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        goalDialog.editBox:SetScript("OnEnterPressed", function(self)
            local goal = tonumber(self:GetText())
            if goal and goal > 0 and ResourceTrackerAccountDB.slots[goalDialog.currentSlot] then
                ResourceTrackerAccountDB.slots[goalDialog.currentSlot].goal = goal
                UpdateSlot(goalDialog.currentSlot)
                goalDialog:Hide()
            else
                print("|cffff0000Invalid goal amount|r")
            end
        end)
        goalDialog.okButton = CreateFrame("Button", nil, goalDialog, "UIPanelButtonTemplate")
        goalDialog.okButton:SetSize(80, 22)
        goalDialog.okButton:SetPoint("BOTTOM", -45, 15)
        goalDialog.okButton:SetText("OK")
        goalDialog.okButton:SetScript("OnClick", function()
            local goal = tonumber(goalDialog.editBox:GetText())
            if goal and goal > 0 and ResourceTrackerAccountDB.slots[goalDialog.currentSlot] then
                ResourceTrackerAccountDB.slots[goalDialog.currentSlot].goal = goal
                UpdateSlot(goalDialog.currentSlot)
                goalDialog:Hide()
            else
                print("|cffff0000Invalid goal amount|r")
            end
        end)
        goalDialog.cancelButton = CreateFrame("Button", nil, goalDialog, "UIPanelButtonTemplate")
        goalDialog.cancelButton:SetSize(80, 22)
        goalDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        goalDialog.cancelButton:SetText("Cancel")
        goalDialog.cancelButton:SetScript("OnClick", function() goalDialog:Hide() end)
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
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        optionsDialog:SetBackdropColor(0, 0, 0, 0.9)
        optionsDialog.title = optionsDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        optionsDialog.title:SetPoint("TOP", 0, -15)
        optionsDialog.title:SetText("Options")
        optionsDialog.label = optionsDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        optionsDialog.label:SetPoint("TOP", optionsDialog.title, "BOTTOM", 0, -20)
        optionsDialog.label:SetText("Slots per row:")
        optionsDialog.editBox = CreateFrame("EditBox", nil, optionsDialog, "InputBoxTemplate")
        optionsDialog.editBox:SetSize(60, 20)
        optionsDialog.editBox:SetPoint("TOP", optionsDialog.label, "BOTTOM", 0, -10)
        optionsDialog.editBox:SetAutoFocus(false)
        optionsDialog.editBox:SetMaxLetters(2)
        optionsDialog.editBox:SetNumeric(true)
        optionsDialog.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        optionsDialog.okButton = CreateFrame("Button", nil, optionsDialog, "UIPanelButtonTemplate")
        optionsDialog.okButton:SetSize(80, 22)
        optionsDialog.okButton:SetPoint("BOTTOM", -45, 15)
        optionsDialog.okButton:SetText("OK")
        optionsDialog.okButton:SetScript("OnClick", function()
            local value = tonumber(optionsDialog.editBox:GetText())
            if value and value > 0 and value <= 20 then
                ResourceTrackerAccountDB.slotsPerRow = value
                UpdateSlotPositions()
            else
                print("|cffff0000Enter 1-20|r")
            end
            optionsDialog:Hide()
        end)
        optionsDialog.cancelButton = CreateFrame("Button", nil, optionsDialog, "UIPanelButtonTemplate")
        optionsDialog.cancelButton:SetSize(80, 22)
        optionsDialog.cancelButton:SetPoint("BOTTOM", 45, 15)
        optionsDialog.cancelButton:SetText("Cancel")
        optionsDialog.cancelButton:SetScript("OnClick", function() optionsDialog:Hide() end)
        optionsDialog:SetScript("OnDragStart", optionsDialog.StartMoving)
        optionsDialog:SetScript("OnDragStop", optionsDialog.StopMovingOrSizing)
        optionsDialog:Hide()
    end
    optionsDialog.editBox:SetText(tostring(ResourceTrackerAccountDB.slotsPerRow))
    optionsDialog:Show()
    optionsDialog.editBox:SetFocus()
end

ShowClearAllDialog = function()
    if not clearAllDialog then
        clearAllDialog = CreateFrame("Frame", "RTClearAllDialog", UIParent)
        clearAllDialog:SetSize(300, 140)
        clearAllDialog:SetPoint("CENTER")
        clearAllDialog:SetFrameStrata("DIALOG")
        clearAllDialog:EnableMouse(true)
        clearAllDialog:SetMovable(true)
        clearAllDialog:RegisterForDrag("LeftButton")
        clearAllDialog:SetClampedToScreen(true)
        clearAllDialog:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
        clearAllDialog:SetBackdropColor(0, 0, 0, 0.9)
        clearAllDialog.title = clearAllDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        clearAllDialog.title:SetPoint("TOP", 0, -15)
        clearAllDialog.title:SetText("Clear All Slots?")
        clearAllDialog.text = clearAllDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        clearAllDialog.text:SetPoint("TOP", clearAllDialog.title, "BOTTOM", 0, -20)
        clearAllDialog.text:SetWidth(260)
        clearAllDialog.text:SetJustifyH("CENTER")
        clearAllDialog.text:SetText("Are you sure you want to clear\nall tracked items?")
        clearAllDialog.yesButton = CreateFrame("Button", nil, clearAllDialog, "UIPanelButtonTemplate")
        clearAllDialog.yesButton:SetSize(80, 22)
        clearAllDialog.yesButton:SetPoint("BOTTOM", -45, 15)
        clearAllDialog.yesButton:SetText("Yes")
        clearAllDialog.yesButton:SetScript("OnClick", function()
            ResourceTrackerAccountDB.slots = {}
            pollingItems = {}
            savedCounts = {}
            RebuildSlots()
            clearAllDialog:Hide()
        end)
        clearAllDialog.noButton = CreateFrame("Button", nil, clearAllDialog, "UIPanelButtonTemplate")
        clearAllDialog.noButton:SetSize(80, 22)
        clearAllDialog.noButton:SetPoint("BOTTOM", 45, 15)
        clearAllDialog.noButton:SetText("No")
        clearAllDialog.noButton:SetScript("OnClick", function() clearAllDialog:Hide() end)
        clearAllDialog:SetScript("OnDragStart", clearAllDialog.StartMoving)
        clearAllDialog:SetScript("OnDragStop", clearAllDialog.StopMovingOrSizing)
        clearAllDialog:Hide()
    end
    clearAllDialog:Show()
end

CreateSlot = function(parent, index)
    local slot = CreateFrame("Button", "RTSlot" .. index, parent)
    slot:SetSize(SLOT_SIZE, SLOT_SIZE)
    slot.slotIndex = index
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
        local data = ResourceTrackerAccountDB.slots[index]
        if button == "LeftButton" then
            if IsShiftKeyDown() and data and data.id then
                local itemLink = select(2, GetCachedItemInfo(data.id))
                if itemLink and ChatEdit_GetActiveWindow() then
                    ChatEdit_InsertLink(itemLink)
                end
            elseif IsAltKeyDown() and data and data.id then
                local itemLink = select(2, GetCachedItemInfo(data.id))
                if itemLink then
                    SetItemRef(itemLink, itemLink, "LeftButton")
                end
            elseif not IsControlKeyDown() then
                ShowConfigDialog(index)
            end
        elseif button == "RightButton" and not IsShiftKeyDown() and not IsAltKeyDown() and not IsControlKeyDown() then
            if data and data.id then
                if not dropdownMenu then
                    dropdownMenu = CreateFrame("Frame", "RTDropdownMenu", UIParent, "UIDropDownMenuTemplate")
                end
                local menuList = {
                    {text = data.goal and "Remove Goal" or "Add Goal", func = function()
                        if data.goal then
                            ResourceTrackerAccountDB.slots[index].goal = nil
                            UpdateSlot(index)
                        else
                            ShowGoalDialog(index)
                        end
                    end, notCheckable = true},
                    {text = "Clear Slot", func = function()
                        local clearedItemId = ResourceTrackerAccountDB.slots[index].id
                        ResourceTrackerAccountDB.slots[index] = nil
                        if clearedItemId then pollingItems[clearedItemId] = nil end
                        RebuildSlots()
                    end, notCheckable = true},
                    {text = "Clear All Slots", func = function() ShowClearAllDialog() end, notCheckable = true},
                    {text = "Cancel", func = function() end, notCheckable = true}
                }
                EasyMenu(menuList, dropdownMenu, "cursor", 0, 0, "MENU")
            end
        end
    end)
    slot:RegisterForClicks("AnyUp")
    slot:SetScript("OnEnter", function(self)
        mainFrame.tab:Show()
        local data = ResourceTrackerAccountDB.slots[self.slotIndex]
        if data and data.id then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. data.id)
            GameTooltip:Show()
        end
    end)
    slot:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        mainFrame.tabHideTimer = 0.1
    end)
    return slot
end

UpdateSlot = function(slotIndex)
    local slot = slots[slotIndex]
    if not slot then return end
    local data = ResourceTrackerAccountDB.slots[slotIndex]
    if not data or not data.id then
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.icon:SetDesaturated(true)
        slot.count:SetText("")
        slot.goalText:Hide()
        slot.checkMark:Hide()
        slot.plusSign:Show()
        return
    end
    slot.plusSign:Hide()
    local itemName, _, _, _, _, _, _, _, _, texture = GetCachedItemInfo(data.id)
    if not texture then
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.icon:SetDesaturated(false)
        slot.count:SetText("...")
        slot.goalText:Hide()
        slot.checkMark:Hide()
        mainFrame.pendingSlots = mainFrame.pendingSlots or {}
        mainFrame.pendingSlots[slotIndex] = GetTime()
        return
    end
    local count = GetTotalItemCount(data.id)
    savedCounts[data.id] = count
    slot.icon:SetTexture(texture)
    slot.icon:SetDesaturated(false)
    slot.count:SetText(FormatCount(count))
    if data.goal then
        slot.goalText:SetText(FormatCount(data.goal))
        slot.goalText:Show()
        slot.checkMark[count >= data.goal and "Show" or "Hide"](slot.checkMark)
    else
        slot.goalText:Hide()
        slot.checkMark:Hide()
    end
    if mainFrame.pendingSlots then mainFrame.pendingSlots[slotIndex] = nil end
end

UpdateAllSlots = function()
    if not mainFrame then return end
    for i = 1, #slots do UpdateSlot(i) end
end

UpdateSlotPositions = function()
    if not mainFrame then return end
    local filledCount = 0
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then filledCount = filledCount + 1 end
    end
    local totalSlots = filledCount + 1
    local slotsPerRow = ResourceTrackerAccountDB.slotsPerRow or 4
    for i = totalSlots + 1, #slots do slots[i]:Hide() end
    for i = 1, totalSlots do
        if not slots[i] then slots[i] = CreateSlot(mainFrame, i) end
        local slot = slots[i]
        slot.slotIndex = i
        local row = math.floor((i - 1) / slotsPerRow)
        local col = (i - 1) % slotsPerRow
        slot:ClearAllPoints()
        slot:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", col * (SLOT_SIZE + SLOT_SPACING), -(TAB_HEIGHT + row * (SLOT_SIZE + SLOT_SPACING)))
        slot:SetParent(mainFrame)
        slot:Show()
    end
    if mainFrame.tab and slots[1] then
        mainFrame.tab:ClearAllPoints()
        mainFrame.tab:SetPoint("BOTTOMLEFT", slots[1], "TOPLEFT", -1, 0)
    end
end

RebuildSlots = function()
    if not mainFrame then return end
    CleanupStaleData()
    local consolidated = {}
    local sortedIndices = {}
    for i, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then table.insert(sortedIndices, i) end
    end
    table.sort(sortedIndices)
    for newIndex, oldIndex in ipairs(sortedIndices) do
        consolidated[newIndex] = ResourceTrackerAccountDB.slots[oldIndex]
    end
    ResourceTrackerAccountDB.slots = consolidated
    savedCounts = {}
    for _, data in pairs(ResourceTrackerAccountDB.slots) do
        if data and data.id then savedCounts[data.id] = GetTotalItemCount(data.id) end
    end
    UpdateSlotPositions()
    UpdateAllSlots()
end

local function CreateMainFrame()
    mainFrame = CreateFrame("Frame", "ResourceTrackerFrame", UIParent)
    mainFrame:SetSize(SLOT_SIZE, TAB_HEIGHT)
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ResourceTrackerAccountDB.anchorX, ResourceTrackerAccountDB.anchorY)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetClampedToScreen(true)
    mainFrame.isLocked = ResourceTrackerAccountDB.isLocked or false
    mainFrame:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing()
        local left, top = mainFrame:GetLeft(), mainFrame:GetTop()
        if left and top then
            ResourceTrackerAccountDB.anchorX = math.floor(left * 100 + 0.5) / 100
            ResourceTrackerAccountDB.anchorY = math.floor((top - UIParent:GetHeight()) * 100 + 0.5) / 100
        end
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
            local left, top = mainFrame:GetLeft(), mainFrame:GetTop()
            if left and top then
                ResourceTrackerAccountDB.anchorX = math.floor(left * 100 + 0.5) / 100
                ResourceTrackerAccountDB.anchorY = math.floor((top - UIParent:GetHeight()) * 100 + 0.5) / 100
            end
        elseif button == "RightButton" then
            if not dropdownMenu then
                dropdownMenu = CreateFrame("Frame", "RTDropdownMenu", UIParent, "UIDropDownMenuTemplate")
            end
            local menuList = {
                {text = mainFrame.isLocked and "Unlock Bar" or "Lock Bar", func = function()
                    mainFrame.isLocked = not mainFrame.isLocked
                    ResourceTrackerAccountDB.isLocked = mainFrame.isLocked
                end, notCheckable = true},
                {text = "Options", func = function() ShowOptionsDialog() end, notCheckable = true},
                {text = "Cancel", func = function() end, notCheckable = true}
            }
            EasyMenu(menuList, dropdownMenu, "cursor", 0, 0, "MENU")
        end
    end)
    mainFrame.tab:SetScript("OnLeave", function(self) mainFrame.tabHideTimer = 0.1 end)
    mainFrame.tabHideTimer = 0
    mainFrame:SetScript("OnUpdate", function(self, elapsed)
        if self.tabHideTimer > 0 then
            self.tabHideTimer = self.tabHideTimer - elapsed
            if self.tabHideTimer <= 0 then
                self.tabHideTimer = 0
                if not self.isDragging and not self.tab:IsMouseOver() then
                    local mouseOverSlot = false
                    for j = 1, #slots do
                        if slots[j]:IsShown() and slots[j]:IsMouseOver() then
                            mouseOverSlot = true
                            break
                        end
                    end
                    if not mouseOverSlot then self.tab:Hide() end
                end
            end
        end
        if self.pendingSlots then
            local currentTime = GetTime()
            for slotIndex, startTime in pairs(self.pendingSlots) do
                if currentTime - startTime > PENDING_TIMEOUT then
                    self.pendingSlots[slotIndex] = nil
                else
                    UpdateSlot(slotIndex)
                end
            end
        end
    end)
    return mainFrame
end

local pollingFrame = CreateFrame("Frame")
pollingFrame:Hide()
pollingFrame:SetScript("OnUpdate", function(self, elapsed)
    for itemId, pollData in pairs(pollingItems) do
        pollData.timer = pollData.timer + elapsed
        pollData.totalTime = pollData.totalTime + elapsed
        if pollData.totalTime >= POLLING_TIMEOUT then
            pollingItems[itemId] = nil
        elseif pollData.timer >= POLLING_INTERVAL then
            pollData.timer = 0
            local currentCount = GetTotalItemCount(itemId)
            if currentCount ~= pollData.oldCount then
                savedCounts[itemId] = currentCount
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
    local hasItems = false
    for _ in pairs(pollingItems) do hasItems = true break end
    if not hasItems then self:Hide() end
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        hasResourceBankAPI = (GetCustomGameData ~= nil)
        CreateMainFrame()
        RebuildSlots()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not hasLoadedOnce then
            hasLoadedOnce = true
            C_Timer.After(1.0, UpdateAllSlots)
            C_Timer.After(2.5, CheckRecipeDataAndPrompt)
        end
    elseif event == "CHAT_MSG_LOOT" then
        local lootedItemId = tonumber(arg1:match("item:(%d+)"))
        if lootedItemId then
            for slotIndex, data in pairs(ResourceTrackerAccountDB.slots) do
                if data and data.id == lootedItemId then
                    local currentCount = GetTotalItemCount(lootedItemId)
                    local oldCount = savedCounts[lootedItemId] or 0
                    if currentCount ~= oldCount then
                        savedCounts[lootedItemId] = currentCount
                        UpdateSlot(slotIndex)
                    else
                        if not pollingItems[lootedItemId] then
                            pollingItems[lootedItemId] = {slotIndex = slotIndex, oldCount = oldCount, timer = 0, totalTime = 0}
                            pollingFrame:Show()
                        end
                    end
                    break
                end
            end
        end
    elseif event == "TRADE_SKILL_SHOW" then
        local professionName = GetTradeSkillLine()
        if professionName then ScanTradeSkillRecipes(professionName) end
    elseif event == "CHAT_MSG_SYSTEM" then
        if arg1 and arg1:find("^You have learned how to create a new item:") then
            C_Timer.After(0.5, CheckRecipeDataAndPrompt)
        end
    end
end)

print("|cff00ff00ResourceTracker loaded!|r")
