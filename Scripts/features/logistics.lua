-- Eqol Feature: Logistics UI Screen
-- 1. Configurable keybind (default L, configurable in Settings -> Controls) + bottom-right HUD indicator.
-- 2. Icon-heavy Logistics UI showing:
--    - All items currently stored in containers on the station (inventory-like icon grid)
--    - Every production machine (assemblers, refineries, etc.), its output rate (items/min),
--      individual ingredient consumption rates (items/min), and a bottleneck indicator.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "Logistics",
    DisplayName = "Station Logistics Overview",
    Description = "Hotkey (default L) for station storage totals, machine production rates, and bottlenecks.",
}

local DEFAULT_KEY = "L"
local MAPPING_NAME = "Eqol_Logistics"

local PATHS = {
    WindowBaseClass    = "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C",
    WBPBorderClass     = "/Game/Blueprints/Widgets/Basic/WBP_Border.WBP_Border_C",
    WBPButtonClass     = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass       = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass       = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    InventorySlotClass = "/Game/Blueprints/Widgets/Display/Inventory/WBP_InventorySlot.WBP_InventorySlot_C",
    InputRemapClass    = "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C",
    InputKeyClass      = "/Game/Blueprints/Widgets/Display/WBP_InputKey.WBP_InputKey_C",
    BorderClass        = "/Script/UMG.Border",
    SizeBoxClass       = "/Script/UMG.SizeBox",
    VerticalBoxClass   = "/Script/UMG.VerticalBox",
    HorizontalBoxClass = "/Script/UMG.HorizontalBox",
    ScrollBoxClass     = "/Script/UMG.ScrollBox",
    WrapBoxClass       = "/Script/UMG.WrapBox",
}

local STATUS_COLORS = {
    Green      = { R = 0.05402, G = 0.7042, B = 0.05281, A = 1.0 },
    Amber      = { R = 0.8917,  G = 0.6242, B = 0.0,     A = 1.0 },
    Red        = { R = 0.5177,  G = 0.0,    B = 0.04122, A = 1.0 },
    OutputFull = { R = 0.16,    G = 0.65,   B = 0.96,    A = 1.0 },
    WinBg      = { R = 0.012,   G = 0.016,  B = 0.024,   A = 0.78 },
    RowBg      = { R = 0.0,     G = 0.0,    B = 0.0,     A = 0.0  },
    KeyBg      = { R = 0.060,   G = 0.090,  B = 0.130,   A = 0.85 },
}

local HudKeyIndicators = {} -- hudAddr -> { Root, KeyText }
local ActiveLogisticsWin = nil
local ActiveLogisticsUI = nil

--------------------------------------------------------------------------------
-- Keybind Helpers
--------------------------------------------------------------------------------

local function GetFormattedKeybind(configKey, defaultKey)
    local keyStr = tostring(Core.Config[configKey] or defaultKey or "")
    if keyStr == "None" or keyStr == "" then
        keyStr = "-"
    end
    return keyStr
end

local function UpdateAllHudKeyIndicators()
    for addr, entry in pairs(HudKeyIndicators) do
        if Core.IsValidObj(entry.Root) then
            if entry.Items then
                for _, item in ipairs(entry.Items) do
                    if Core.IsValidObj(item.Icon) then
                        local kt = item.KeyText
                        if not Core.IsValidObj(kt) then
                            pcall(function()
                                if Core.IsValidObj(item.Icon.WBP_InputKey) then
                                    kt = item.Icon.WBP_InputKey.WBP_Text
                                    item.KeyText = kt
                                end
                            end)
                        end
                        if Core.IsValidObj(kt) then
                            local keyStr = GetFormattedKeybind(item.ConfigKey, item.DefaultKey)
                            pcall(function() kt:SetText(Core.MakeText(keyStr)) end)
                        end
                    end
                end
            end
        else
            HudKeyIndicators[addr] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Logistics Data Aggregation
--------------------------------------------------------------------------------

local function GetItemKey(item)
    if not Core.IsValidObj(item) then return nil end
    local ok, n = pcall(function() return item:GetFName():ToString() end)
    if ok and type(n) == "string" and n ~= "" then
        return n
    end
    return tostring(item:GetAddress())
end

local function GetAssemblerRunState(m)
    local bWorking = nil
    local okW, w = pcall(function() return m.bWorking end)
    if okW and type(w) == "boolean" then
        bWorking = w
    end

    local status = nil
    if m.GetAssemblerStatus then
        local okS, s = pcall(function() return m:GetAssemblerStatus() end)
        if okS and type(s) == "number" then
            status = s
        end
    end

    local isRunning = false
    if bWorking ~= nil then
        isRunning = bWorking and (status == nil or status == 0)
    elseif status ~= nil then
        isRunning = (status == 0)
    end
    return isRunning, status
end

local function CheckAssemblerInventories(m, isRunning, machineStatus, inputs, outputs)
    local missingInputs = false
    local missingNames = {}
    local outputFull = false

    -- 1. Check whether output craft completed or OutputInventory lacks space
    pcall(function()
        if m.bProgressComplete == true then
            outputFull = true
        end
    end)

    if not outputFull and #outputs > 0 then
        local outInv = nil
        pcall(function()
            outInv = m.GetOutputInventory and m:GetOutputInventory() or m.OutputInventory
        end)
        if Core.IsValidObj(outInv) then
            local isEmpty = false
            pcall(function()
                if outInv.IsEmpty then
                    isEmpty = (outInv:IsEmpty() == true)
                end
            end)
            if not isEmpty and outInv.HasSpaceForItems then
                local primaryOut = outputs[1]
                local okSp, sp = pcall(function()
                    return outInv:HasSpaceForItems({
                        Item = primaryOut.Item,
                        Amount = primaryOut.CraftAmount or 1,
                    })
                end)
                if okSp and type(sp) == "boolean" and not sp then
                    outputFull = true
                end
            end
        end
    end

    -- 2. Inspect InputInventory directly against recipe per-craft input amounts
    local inInv = nil
    pcall(function()
        inInv = m.GetInputInventory and m:GetInputInventory() or m.InputInventory
    end)
    if Core.IsValidObj(inInv) and #inputs > 0 then
        local storedIn = {}
        local readSlots = false
        local okSlots, slots = pcall(function() return inInv:GetItemSlots() end)
        if okSlots and slots then
            readSlots = true
            StationData.ForEachArray(slots, function(_, elem)
                local st = Core.UnwrapStruct(elem)
                if st and Core.IsValidObj(st.Item) then
                    local k = GetItemKey(st.Item)
                    if k then
                        storedIn[k] = (storedIn[k] or 0) + (tonumber(st.Amount) or 0)
                    end
                end
            end)
        end

        for _, inp in ipairs(inputs) do
            local have = 0
            if readSlots then
                local k = GetItemKey(inp.Item)
                have = (k and storedIn[k]) or 0
            elseif inInv.GetItemAmount then
                local okAmt, a = pcall(function() return inInv:GetItemAmount(inp.Item) end)
                if okAmt and type(a) == "number" then have = a end
            end
            if have < (inp.CraftAmount or 1) then
                missingInputs = true
                local iName = GetItemKey(inp.Item) or "?"
                pcall(function()
                    if inp.Item and inp.Item.DisplayName then
                        local s = tostring(inp.Item.DisplayName:ToString())
                        if s ~= "" then iName = s end
                    elseif inp.Item and inp.Item.Name then
                        local s = tostring(inp.Item.Name:ToString())
                        if s ~= "" then iName = s end
                    end
                end)
                missingNames[#missingNames + 1] = iName
            end
        end
    elseif machineStatus == 1 and not outputFull then
        missingInputs = true
    end

    -- If powered & valid config with all required inputs present, but stopped -> output is full
    if not outputFull and not isRunning and machineStatus ~= 2 and machineStatus ~= 3 and not missingInputs then
        outputFull = true
    end
    if outputFull then
        missingInputs = false
    end

    return missingInputs, missingNames, outputFull
end

local function CollectStationLogisticsData(station, walkFrame)
    local machines = StationData.GetStationMachines(station, walkFrame)

    local containerItems = {} -- itemKey -> { Item = uobj, Amount = number }
    local assemblers = {}
    local stationProdRates = {} -- itemKey -> actual items/min
    local stationConsRates = {} -- itemKey -> active/starved items/min

    local stationProdItems = {} -- itemKey -> { Item = uobj, Rate = number }

    local seenMachines = {}

    for _, m in ipairs(machines) do
        local mAddr = m:GetAddress()
        if not seenMachines[mAddr] then
            seenMachines[mAddr] = true
            local cat = StationData.GetMachineCategory(m)

            if cat == "Container" then
                local inv = StationData.GetContainerInventory(m)
                if Core.IsValidObj(inv) then
                    local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
                    if okSlots and slots then
                        StationData.ForEachArray(slots, function(_, elem)
                            local st = Core.UnwrapStruct(elem)
                            if st and Core.IsValidObj(st.Item) then
                                local amt = tonumber(st.Amount) or 0
                                if amt > 0 then
                                    local k = GetItemKey(st.Item)
                                    if not containerItems[k] then
                                        containerItems[k] = { Item = st.Item, Amount = 0 }
                                    end
                                    containerItems[k].Amount = containerItems[k].Amount + amt
                                end
                            end
                        end)
                    end
                end
            elseif cat == "Assembler" then
                local rec = nil
                pcall(function() rec = m.Recipe end)

                local bonusMult = 1.0
                pcall(function()
                    local bm = Core.GetFPFloat(m.BonusMultiplier)
                    if bm > 0.0001 then bonusMult = bm end
                end)

                local isRunning, machineStatus = GetAssemblerRunState(m)
                local craftSec = 1.0
                local inputs = {}
                local outputs = {}
                local hasMissingInputs, missingNames, isOutputFull = false, {}, false

                if Core.IsValidObj(rec) then
                    local okSec, sec = pcall(function() return rec:GetCraftingSeconds() end)
                    if okSec and type(sec) == "number" and sec > 0.0001 then
                        craftSec = sec
                    end

                    -- Outputs
                    local okOut, outStack = pcall(function() return rec.Output end)
                    if okOut and outStack and Core.IsValidObj(outStack.Item) then
                        local amt = tonumber(outStack.Amount) or 1
                        local rate = (amt * 60.0 / craftSec) * bonusMult
                        table.insert(outputs, { Item = outStack.Item, Rate = rate, CraftAmount = amt })
                    else
                        local okOuts, outs = pcall(function() return rec:GetOutputs() end)
                        if okOuts and outs then
                            StationData.ForEachArray(outs, function(_, elem)
                                local st = Core.UnwrapStruct(elem)
                                if st and Core.IsValidObj(st.Item) then
                                    local amt = tonumber(st.Amount) or 1
                                    local rate = (amt * 60.0 / craftSec) * bonusMult
                                    table.insert(outputs, { Item = st.Item, Rate = rate, CraftAmount = amt })
                                end
                            end)
                        end
                    end

                    -- Inputs
                    local okIn, inArr = pcall(function() return rec.Inputs end)
                    if okIn and inArr then
                        StationData.ForEachArray(inArr, function(_, elem)
                            local st = Core.UnwrapStruct(elem)
                            if st and Core.IsValidObj(st.Item) then
                                local amt = tonumber(st.Amount) or 1
                                local rate = (amt * 60.0 / craftSec) * bonusMult
                                table.insert(inputs, { Item = st.Item, Rate = rate, CraftAmount = amt })
                            end
                        end)
                    end

                    hasMissingInputs, missingNames, isOutputFull = CheckAssemblerInventories(m, isRunning, machineStatus, inputs, outputs)

                    -- Total Production reflects ONLY actual currently running output;
                    -- stationProdRates also counts Output Full machines so backed-up producers don't report fake deficits.
                    for _, outp in ipairs(outputs) do
                        local k = GetItemKey(outp.Item)
                        if k then
                            if isRunning or isOutputFull then
                                stationProdRates[k] = (stationProdRates[k] or 0.0) + outp.Rate
                            end
                            if isRunning then
                                if not stationProdItems[k] then
                                    stationProdItems[k] = { Item = outp.Item, Rate = 0.0 }
                                end
                                stationProdItems[k].Rate = stationProdItems[k].Rate + outp.Rate
                            end
                        end
                    end

                    -- Demand counts running or input-starved machines (not output-full, unpowered, or invalid config)
                    if (isRunning or hasMissingInputs) and machineStatus ~= 2 and machineStatus ~= 3 then
                        for _, inp in ipairs(inputs) do
                            local k = GetItemKey(inp.Item)
                            if k then
                                stationConsRates[k] = (stationConsRates[k] or 0.0) + inp.Rate
                            end
                        end
                    end
                end

                table.insert(assemblers, {
                    Machine = m,
                    Addr = mAddr,
                    Name = StationData.GetMachineDisplayName(m),
                    HasRecipe = Core.IsValidObj(rec),
                    IsRunning = isRunning,
                    MachineStatus = machineStatus,
                    HasMissingInputs = hasMissingInputs,
                    MissingInputNames = missingNames,
                    IsOutputFull = isOutputFull,
                    Inputs = inputs,
                    Outputs = outputs,
                })
            end
        end
    end

    -- Sort container items by descending amount
    local sortedItems = {}
    for _, entry in pairs(containerItems) do
        table.insert(sortedItems, entry)
    end
    table.sort(sortedItems, function(a, b) return a.Amount > b.Amount end)

    local sortedProdTotals = {}
    for _, entry in pairs(stationProdItems) do
        table.insert(sortedProdTotals, entry)
    end
    table.sort(sortedProdTotals, function(a, b) return a.Rate > b.Rate end)

    return sortedItems, assemblers, stationProdRates, stationConsRates, sortedProdTotals
end

--------------------------------------------------------------------------------
-- Logistics Window UI
--------------------------------------------------------------------------------

local function SetLogisticsCursorMode(pc, win, active)
    if not Core.IsValidObj(pc) then return end
    pcall(function()
        pc.bShowMouseCursor = active
    end)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) then
        pcall(function() widgetSub:SetCursorVisible(active) end)
    end
    local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    if Core.IsValidObj(wbl) then
        pcall(function()
            if active then
                wbl:SetInputMode_GameAndUIEx(pc, win, 0, false, false)
            else
                wbl:SetInputMode_GameOnly(pc, false)
            end
        end)
    end
end

local ActiveLogisticsVisible = false
local CachedWidgetClasses = {}
local CachedWblCDO = nil

local function CreateRawFast(classPath, outer)
    local cls = CachedWidgetClasses[classPath]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(classPath)
        if Core.IsValidObj(cls) then CachedWidgetClasses[classPath] = cls end
    end
    if not Core.IsValidObj(cls) or not Core.IsValidObj(outer) then return nil end
    local ok, w = pcall(StaticConstructObject, cls, outer)
    return (ok and Core.IsValidObj(w)) and w or nil
end

local function CreateUserWidgetFast(classPath, worldContext, owningPC)
    if not Core.IsValidObj(CachedWblCDO) then
        CachedWblCDO = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    end
    local cls = CachedWidgetClasses[classPath]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(classPath)
        if Core.IsValidObj(cls) then CachedWidgetClasses[classPath] = cls end
    end
    if not Core.IsValidObj(CachedWblCDO) or not Core.IsValidObj(cls) or not Core.IsValidObj(worldContext) then
        return nil
    end
    local ok, w = pcall(function() return CachedWblCDO:Create(worldContext, cls, owningPC) end)
    return (ok and Core.IsValidObj(w)) and w or nil
end

local function DestroyLogisticsWindow()
    local wasVisible = ActiveLogisticsVisible
    ActiveLogisticsVisible = false
    if Core.IsValidObj(ActiveLogisticsWin) then
        if Core.IsValidObj(ActiveLogisticsWin.WBP_WindowHeader) and Core.IsValidObj(ActiveLogisticsWin.WBP_WindowHeader.CloseButton) then
            Core.UnregisterWBPButtonClick(ActiveLogisticsWin.WBP_WindowHeader.CloseButton)
        end
        pcall(function() ActiveLogisticsWin:RemoveFromParent() end)
    end
    ActiveLogisticsWin = nil
    ActiveLogisticsUI = nil
    -- Only restore game-only cursor mode if Logistics actually owned the cursor;
    -- never hide the cursor on MainMenu/OnMapLoad when Logistics was not open!
    if wasVisible then
        SetLogisticsCursorMode(Core.GetLocalPlayerController(), nil, false)
    end
end

local function CloseLogisticsWindow()
    ActiveLogisticsVisible = false
    if Core.IsValidObj(ActiveLogisticsWin) then
        pcall(function() ActiveLogisticsWin:SetVisibility(1) end) -- Collapsed for instant reopen (learning.md §8)
    end
    SetLogisticsCursorMode(Core.GetLocalPlayerController(), nil, false)
end

local function FormatRate(rate)
    if rate >= 100.0 then
        return string.format("%.0f/m", rate)
    elseif rate >= 10.0 then
        return string.format("%.1f/m", rate)
    end
    return string.format("%.2f/m", rate)
end

local function AddItemRateChip(parentHBox, window, pc, outer, item, rate, tintColor)
    local chipBox = CreateRawFast(PATHS.HorizontalBoxClass, outer)
    local itemW = CreateUserWidgetFast(PATHS.WBPItemClass, window, pc)
    local rateTxt = CreateUserWidgetFast(PATHS.WBPTextClass, window, pc)
    if not (Core.IsValidObj(chipBox) and Core.IsValidObj(itemW) and Core.IsValidObj(rateTxt)) then
        return
    end

    pcall(function()
        itemW:SetIconSize(24.0)
        itemW:SetItem(item)
        rateTxt:SetSize(12)
        rateTxt:SetText(Core.MakeText(FormatRate(rate)))
        if tintColor and Core.IsValidObj(rateTxt.TextBlock) then
            rateTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = tintColor, ColorUseRule = 0 })
        end
    end)

    local s1 = chipBox:AddChildToHorizontalBox(itemW)
    if Core.IsValidObj(s1) then
        pcall(function() s1:SetVerticalAlignment(2) end)
    end
    local s2 = chipBox:AddChildToHorizontalBox(rateTxt)
    if Core.IsValidObj(s2) then
        pcall(function()
            s2:SetVerticalAlignment(2)
            s2:SetPadding({ Left = 4.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        end)
    end

    local pSlot = parentHBox:AddChildToHorizontalBox(chipBox)
    if Core.IsValidObj(pSlot) then
        pcall(function()
            pSlot:SetVerticalAlignment(2)
            pSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 12.0, Bottom = 0.0 })
        end)
    end
    return rateTxt
end

local COLOR_DEFAULT_RATE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

-- Shared deficit predicate: raw resources (no recipe & 0 station production) are never flagged as production deficits.
local function IsInputInDeficit(item, prodRates, consRates)
    local k = GetItemKey(item) or "?"
    local pRate = prodRates[k] or 0.0
    local cRate = consRates[k] or 0.0
    local hasRecipe = false
    pcall(function() hasRecipe = Core.IsValidObj(item.Recipe) end)
    return (pRate > 0.001 or hasRecipe) and (cRate > pRate + 0.001), k, pRate, cRate
end

local function BuildStorageSignatures(items)
    local orderParts = {}
    local fullParts = {}
    for _, entry in ipairs(items) do
        local k = GetItemKey(entry.Item) or "?"
        table.insert(orderParts, k)
        table.insert(fullParts, k .. "=" .. tostring(entry.Amount))
    end
    return table.concat(orderParts, ","), table.concat(fullParts, ";")
end

local function BuildTotalsSignature(prodTotals)
    local parts = {}
    for _, entry in ipairs(prodTotals) do
        local k = GetItemKey(entry.Item) or "?"
        table.insert(parts, string.format("%s=%.2f", k, entry.Rate or 0.0))
    end
    return table.concat(parts, ";")
end

local function ComputeAssemblerStatus(entry, prodRates, consRates)
    local hasDeficit = false
    local deficitNames = {}
    local inpParts = {}
    for _, inp in ipairs(entry.Inputs) do
        local isDef, k, pRate, cRate = IsInputInDeficit(inp.Item, prodRates, consRates)
        if isDef then
            hasDeficit = true
            local iName = k
            pcall(function()
                if inp.Item and inp.Item.Name then
                    local s = tostring(inp.Item.Name:ToString())
                    if s ~= "" then iName = s end
                elseif inp.Item and inp.Item.GetName then
                    local s = tostring(inp.Item:GetName())
                    if s ~= "" then iName = s end
                end
            end)
            deficitNames[#deficitNames + 1] = string.format("%s (%.1f/m needed, %.1f/m produced)", iName, cRate, pRate)
        end
        table.insert(inpParts, string.format("%s=%.2f:%s", k, inp.Rate or 0.0, isDef and "R" or "N"))
    end

    local statusCode = "G"
    local statusLabel = "Producing"
    local statusCol = STATUS_COLORS.Green
    local tooltipMsg = "Producing: machine is actively running and supplied."
    if not entry.HasRecipe then
        statusCode = "A"
        statusLabel = "No Recipe"
        statusCol = STATUS_COLORS.Amber
        tooltipMsg = "Idle: no active recipe or output configured."
    elseif entry.MachineStatus == 2 then
        statusCode = "R_PWR"
        statusLabel = "No Power"
        statusCol = STATUS_COLORS.Red
        tooltipMsg = "Offline: insufficient power."
    elseif entry.MachineStatus == 3 then
        statusCode = "R_CFG"
        statusLabel = "Invalid Config"
        statusCol = STATUS_COLORS.Red
        tooltipMsg = "Stopped: invalid machine configuration."
    elseif entry.IsOutputFull then
        statusCode = "B_FULL"
        statusLabel = "Output Full"
        statusCol = STATUS_COLORS.OutputFull
        tooltipMsg = "Output full: output buffer is full so production is paused."
    elseif entry.HasMissingInputs then
        statusCode = "R_ITM"
        statusLabel = "Missing Inputs"
        statusCol = STATUS_COLORS.Red
        if entry.MissingInputNames and #entry.MissingInputNames > 0 then
            tooltipMsg = "Missing inputs: waiting for " .. table.concat(entry.MissingInputNames, ", ") .. "."
        elseif hasDeficit then
            tooltipMsg = "Bottlenecked (missing inputs): " .. table.concat(deficitNames, ", ") .. "."
        else
            tooltipMsg = "Waiting for input items."
        end
    elseif hasDeficit and entry.IsRunning then
        statusCode = "R_DEF"
        statusLabel = "Input Deficit"
        statusCol = STATUS_COLORS.Red
        tooltipMsg = "Bottlenecked: input demand exceeds current production (" .. table.concat(deficitNames, ", ") .. ")."
    elseif not entry.IsRunning then
        statusCode = "A_STP"
        statusLabel = "Idle"
        statusCol = STATUS_COLORS.Amber
        tooltipMsg = "Idle: machine is not currently running."
    end

    local outParts = {}
    for _, outp in ipairs(entry.Outputs) do
        local k = GetItemKey(outp.Item) or "?"
        table.insert(outParts, string.format("%s=%.2f", k, outp.Rate or 0.0))
    end
    local sig = string.format("%s|%s|%s|%s|%s|%s",
        tostring(entry.Name), statusCode, tostring(entry.IsRunning), tostring(entry.MachineStatus),
        table.concat(inpParts, ","), table.concat(outParts, ","))
    return statusCol, statusLabel, tooltipMsg, sig
end

local function PopulateStorageSection(ui, items)
    if not ui or not Core.IsValidObj(ui.Window) or not Core.IsValidObj(ui.InvWrap) then return end
    local orderSig, fullSig = BuildStorageSignatures(items)
    if ui.LastStorageFullSig == fullSig then return end
    ui.LastStorageFullSig = fullSig

    if Core.IsValidObj(ui.InvHeader) then
        pcall(function()
            ui.InvHeader:SetText(Core.MakeText(string.format("Storage (%d)", #items)))
        end)
    end

    -- Fast in-place update when the set/order of stored item types hasn't changed
    if ui.LastStorageOrderSig == orderSig and ui.StorageSlots then
        local allOk = true
        for idx, entry in ipairs(items) do
            local slotW = ui.StorageSlots[idx]
            if Core.IsValidObj(slotW) then
                pcall(function()
                    slotW:SetItemStack({ Item = entry.Item, Amount = entry.Amount })
                end)
            else
                allOk = false
                break
            end
        end
        if allOk then return end
    end

    ui.LastStorageOrderSig = orderSig
    ui.StorageSlots = {}
    local savedOffset = 0.0
    if Core.IsValidObj(ui.InvScroll) and ui.InvScroll.GetScrollOffset then
        pcall(function() savedOffset = tonumber(ui.InvScroll:GetScrollOffset()) or 0.0 end)
    end

    pcall(function()
        if ui.InvWrap.ClearChildren then ui.InvWrap:ClearChildren() end
    end)
    for idx, entry in ipairs(items) do
        local slotW = CreateUserWidgetFast(PATHS.InventorySlotClass, ui.Window, ui.PC)
        if Core.IsValidObj(slotW) then
            pcall(function()
                slotW:SetItemStack({ Item = entry.Item, Amount = entry.Amount })
            end)
            ui.InvWrap:AddChildToWrapBox(slotW)
            ui.StorageSlots[idx] = slotW
        end
    end

    if Core.IsValidObj(ui.InvScroll) and ui.InvScroll.SetScrollOffset and savedOffset > 0.0 then
        pcall(function() ui.InvScroll:SetScrollOffset(savedOffset) end)
    end
end

local function PopulateTotalProductionSection(ui, prodTotals)
    if not ui or not Core.IsValidObj(ui.Window) or not Core.IsValidObj(ui.TotListBox) then return end
    local sig = BuildTotalsSignature(prodTotals)
    if ui.LastTotalsSig == sig then return end
    ui.LastTotalsSig = sig

    if Core.IsValidObj(ui.TotHeader) then
        pcall(function()
            ui.TotHeader:SetText(Core.MakeText(string.format("Total Production (%d)", #prodTotals)))
        end)
    end

    local savedOffset = 0.0
    if Core.IsValidObj(ui.TotScroll) and ui.TotScroll.GetScrollOffset then
        pcall(function() savedOffset = tonumber(ui.TotScroll:GetScrollOffset()) or 0.0 end)
    end

    pcall(function()
        if ui.TotListBox.ClearChildren then ui.TotListBox:ClearChildren() end
    end)
    for i = 1, #prodTotals, 2 do
        local pairRow = CreateRawFast(PATHS.HorizontalBoxClass, ui.Outer)
        if Core.IsValidObj(pairRow) then
            for col = 0, 1 do
                local entry = prodTotals[i + col]
                local cellBox = CreateRawFast(PATHS.HorizontalBoxClass, ui.Outer)
                if Core.IsValidObj(cellBox) then
                    if entry then
                        AddItemRateChip(cellBox, ui.Window, ui.PC, ui.Outer, entry.Item, entry.Rate, STATUS_COLORS.Green)
                    end
                    local cSlot = pairRow:AddChildToHorizontalBox(cellBox)
                    if Core.IsValidObj(cSlot) then
                        pcall(function() cSlot:SetSize({ Value = 0.5, SizeRule = 1 }) end)
                    end
                end
            end
            local prSlot = ui.TotListBox:AddChildToVerticalBox(pairRow)
            if Core.IsValidObj(prSlot) then
                pcall(function() prSlot:SetPadding({ Left = 0.0, Top = 3.0, Right = 0.0, Bottom = 3.0 }) end)
            end
        end
    end

    if Core.IsValidObj(ui.TotScroll) and ui.TotScroll.SetScrollOffset and savedOffset > 0.0 then
        pcall(function() ui.TotScroll:SetScrollOffset(savedOffset) end)
    end
end

local function BuildMachineRow(ui, entry, info, prodRates, consRates)
    local rowBorder = CreateRawFast(PATHS.BorderClass, ui.Outer)
    local rowHBox = CreateRawFast(PATHS.HorizontalBoxClass, ui.Outer)
    local statusBar = CreateRawFast(PATHS.BorderClass, ui.Outer)
    local statusSize = CreateRawFast(PATHS.SizeBoxClass, ui.Outer)
    if not (Core.IsValidObj(rowBorder) and Core.IsValidObj(rowHBox) and Core.IsValidObj(statusBar) and Core.IsValidObj(statusSize)) then
        return nil
    end

    pcall(function()
        rowBorder:SetBrushColor(STATUS_COLORS.RowBg)
        rowBorder:SetPadding({ Left = 6.0, Top = 6.0, Right = 8.0, Bottom = 6.0 })
        rowBorder:SetToolTipText(Core.MakeText(info.tooltipMsg))
        statusBar:SetBrushColor(info.statusCol)
        statusSize:SetWidthOverride(6.0)
        statusSize:SetHeightOverride(28.0)
    end)
    statusSize:AddChild(statusBar)

    local stSlot = rowHBox:AddChildToHorizontalBox(statusSize)
    if Core.IsValidObj(stSlot) then
        pcall(function()
            stSlot:SetVerticalAlignment(2)
            stSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 8.0, Bottom = 0.0 })
        end)
    end

    local statusTxt = nil
    local nameTxt = CreateUserWidgetFast(PATHS.WBPTextClass, ui.Window, ui.PC)
    if Core.IsValidObj(nameTxt) then
        pcall(function()
            nameTxt:SetSize(12)
            nameTxt:SetText(Core.MakeText(entry.Name))
        end)
        local nameCol = CreateRawFast(PATHS.VerticalBoxClass, ui.Outer)
        statusTxt = CreateUserWidgetFast(PATHS.WBPTextClass, ui.Window, ui.PC)
        if Core.IsValidObj(nameCol) and Core.IsValidObj(statusTxt) then
            pcall(function()
                statusTxt:SetSize(9)
                statusTxt:SetText(Core.MakeText(info.statusLabel or ""))
                if Core.IsValidObj(statusTxt.TextBlock) then
                    statusTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = info.statusCol, ColorUseRule = 0 })
                end
            end)
            nameCol:AddChildToVerticalBox(nameTxt)
            nameCol:AddChildToVerticalBox(statusTxt)
        end
        local nBox = CreateRawFast(PATHS.SizeBoxClass, ui.Outer)
        pcall(function() nBox:SetWidthOverride(130.0) end)
        nBox:AddChild(Core.IsValidObj(nameCol) and nameCol or nameTxt)
        local nSlot = rowHBox:AddChildToHorizontalBox(nBox)
        if Core.IsValidObj(nSlot) then
            pcall(function() nSlot:SetVerticalAlignment(2) end)
        end
    end

    local inputChips = {}
    for _, inp in ipairs(entry.Inputs) do
        local isDef = IsInputInDeficit(inp.Item, prodRates, consRates)
        local chipTint = isDef and STATUS_COLORS.Red or nil
        local rateTxt = AddItemRateChip(rowHBox, ui.Window, ui.PC, ui.Outer, inp.Item, inp.Rate, chipTint)
        inputChips[#inputChips + 1] = { Item = inp.Item, RateTxt = rateTxt }
    end

    if #entry.Inputs > 0 and #entry.Outputs > 0 then
        local arrowTxt = CreateUserWidgetFast(PATHS.WBPTextClass, ui.Window, ui.PC)
        if Core.IsValidObj(arrowTxt) then
            pcall(function()
                arrowTxt:SetSize(13)
                arrowTxt:SetText(Core.MakeText("→"))
            end)
            local aSlot = rowHBox:AddChildToHorizontalBox(arrowTxt)
            if Core.IsValidObj(aSlot) then
                pcall(function()
                    aSlot:SetVerticalAlignment(2)
                    aSlot:SetPadding({ Left = 2.0, Top = 0.0, Right = 10.0, Bottom = 0.0 })
                end)
            end
        end
    end

    for _, outp in ipairs(entry.Outputs) do
        AddItemRateChip(rowHBox, ui.Window, ui.PC, ui.Outer, outp.Item, outp.Rate, STATUS_COLORS.Green)
    end

    rowBorder:AddChild(rowHBox)
    local rSlot = ui.MachListBox:AddChildToVerticalBox(rowBorder)
    if Core.IsValidObj(rSlot) then
        pcall(function() rSlot:SetPadding({ Left = 0.0, Top = 2.0, Right = 0.0, Bottom = 2.0 }) end)
    end
    return {
        RowBorder = rowBorder,
        StatusBar = statusBar,
        StatusTxt = statusTxt,
        InputChips = inputChips,
    }
end

local function PopulateMachinesSection(ui, assemblers, prodRates, consRates)
    if not ui or not Core.IsValidObj(ui.Window) or not Core.IsValidObj(ui.MachListBox) then return end

    local computed = {}
    local sigParts = {}
    local structParts = {}
    for idx, entry in ipairs(assemblers) do
        local statusCol, statusLabel, tooltipMsg, rowSig = ComputeAssemblerStatus(entry, prodRates, consRates)
        computed[idx] = { statusCol = statusCol, statusLabel = statusLabel, tooltipMsg = tooltipMsg }
        sigParts[idx] = rowSig
        local inKeys = {}
        for _, inp in ipairs(entry.Inputs) do
            inKeys[#inKeys + 1] = string.format("%s=%.1f", GetItemKey(inp.Item) or "?", inp.Rate or 0.0)
        end
        local outKeys = {}
        for _, outp in ipairs(entry.Outputs) do
            outKeys[#outKeys + 1] = string.format("%s=%.1f", GetItemKey(outp.Item) or "?", outp.Rate or 0.0)
        end
        structParts[idx] = string.format("%s|%s|%s|%s",
            tostring(entry.Addr or entry.Name), tostring(entry.HasRecipe),
            table.concat(inKeys, ","), table.concat(outKeys, ","))
    end
    local sig = table.concat(sigParts, "||")
    if ui.LastMachinesSig == sig then return end
    ui.LastMachinesSig = sig

    if Core.IsValidObj(ui.MachHeader) then
        pcall(function()
            ui.MachHeader:SetText(Core.MakeText(string.format("Production (%d)", #assemblers)))
        end)
    end

    -- Fast in-place update when machine list & recipes haven't changed (avoids rebuilding thousands of widgets)
    local structSig = table.concat(structParts, "||")
    if ui.LastMachinesStructSig == structSig and ui.MachineRows and #ui.MachineRows == #assemblers and not ui.MachStreamActive then
        local allOk = true
        for idx, info in ipairs(computed) do
            local rw = ui.MachineRows[idx]
            if rw and Core.IsValidObj(rw.RowBorder) and Core.IsValidObj(rw.StatusBar) then
                pcall(function()
                    rw.RowBorder:SetToolTipText(Core.MakeText(info.tooltipMsg))
                    rw.StatusBar:SetBrushColor(info.statusCol)
                    if Core.IsValidObj(rw.StatusTxt) then
                        rw.StatusTxt:SetText(Core.MakeText(info.statusLabel or ""))
                        if Core.IsValidObj(rw.StatusTxt.TextBlock) then
                            rw.StatusTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = info.statusCol, ColorUseRule = 0 })
                        end
                    end
                    if rw.InputChips then
                        for _, chip in ipairs(rw.InputChips) do
                            if Core.IsValidObj(chip.RateTxt) and Core.IsValidObj(chip.RateTxt.TextBlock) then
                                local isDef = IsInputInDeficit(chip.Item, prodRates, consRates)
                                local col = isDef and STATUS_COLORS.Red or COLOR_DEFAULT_RATE
                                chip.RateTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                            end
                        end
                    end
                end)
            else
                allOk = false
                break
            end
        end
        if allOk then return end
    end

    ui.LastMachinesStructSig = structSig
    ui.MachStreamGen = (ui.MachStreamGen or 0) + 1
    local myGen = ui.MachStreamGen
    ui.MachineRows = {}

    local savedOffset = 0.0
    if Core.IsValidObj(ui.MachScroll) and ui.MachScroll.GetScrollOffset then
        pcall(function() savedOffset = tonumber(ui.MachScroll:GetScrollOffset()) or 0.0 end)
    end

    pcall(function()
        if ui.MachListBox.ClearChildren then ui.MachListBox:ClearChildren() end
    end)

    local total = #assemblers
    if total == 0 then
        ui.MachStreamActive = false
        return
    end

    -- Stream machine rows in time-budgeted batches so opening Logistics never freezes the game thread
    ui.MachStreamActive = true
    local nextIdx = 1
    local function StreamBatch()
        if ActiveLogisticsUI ~= ui or ui.MachStreamGen ~= myGen or not Core.IsValidObj(ui.Window) or not Core.IsValidObj(ui.MachListBox) then
            return
        end
        local tStart = os.clock()
        local builtThisFrame = 0
        while nextIdx <= total do
            local entry = assemblers[nextIdx]
            local info = computed[nextIdx]
            ui.MachineRows[nextIdx] = BuildMachineRow(ui, entry, info, prodRates, consRates)
            nextIdx = nextIdx + 1
            builtThisFrame = builtThisFrame + 1
            if builtThisFrame >= 6 and (os.clock() - tStart) >= 0.005 then
                break
            end
        end

        if nextIdx <= total then
            ExecuteInGameThreadAfterFrames(1, StreamBatch)
        else
            ui.MachStreamActive = false
            if Core.IsValidObj(ui.MachScroll) and ui.MachScroll.SetScrollOffset and savedOffset > 0.0 then
                pcall(function() ui.MachScroll:SetScrollOffset(savedOffset) end)
            end
        end
    end

    StreamBatch()
end

local function RefreshLogisticsUI(ui)
    if not ui or not Core.IsValidObj(ui.Window) then return false end
    local pc = Core.IsValidObj(ui.PC) and ui.PC or Core.GetLocalPlayerController()
    local station, walkFrame = ui.Station, ui.WalkFrame
    if Core.IsValidObj(pc) then
        local inSt, curWalk, curSt = StationData.IsPlayerInStation(pc)
        if inSt then
            if Core.IsValidObj(curSt) then station = curSt end
            if Core.IsValidObj(curWalk) then walkFrame = curWalk end
            ui.Station = station
            ui.WalkFrame = walkFrame
        end
    end

    local items, assemblers, prodRates, consRates, prodTotals = CollectStationLogisticsData(station, walkFrame)
    PopulateStorageSection(ui, items)
    PopulateTotalProductionSection(ui, prodTotals)
    PopulateMachinesSection(ui, assemblers, prodRates, consRates)
    return true
end

local function StartLogisticsLivePoll(win, ui)
    local function PollTick()
        if not ActiveLogisticsVisible or ActiveLogisticsWin ~= win or ActiveLogisticsUI ~= ui or not Core.IsValidObj(win) then
            return
        end
        local openAndVisible = false
        pcall(function()
            openAndVisible = (win:IsInViewport() == true) and (win:IsVisible() == true)
        end)
        if not openAndVisible then
            CloseLogisticsWindow()
            return
        end

        if not ui.MachStreamActive then
            pcall(RefreshLogisticsUI, ui)
        end
        ExecuteInGameThreadWithDelay(1500, PollTick)
    end

    ExecuteInGameThreadWithDelay(1500, PollTick)
end

local function OpenLogisticsWindow()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation and not Core.IsValidObj(station) then
        Core.Log("Logistics: player is not in a station")
        return
    end

    if Core.IsValidObj(ActiveLogisticsWin) and ActiveLogisticsUI then
        local win = ActiveLogisticsWin
        ActiveLogisticsVisible = true
        ActiveLogisticsUI.PC = pc
        ActiveLogisticsUI.Station = station
        ActiveLogisticsUI.WalkFrame = walkFrame
        pcall(function()
            local inVp = win.IsInViewport and win:IsInViewport()
            if not inVp then
                win:AddToViewport(50)
                win:SetAnchorsInViewport({ Minimum = { X = 0.22, Y = 0.08 }, Maximum = { X = 0.78, Y = 0.92 } })
            end
            win:SetVisibility(0)
        end)
        SetLogisticsCursorMode(pc, win, true)
        RefreshLogisticsUI(ActiveLogisticsUI)
        StartLogisticsLivePoll(win, ActiveLogisticsUI)
        return
    end

    local win = CreateUserWidgetFast(PATHS.WindowBaseClass, pc, pc)
    if not Core.IsValidObj(win) then
        Core.Log("Logistics: failed to construct WBP_WindowBase_C")
        return
    end

    ActiveLogisticsWin = win
    ActiveLogisticsVisible = true
    local outer = Core.GetWidgetOuter(win)

    pcall(function()
        win:SetWindowName(Core.MakeText("Logistics"))
        win:AddToViewport(50)
        win:SetAnchorsInViewport({ Minimum = { X = 0.22, Y = 0.08 }, Maximum = { X = 0.78, Y = 0.92 } })
    end)
    SetLogisticsCursorMode(pc, win, true)

    if Core.IsValidObj(win.WBP_WindowHeader) and Core.IsValidObj(win.WBP_WindowHeader.CloseButton) then
        Core.RegisterWBPButtonClick(win.WBP_WindowHeader.CloseButton, function()
            ExecuteInGameThreadWithDelay(10, CloseLogisticsWindow)
        end)
    end

    local rootBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local mainHBox = CreateRawFast(PATHS.HorizontalBoxClass, outer)
    if not (Core.IsValidObj(rootBox) and Core.IsValidObj(mainHBox)) then return end

    local attached = false
    if Core.IsValidObj(win.Content) then
        local okC = pcall(function() win.Content:AddChild(rootBox) end)
        if okC then attached = true end
    end
    if not attached and Core.IsValidObj(win.ContentBorder) then
        pcall(function() win.ContentBorder:AddChild(rootBox) end)
    end
    pcall(function() win:SetContentForSlot(FName("Content"), rootBox) end)

    -- Left Column: Storage Grid + Total Production Rates
    local leftVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local invHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
    local invScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local invWrap = Core.CreateRawWidget(PATHS.WrapBoxClass, outer)

    if Core.IsValidObj(invHeader) then
        pcall(function()
            invHeader:SetSize(14)
            invHeader:SetText(Core.MakeText("Storage (0)"))
        end)
        leftVBox:AddChildToVerticalBox(invHeader)
    end

    if Core.IsValidObj(invWrap) and Core.IsValidObj(invScroll) then
        pcall(function()
            invWrap:SetInnerSlotPadding({ X = 4.0, Y = 4.0 })
        end)
        invScroll:AddChild(invWrap)
        local sBoxSlot = leftVBox:AddChildToVerticalBox(invScroll)
        if Core.IsValidObj(sBoxSlot) then
            pcall(function() sBoxSlot:SetSize({ Value = 0.5, SizeRule = 1 }) end)
        end
    end

    local totHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
    local totScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local totListBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    if Core.IsValidObj(totHeader) then
        pcall(function()
            totHeader:SetSize(14)
            totHeader:SetText(Core.MakeText("Total Production (0)"))
        end)
        local thSlot = leftVBox:AddChildToVerticalBox(totHeader)
        if Core.IsValidObj(thSlot) then
            pcall(function() thSlot:SetPadding({ Left = 0.0, Top = 10.0, Right = 0.0, Bottom = 4.0 }) end)
        end
    end

    if Core.IsValidObj(totListBox) and Core.IsValidObj(totScroll) then
        totScroll:AddChild(totListBox)
        local tBoxSlot = leftVBox:AddChildToVerticalBox(totScroll)
        if Core.IsValidObj(tBoxSlot) then
            pcall(function() tBoxSlot:SetSize({ Value = 0.5, SizeRule = 1 }) end)
        end
    end

    local leftSlot = mainHBox:AddChildToHorizontalBox(leftVBox)
    if Core.IsValidObj(leftSlot) then
        pcall(function()
            leftSlot:SetSize({ Value = 0.36, SizeRule = 1 })
            leftSlot:SetVerticalAlignment(0)
            leftSlot:SetPadding({ Left = 8.0, Top = 8.0, Right = 16.0, Bottom = 8.0 })
        end)
    end

    -- Right Column: Production Machines & Rates
    local rightVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local machHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
    local machScroll = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local machListBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)

    if Core.IsValidObj(machHeader) then
        pcall(function()
            machHeader:SetSize(14)
            machHeader:SetText(Core.MakeText("Production (0)"))
        end)
        rightVBox:AddChildToVerticalBox(machHeader)
    end

    if Core.IsValidObj(machListBox) and Core.IsValidObj(machScroll) then
        machScroll:AddChild(machListBox)
        local mBoxSlot = rightVBox:AddChildToVerticalBox(machScroll)
        if Core.IsValidObj(mBoxSlot) then
            pcall(function() mBoxSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
        end
    end

    local rightSlot = mainHBox:AddChildToHorizontalBox(rightVBox)
    if Core.IsValidObj(rightSlot) then
        pcall(function()
            rightSlot:SetSize({ Value = 0.64, SizeRule = 1 })
            rightSlot:SetVerticalAlignment(0)
            rightSlot:SetPadding({ Left = 8.0, Top = 8.0, Right = 8.0, Bottom = 8.0 })
        end)
    end

    local mainSlot = rootBox:AddChildToVerticalBox(mainHBox)
    if Core.IsValidObj(mainSlot) then
        pcall(function()
            mainSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            mainSlot:SetHorizontalAlignment(0)
            mainSlot:SetVerticalAlignment(0)
        end)
    end

    local ui = {
        Window = win,
        PC = pc,
        Outer = outer,
        Station = station,
        WalkFrame = walkFrame,
        InvHeader = invHeader,
        InvScroll = invScroll,
        InvWrap = invWrap,
        TotHeader = totHeader,
        TotScroll = totScroll,
        TotListBox = totListBox,
        MachHeader = machHeader,
        MachScroll = machScroll,
        MachListBox = machListBox,
    }
    ActiveLogisticsUI = ui
    RefreshLogisticsUI(ui)
    StartLogisticsLivePoll(win, ui)
end

local function ToggleLogistics()
    if not Core.IsFeatureEnabled("Logistics") then
        if Core.IsValidObj(ActiveLogisticsWin) then CloseLogisticsWindow() end
        return
    end
    if Core.IsSelectingAnyRegisteredKeybind()
        or Core.IsAnyTextInputFocused()
    then
        return
    end

    if ActiveLogisticsVisible and Core.IsValidObj(ActiveLogisticsWin) then
        CloseLogisticsWindow()
        return
    end

    if not Core.IsGameplayInputAllowed() then
        return
    end

    OpenLogisticsWindow()
end

--------------------------------------------------------------------------------
-- Top-Right HUD Keybind Indicator
--------------------------------------------------------------------------------

local CachedHudIconTextures = {}
local HudIconScanCooldown = {} -- kind -> os.clock() of last missed FindAllOf("Texture2D") scan

local function FindHudIconTexture(kind, hud)
    if Core.IsValidObj(CachedHudIconTextures[kind]) then
        return CachedHudIconTextures[kind]
    end
    local now = os.clock()
    if HudIconScanCooldown[kind] and (now - HudIconScanCooldown[kind]) < 8.0 then
        return nil
    end

    local pathsByKind = {
        Logistics = {
            "/Game/Materials/UI_Textures/T_MatSciIcon.T_MatSciIcon",
            "/Game/Materials/Icons/T_MatSciIcon.T_MatSciIcon",
            "/Game/Textures/Icons/T_MatSciIcon.T_MatSciIcon",
            "/Game/Textures/T_MatSciIcon.T_MatSciIcon",
        },
        Power = {
            "/Game/Materials/Icons/UI/T_UI_Power.T_UI_Power",
            "/Game/Materials/Icons/UI/T_UI_Electricity.T_UI_Electricity",
            "/Game/Materials/Icons/UI/T_UI_Energy.T_UI_Energy",
            "/Game/Materials/Icons/UI/T_UI_Lightning.T_UI_Lightning",
            "/Game/Materials/Icons/UI/T_UI_Bolt.T_UI_Bolt",
            "/Game/Materials/Icons/T_Power.T_Power",
            "/Game/Materials/Icons/T_PowerIcon.T_PowerIcon",
            "/Game/Materials/Icons/T_Electricity.T_Electricity",
            "/Game/Materials/Icons/T_ElectricityIcon.T_ElectricityIcon",
            "/Game/Materials/Icons/T_Energy.T_Energy",
            "/Game/Materials/Icons/T_EnergyIcon.T_EnergyIcon",
            "/Game/Materials/Icons/T_Lightning.T_Lightning",
            "/Game/Materials/UI_Textures/T_Power.T_Power",
            "/Game/Materials/UI_Textures/T_PowerIcon.T_PowerIcon",
            "/Game/Materials/UI_Textures/T_Electricity.T_Electricity",
            "/Game/Materials/UI_Textures/T_ElectricityIcon.T_ElectricityIcon",
            "/Game/Materials/UI_Textures/T_Energy.T_Energy",
            "/Game/Materials/UI_Textures/T_EnergyIcon.T_EnergyIcon",
            "/Game/Textures/Icons/T_PowerIcon.T_PowerIcon",
            "/Game/Textures/Icons/T_Power.T_Power",
        },
        StationMap = {
            "/Game/Materials/Icons/UI/T_UI_StationIcon.T_UI_StationIcon",
            "/Game/Materials/UI_Textures/T_StationMapIcon.T_StationMapIcon",
            "/Game/Materials/UI_Textures/T_StationIcon.T_StationIcon",
            "/Game/Materials/Icons/T_StationIcon.T_StationIcon",
            "/Game/Materials/UI_Textures/T_MapIcon.T_MapIcon",
            "/Game/Materials/Icons/T_MapIcon.T_MapIcon",
        },
    }

    local tex = nil
    for _, tPath in ipairs(pathsByKind[kind] or {}) do
        local candidate = Core.FindOrLoadClass(tPath)
        if Core.IsValidObj(candidate) then
            tex = candidate
            break
        end
    end

    -- Reliable fallbacks from existing HUD input icons (never scan FindAllOf("Texture2D")!)
    if not Core.IsValidObj(tex) and Core.IsValidObj(hud) then
        if kind == "StationMap" and Core.IsValidObj(hud.MapInput) then
            pcall(function() tex = hud.MapInput.Icon end)
        elseif kind ~= "Power" and Core.IsValidObj(hud.ResearchInput) then
            pcall(function() tex = hud.ResearchInput.Icon end)
        end
    end

    if Core.IsValidObj(tex) then
        CachedHudIconTextures[kind] = tex
        HudIconScanCooldown[kind] = nil
    else
        HudIconScanCooldown[kind] = now
    end
    return tex
end

local function EnsureHudKeybindIndicator(hud)
    if not Core.IsValidObj(hud) then return end
    local addr = hud:GetAddress()
    if HudKeyIndicators[addr] and Core.IsValidObj(HudKeyIndicators[addr].Root) then
        return
    end

    local container = hud.HUDInputContainer
    if not Core.IsValidObj(container) then return end

    local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()
    local outer = Core.GetWidgetOuter(hud)

    -- Inspect Tab (InventoryInput) or B (BuildingInput) slot so spacing & shift match the top row exactly
    local refWidget = nil
    for _, prop in ipairs({ "InventoryInput", "BuildingInput", "DisassembleInput", "MapInput" }) do
        local okW, w = pcall(function() return hud[prop] end)
        if okW and Core.IsValidObj(w) and Core.IsValidObj(w.Slot) then
            refWidget = w
            break
        end
    end
    local refSlot = Core.IsValidObj(refWidget) and refWidget.Slot or nil

    local padL, padR, padT, padB = 4.0, 4.0, 0.0, 0.0
    local nudgeX, nudgeY = 0.0, 0.0
    local refVAlign = 2
    if Core.IsValidObj(refSlot) then
        pcall(function()
            local p = refSlot.Padding
            if p then
                padL = tonumber(p.Left) or padL
                padR = tonumber(p.Right) or padR
                padT = tonumber(p.Top) or padT
                padB = tonumber(p.Bottom) or padB
            end
            if refSlot.Nudge then
                nudgeX = tonumber(refSlot.Nudge.X) or 0.0
                nudgeY = tonumber(refSlot.Nudge.Y) or 0.0
            end
            if type(refSlot.VerticalAlignment) == "number" then
                refVAlign = refSlot.VerticalAlignment
            end
        end)
    end
    if nudgeX == 0.0 and Core.IsValidObj(refWidget) then
        pcall(function()
            local rt = refWidget.RenderTransform
            if rt and rt.Translation then
                nudgeX = tonumber(rt.Translation.X) or 0.0
            end
        end)
    end
    -- On WBP_CharacterHUD_C, Row 0 (Tab, B, X) sits ~22px right of Row 1 columns (T, G, K);
    -- shift our right-anchored host by the same amount when GridSlot.Nudge isn't explicitly set.
    if math.abs(nudgeX) < 0.5 then
        nudgeX = 22.0
    end

    -- Wrap hostCanvas in a 1x1 SizeBox (unclipped) in Row 0, Col 1 so the GridPanel NEVER
    -- stretches Column 1 (which would widen the base-game Map 'M' icon in Row 1, Col 1),
    -- while [P] [N] [L] render at full size extending cleanly to the left of Tab.
    local hostSizeBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local hostCanvas = Core.CreateRawWidget("/Script/UMG.CanvasPanel", outer)
    local iconsHBox = Core.CreateRawWidget(PATHS.HorizontalBoxClass, outer)
    if not (Core.IsValidObj(hostSizeBox) and Core.IsValidObj(hostCanvas) and Core.IsValidObj(iconsHBox)) then return end

    pcall(function()
        hostSizeBox:SetWidthOverride(1.0)
        hostSizeBox:SetHeightOverride(1.0)
        if hostSizeBox.SetClipping then hostSizeBox:SetClipping(0) end
        if hostCanvas.SetClipping then hostCanvas:SetClipping(0) end
    end)
    hostSizeBox:AddChild(hostCanvas)

    local cSlot = hostCanvas:AddChildToCanvas(iconsHBox)
    if Core.IsValidObj(cSlot) then
        pcall(function()
            cSlot:SetAnchors({ Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } })
            cSlot:SetAlignment({ X = 1.0, Y = 0.5 })
            cSlot:SetAutoSize(true)
            cSlot:SetPosition({ X = nudgeX, Y = nudgeY })
        end)
    end

    local inputIconCls = "/Game/Blueprints/Widgets/HUDs/WBP_InputIcon.WBP_InputIcon_C"
    local defs = {
        { Kind = "Power",      FeatureName = "PowerOverview", ConfigKey = "PowerOverviewKey", DefaultKey = "P" },
        { Kind = "StationMap", FeatureName = "StationMap",    ConfigKey = "StationMapKey",    DefaultKey = "N" },
        { Kind = "Logistics",  FeatureName = "Logistics",     ConfigKey = "LogisticsKey",     DefaultKey = DEFAULT_KEY },
    }

    local createdItems = {}
    for _, def in ipairs(defs) do
        local iconW = Core.CreateUserWidget(inputIconCls, hud, pc)
        if Core.IsValidObj(iconW) then
            local itemEntry = {
                Kind = def.Kind,
                FeatureName = def.FeatureName,
                ConfigKey = def.ConfigKey,
                DefaultKey = def.DefaultKey,
                Icon = iconW,
                IconAddr = iconW:GetAddress(),
                KeyText = nil,
            }

            local function ApplyVisuals()
                local tex = FindHudIconTexture(def.Kind, hud)
                local keyStr = GetFormattedKeybind(def.ConfigKey, def.DefaultKey)
                pcall(function()
                    if Core.IsValidObj(tex) then
                        iconW.Icon = tex
                        if Core.IsValidObj(iconW.Image_82) then
                            iconW.Image_82:SetBrushFromTexture(tex, false)
                        end
                    end
                    if Core.IsValidObj(iconW.WBP_InputKey) and Core.IsValidObj(iconW.WBP_InputKey.WBP_Text) then
                        itemEntry.KeyText = iconW.WBP_InputKey.WBP_Text
                        itemEntry.KeyText:SetText(Core.MakeText(keyStr))
                    end
                    local featEnabled = (not def.FeatureName) or Core.IsFeatureEnabled(def.FeatureName)
                    iconW:SetVisibility(featEnabled and 0 or 1)
                end)
            end

            ApplyVisuals()
            ExecuteInGameThreadAfterFrames(1, function()
                if Core.IsValidObj(iconW) then ApplyVisuals() end
            end)

            local hSlot = iconsHBox:AddChildToHorizontalBox(iconW)
            if Core.IsValidObj(hSlot) then
                pcall(function()
                    hSlot:SetPadding({ Left = padL, Top = padT, Right = padR, Bottom = padB })
                    hSlot:SetVerticalAlignment(refVAlign)
                end)
            end
            createdItems[#createdItems + 1] = itemEntry
        end
    end

    if #createdItems == 0 then return end

    local gSlot = container:AddChildToGrid(hostSizeBox, 0, 1)
    if Core.IsValidObj(gSlot) then
        pcall(function()
            gSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            gSlot:SetHorizontalAlignment(3) -- Right
            gSlot:SetVerticalAlignment(2)   -- Center
        end)
    end

    HudKeyIndicators[addr] = { Root = hostSizeBox, Items = createdItems }
end

local HudIndicatorPollActive = false

local function AnyHudIndicatorFeatureEnabled()
    return Core.IsFeatureEnabled("Logistics")
        or Core.IsFeatureEnabled("StationMap")
        or Core.IsFeatureEnabled("PowerOverview")
end

local function StartHudIndicatorPoll()
    if HudIndicatorPollActive or not AnyHudIndicatorFeatureEnabled() then return end
    HudIndicatorPollActive = true

    local function Tick()
        if not AnyHudIndicatorFeatureEnabled() then
            for addr, entry in pairs(HudKeyIndicators) do
                if Core.IsValidObj(entry.Root) then
                    pcall(function() entry.Root:SetVisibility(1) end)
                else
                    HudKeyIndicators[addr] = nil
                end
            end
            HudIndicatorPollActive = false
            return
        end
        local anyValid = false
        local pc = Core.GetLocalPlayerController()
        local showIndicator = false
        if Core.IsValidObj(pc) then
            local playerObj = pc.PlayerObject
            local piloting = Core.IsValidObj(playerObj) and Core.IsValidObj(playerObj.PilotedShip)
            if not piloting then
                local inStation = StationData.IsPlayerInStation(pc)
                showIndicator = inStation == true
            end
        end

        local targetVis = showIndicator and 0 or 1 -- Visible or Collapsed
        for addr, entry in pairs(HudKeyIndicators) do
            if Core.IsValidObj(entry.Root) then
                anyValid = true
                if entry.LastVis ~= targetVis then
                    entry.LastVis = targetVis
                    pcall(function() entry.Root:SetVisibility(targetVis) end)
                end
                if showIndicator and entry.Items then
                    for _, item in ipairs(entry.Items) do
                        local featOn = (not item.FeatureName) or Core.IsFeatureEnabled(item.FeatureName)
                        local iconVis = featOn and 0 or 1
                        if Core.IsValidObj(item.Icon) and item.LastIconVis ~= iconVis then
                            item.LastIconVis = iconVis
                            pcall(function() item.Icon:SetVisibility(iconVis) end)
                        end
                        if featOn and Core.IsValidObj(item.KeyText) then
                            local keyStr = GetFormattedKeybind(item.ConfigKey, item.DefaultKey)
                            if item.LastKeyStr ~= keyStr then
                                item.LastKeyStr = keyStr
                                pcall(function() item.KeyText:SetText(Core.MakeText(keyStr)) end)
                            end
                        end
                    end
                end
            else
                HudKeyIndicators[addr] = nil
            end
        end

        if anyValid then
            ExecuteInGameThreadWithDelay(1200, Tick)
        else
            HudIndicatorPollActive = false
        end
    end

    ExecuteInGameThreadWithDelay(1200, Tick)
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(hud)
        if not AnyHudIndicatorFeatureEnabled() then return end
        EnsureHudKeybindIndicator(hud)
        StartHudIndicatorPoll()
    end,
}

function Feature.Init()
    Core.RegisterConfigurableKeybind({
        ConfigKey     = "LogisticsKey",
        DefaultKey    = DEFAULT_KEY,
        MappingName   = MAPPING_NAME,
        Label         = "Logistics",
        AllowCursorUI = true,
        OnPress       = ToggleLogistics,
        OnChanged     = UpdateAllHudKeyIndicators,
    })
    if Key and Key.ESCAPE then
        RegisterKeyBind(Key.ESCAPE, function()
            if ActiveLogisticsVisible and Core.IsValidObj(ActiveLogisticsWin) then
                ExecuteInGameThread(CloseLogisticsWindow)
            end
        end)
    end
end

local InitialLogisticsWidgetScanDone = false

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "WindowBase_CloseWindow_Logistics",
        "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C:BndEvt__WBP_WindowBase_WBP_WindowHeader_K2Node_ComponentBoundEvent_1_CloseWindow__DelegateSignature",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) and Core.IsValidObj(ActiveLogisticsWin) and w:GetAddress() == ActiveLogisticsWin:GetAddress() then
                CloseLogisticsWindow()
            end
        end
    )

    Core.TryRegisterHook(
        "InputIcon_RefreshVisible_Logistics",
        "/Game/Blueprints/Widgets/HUDs/WBP_InputIcon.WBP_InputIcon_C:RefreshVisible",
        function(Context)
            local iconW = Context:get()
            if not Core.IsValidObj(iconW) then return end
            local iconAddr = iconW:GetAddress()
            for _, entry in pairs(HudKeyIndicators) do
                if entry.Items then
                    for _, item in ipairs(entry.Items) do
                        if item.IconAddr == iconAddr then
                            pcall(function()
                                local featEnabled = (not item.FeatureName) or Core.IsFeatureEnabled(item.FeatureName)
                                iconW:SetVisibility(featEnabled and 0 or 1)
                                local kt = item.KeyText
                                if not Core.IsValidObj(kt) and Core.IsValidObj(iconW.WBP_InputKey) then
                                    kt = iconW.WBP_InputKey.WBP_Text
                                    item.KeyText = kt
                                end
                                if Core.IsValidObj(kt) then
                                    local keyStr = GetFormattedKeybind(item.ConfigKey, item.DefaultKey)
                                    kt:SetText(Core.MakeText(keyStr))
                                end
                            end)
                            return
                        end
                    end
                end
            end
        end
    )

    Core.TryRegisterHook(
        "CharacterHUD_RefreshKeybinds_Logistics",
        "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C:RefreshKeybinds",
        function(Context)
            if not AnyHudIndicatorFeatureEnabled() then return end
            local hud = Context:get()
            if Core.IsValidObj(hud) then
                EnsureHudKeybindIndicator(hud)
                StartHudIndicatorPoll()
                UpdateAllHudKeyIndicators()
            end
        end
    )

    if not InitialLogisticsWidgetScanDone then
        InitialLogisticsWidgetScanDone = true
        if AnyHudIndicatorFeatureEnabled() then
            local okHud, h = pcall(FindFirstOf, "WBP_CharacterHUD_C")
            if okHud and Core.IsValidObj(h) then
                EnsureHudKeybindIndicator(h)
                StartHudIndicatorPoll()
            end
        end
    end
end

function Feature.OnToggle(enabled)
    if not enabled and Core.IsValidObj(ActiveLogisticsWin) then
        CloseLogisticsWindow()
    end
    UpdateAllHudKeyIndicators()
end

function Feature.OnMapLoad()
    DestroyLogisticsWindow()
    CachedWidgetClasses = {}
    CachedHudIconTextures = {}
    HudIconScanCooldown = {}
    CachedWblCDO = nil
end

function Feature.PruneCaches()
    for addr, entry in pairs(HudKeyIndicators) do
        if not Core.IsValidObj(entry.Root) then HudKeyIndicators[addr] = nil end
    end
    for k, tex in pairs(CachedHudIconTextures) do
        if not Core.IsValidObj(tex) then CachedHudIconTextures[k] = nil end
    end
    if ActiveLogisticsWin and not Core.IsValidObj(ActiveLogisticsWin) then
        ActiveLogisticsWin = nil
        ActiveLogisticsUI = nil
    end
end

return Feature
