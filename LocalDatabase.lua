if not InspectEquip then return end

local IE = InspectEquip
local IS = InspectEquip_ItemSources
local L = LibStub("AceLocale-3.0"):GetLocale("InspectEquip")

local band = bit.band
local bor = bit.bor
local tinsert = table.insert
local strfind = string.find
local max = math.max

-- check for 5.0+ client, because EJ api was changed
local mop = select(4, GetBuildInfo()) >= 50000
local wod = select(4, GetBuildInfo()) >= 60000
local legion = select(4, GetBuildInfo()) >= 70000

-- Database
InspectEquipLocalDB = {}
local ieVersion

-- Max wait cycles for database update
local MAX_WC = 5
local DATA_RECEIVED_WC = 7

local newDataReceived
local newDataCycles = 0
local dbInitialized = false

-- GUI
local bar, barText
local coUpdate

function IE:InitLocalDatabase()
	if dbInitialized then return end

	if not InspectEquipLocalDB then InspectEquipLocalDB = {} end
	setmetatable(InspectEquipLocalDB, {__index = {
		Zones = {}, Bosses = {}, Items = {}
	}})

	local _, currentBuild = GetBuildInfo()
	ieVersion = GetAddOnMetadata("InspectEquip", "Version")

	-- create database if not present or outdated (or wrong locale)
	if (InspectEquipLocalDB.ClientBuild ~= currentBuild) or
			(InspectEquipLocalDB.Locale ~= GetLocale()) or
			(InspectEquipLocalDB.IEVersion ~= ieVersion) or
			(InspectEquipLocalDB.Expansion ~= GetExpansionLevel()) then
		--self:CreateLocalDatabase()
		self:ScheduleTimer("CreateLocalDatabase", 5)
	end
	dbInitialized = true
end

local function createUpdateGUI()

	if not bar then
		bar = CreateFrame("STATUSBAR", nil, UIParent, "TextStatusBar")
	end
	bar:SetWidth(300)
	bar:SetHeight(30)
	bar:SetPoint("CENTER", 0, -100)
	bar:SetBackdrop({
		bgFile	 = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = 1, tileSize = 10, edgeSize = 10,
		insets = {left = 1, right = 1, top = 1, bottom = 1}
	})
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetBackdropColor(0, 0, 0, 1)
	bar:SetStatusBarColor(0.6, 0.6, 0, 0.4)
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(0)

	if not barText then
		barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	end
	barText:SetPoint("CENTER", bar, "CENTER")
	barText:SetJustifyH("CENTER")
	barText:SetJustifyV("CENTER")
	barText:SetTextColor(1, 1, 1)
	barText:SetText("InspectEquip: " .. L["Updating database..."])

	bar:SetMovable(true)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function() bar:StartMoving() end)
	bar:SetScript("OnDragStop", function() bar:StopMovingOrSizing() end)

end

local ejDisabled = false
local ejToggle = ToggleEncounterJournal

-- this function disables the EJ GUI during update
-- because using the EJ during update will result in an invalid database
-- (other addons may still use the EJ api and possibly destroy the DB that way...)
local function DisableEJ()
	if ejDisabled then return end
	ejDisabled = true

	-- hide EJ
	if EncounterJournal then
		if EncounterJournal:IsShown() then
			EncounterJournal:Hide()
		end
	end

	ejToggle = ToggleEncounterJournal
	ToggleEncounterJournal = function() end
	EJMicroButton:Disable()
end

local function EnableEJ()
	if not ejDisabled then return end
	ejDisabled = false

	ToggleEncounterJournal = ejToggle
	EJMicroButton:Enable()
	EJMicroButton:SetAlpha(1)
end

local function EndUpdate()
	bar:SetScript("OnUpdate", nil)
	bar:Hide()
	EnableEJ()
	coUpdate = nil
	IE:UnregisterEvent("EJ_LOOT_DATA_RECIEVED")
end

local function UpdateTick()
	if coUpdate then
		-- wait for loot data
		if newDataReceived then -- data received this frame
			newDataCycles = newDataCycles + DATA_RECEIVED_WC
			newDataReceived = false
		end
		if newDataCycles > 0 then
			newDataCycles = newDataCycles - 1
			return
		end
		local ok, msg = coroutine.resume(coUpdate)
		if not ok then
			EndUpdate()
			message("[InspectEquip] Could not update database: " .. msg)
		end
	end
end

local function UpdateBar()
	bar:SetValue(bar:GetValue() + 1)
	coroutine.yield()
end

local function GetReverseMapping(baseMap)
	local map = {}
	local id, name
	for id, name in pairs(baseMap) do
		map[name] = id
	end
	return map
end

local function DifficultyToMode(diff, raid)
	if diff == 1 then
		-- 5 normal
		return 2
	elseif diff == 2 then
		-- 5 heroic
		return 1
	elseif diff == 23 then
		-- 5 mythic
		return 3
	elseif diff == 3 then
		-- 10 normal
		return 8
	elseif diff == 4 then
		-- 25 normal
		return 16
	elseif diff == 5 then
		-- 10 heroic
		return 32
	elseif diff == 6 then
		-- 25 heroic
		return 64
	elseif diff == 7 then
		-- 25 lfr
		return 128
	elseif diff == 8 then
		-- 5 challenge TODO
		return 2
	elseif diff == 14 then
		-- normal / flexible
		return 65536
	elseif diff == 15 then
		-- heroic
		return 131072
	elseif diff == 16 then
		-- mythic
		return 262144
	elseif diff == 17 then
		-- lfr
		return 524288
	end
end

local function AddToDB(tempDB, itemID, zoneID, bossID, mode)
	local sources = tempDB[itemID]
	local entry
	if sources then
		for _, entry in pairs(sources) do
			if (entry[1] == zoneID) and (entry[2] == bossID) then
				entry[3] = bor(entry[3], mode)
				return
			end
		end
		tinsert(sources, {zoneID, bossID, mode})
	else
		tempDB[itemID] = {{zoneID, bossID, mode}}
	end
end

local function SaveToDB(tempDB, entryType)
	local itemID, sources, entry
	for itemID, sources in pairs(tempDB) do
		local str = InspectEquipLocalDB.Items[itemID]
		local isEntry = IS.Items[itemID]

		-- loop through sources we found
		for _, entry in pairs(sources) do
			local entryStr = entryType .. "_" .. entry[1] .. "_" .. entry[3] .. "_" .. entry[2]

			-- skip if already in IS DB
			if not (isEntry and (strfind(";" .. isEntry .. ";", ";" .. entryStr .. ";"))) then
				if str then
					str = str .. ";" .. entryStr
				else
					str = entryStr
				end
			end

		end

		InspectEquipLocalDB.Items[itemID] = str
	end
end

local function GetInstanceCount(isRaid)
	local i = 1
	local id
	repeat
		id = EJ_GetInstanceByIndex(i, isRaid)
		i = i + 1
	until not id
	return i - 2
end

local function GetTotalLootCount(tierCount)
	local lootCount = 0
	local tier, i
	for tier = 1, tierCount do
		if mop then
			EJ_SelectTier(tier)
		end

		local isRaid = false
		while true do
			i = 1
			local insID, insName = EJ_GetInstanceByIndex(i, isRaid)

			while insID do
				EJ_SelectInstance(insID)
				local diff
				local diffOffset = (mop and isRaid) and 2 or 0
				local maxDiff = isRaid and 5 or 2
				for diff = 1, maxDiff do
					if EJ_IsValidInstanceDifficulty(diff + diffOffset) then
						EJ_SetDifficulty(diff)
						lootCount = lootCount + EJ_GetNumLoot()
					end
				end
				i = i + 1
				insID, insName = EJ_GetInstanceByIndex(i, isRaid)
			end

			if isRaid then
				break
			else
				isRaid = true
			end
		end
	end
	return lootCount
end

local function UpdateFunction(recursive)
	local _, i, j, tier

	-- reset EJ
	DisableEJ()
	EJ_ClearSearch()
	if mop then
		EJ_ResetLootFilter()
	else
		EJ_SetClassLootFilter(0)
	end
	newDataReceived = false
	IE:RegisterEvent("EJ_LOOT_DATA_RECIEVED")

	-- init/reset database
	local db = InspectEquipLocalDB
	db.Zones = {}
	db.Bosses = {}
	db.Items = {}
	db.NextZoneID = 1000
	db.NextBossID = 1000

	-- count total number of instances
	local insCount = 0
	local tierCount = 1
	if mop then
		-- as of 5.x there are multiple tiers (classic, bc, wotlk, cata, mop...)
		tierCount = EJ_GetNumTiers()
		for tier = 1, tierCount do
			local tierName = EJ_GetTierInfo(tier)
			EJ_SelectTier(tier)
			--IE:Print("Tier: " .. tostring(tier) .. " = " .. tierName)
			local dungeonCount = GetInstanceCount(false)
			local raidCount = GetInstanceCount(true)
			--IE:Print(" ==> " .. tostring(dungeonCount) .. " Dungeons, " .. tostring(raidCount) .. " Raids")
			insCount = insCount + dungeonCount + raidCount
		end
	else
		local dungeonCount = GetInstanceCount(false)
		local raidCount = GetInstanceCount(true)
		insCount = dungeonCount + raidCount
		--IE:Print(" ==> " .. tostring(dungeonCount) .. " Dungeons, " .. tostring(raidCount) .. " Raids")
	end

	-- set bar max value
	local startValue = bar:GetValue()
	bar:SetMinMaxValues(0, startValue + insCount + 2)

	-- get IS mapping for zone/boss name -> zone/boss id
	local zoneMap = GetReverseMapping(IS.Zones)
	local bossMap = GetReverseMapping(IS.Bosses)

	UpdateBar()

	-- temp db to allow for merging of modes
	local tempDungeonDB = {}
	local tempRaidDB = {}
	local totalLootCount = 0

	local waitCycles = 0
	-- get loot
	for tier = 1, tierCount do
		if mop then
			EJ_SelectTier(tier)
		end

		-- loop through all instances of this tier, dungeons first, then raids
		local isRaid = false
		while true do
			i = 1
			local insID, insName = EJ_GetInstanceByIndex(i, isRaid)
			local tempDB = isRaid and tempRaidDB or tempDungeonDB

			while insID do
				-- get zone id for db
				local zoneID = zoneMap[insName]
				if not zoneID then
					-- zone is not in db
					zoneID = db.NextZoneID
					db.Zones[zoneID] = insName
					zoneMap[insName] = zoneID
					db.NextZoneID = db.NextZoneID + 1
				end

				EJ_SelectInstance(insID)
				local diff
				local difficulties
				if legion then
					if isRaid then
						difficulties = {3, 4, 5, 6, 7, 14, 15, 16, 17}
					else
						difficulties = {1, 2, 8, 23}
					end
				elseif wod then
					if isRaid then
						difficulties = {3, 4, 5, 6, 7, 14, 15, 16, 17}
					else
						difficulties = {1, 2, 8, 23}
					end
				elseif mop then
					if isRaid then
						difficulties = {3, 4, 5, 6, 7, 14}
					else
						difficulties = {1, 2}
					end
				else
					-- not sure if this still works. probably not.
					if isRaid then
						difficulties = {1, 2, 3, 4, 5}
					else
						difficulties = {1, 2}
					end
				end
				for _, diff in ipairs(difficulties) do
					if EJ_IsValidInstanceDifficulty(diff) then
						newDataCycles = DATA_RECEIVED_WC * 3
						EJ_SetDifficulty(diff)
						local mode = DifficultyToMode(diff, isRaid)
						local n = EJ_GetNumLoot()

						-- the problem here is that when the items are not in the cache, EJ_GetNumLoot() will not
						-- return the correct number. it returns the number of items that are cached, which may be
						-- 0 or a number lower than the correct number. it seems to be impossible to determine the
						-- correct number without waiting. EJ_LOOT_DATA_RECIEVED events are received, but we don't
						-- know which event is the last one. also, no EJ_LOOT_DATA_RECIEVED are received if all
						-- items are already in the cache. so we try to wait a couple of frames until we have a
						-- number that is somehow stable.
						-- at the end we count all items again, and if we then have more items, we start all over
						-- again (at this point, the items are already cached, so the 2nd iteration is faster).
						local wc = 0
						local wcMax = MAX_WC
						while wc < wcMax do
							coroutine.yield()
							wc = wc + 1
							local nNew = EJ_GetNumLoot()
							if n ~= nNew then
								wcMax = wc + MAX_WC
							end
							n = nNew
						end
						waitCycles = waitCycles + wc

						totalLootCount = totalLootCount + n

						--IE:Print("T=" .. tostring(tier) .. " I=" .. insName .. " D=" .. diff .. " M=" .. mode .. " ! #loot = " .. n .. " [wc = " .. wc .. "]")

						for j = 1, n do
							-- get item info
							local itemID, encID, itemName, _, _, _, itemLink = EJ_GetLootInfoByIndex(j)

							-- wait until data has arrived
							-- this doesn't seem necessary
							-- while not itemID do
							--	coroutine.yield()
							--	waitCycles = waitCycles + 1
							--	itemName, _, _, _, itemID, itemLink, encID = EJ_GetLootInfoByIndex(j)
							-- end

							local encName = EJ_GetEncounterInfo(encID)

							-- if not encName then
							--	IE:Print("no encounter name! encID = " .. encID)
							-- end

							-- get boss id for db
							local bossID = bossMap[encName]
							if not bossID then
								-- boss is not in db
								bossID = db.NextBossID
								db.Bosses[bossID] = encName
								bossMap[encName] = bossID
								db.NextBossID = db.NextBossID + 1
							end

							-- add item to db
							AddToDB(tempDB, itemID, zoneID, bossID, mode)
						end

					end
				end

				-- next instance
				UpdateBar()
				i = i + 1
				insID, insName = EJ_GetInstanceByIndex(i, isRaid)
			end

			if isRaid then
				-- done with dungeons + raids, next tier
				break
			else
				-- done with dungeons, now do it again for raids
				isRaid = true
			end
		end
	end

	-- save to db
	SaveToDB(tempDungeonDB, "d")
	SaveToDB(tempRaidDB, "r")
	local _, currentBuild = GetBuildInfo()
	db.ClientBuild = currentBuild
	db.Locale = GetLocale()
	db.IEVersion = ieVersion
	db.Expansion = GetExpansionLevel()
	UpdateBar()

	-- Check loot count
	local lootCountVerification = GetTotalLootCount(tierCount)

	--IE:Print("totalLootCount = " .. totalLootCount .. " / lootCountVerification = " .. lootCountVerification)

	-- Check if EJ db is stable
	if totalLootCount < lootCountVerification then
		-- We missed some items, retry...
		--IE:Print("Restarting update...")
		UpdateFunction((recursive and recursive or 0) + 1)
	else
		-- Done
		EndUpdate()
		--IE:Print("Wait cycles = " .. waitCycles)
	end
end

function IE:EJ_LOOT_DATA_RECIEVED(event, itemID)
	-- self:Print("LOOT_DATA_RECEIVED [" .. (itemID and itemID or "nil") .. "]")
	newDataReceived = true
end

function IE:CreateLocalDatabase()

	if coUpdate then
		-- update already in progress
		return
	end

	-- load encounter journal
	if not IsAddOnLoaded("Blizzard_EncounterJournal") then
		local loaded, reason = LoadAddOn("Blizzard_EncounterJournal")
		if not loaded then
			message("[InspectEquip] Could not load encounter journal: " .. reason)
		end
	end

	-- show progress bar
	createUpdateGUI()
	bar:Show()

	-- start update
	coUpdate = coroutine.create(UpdateFunction)
	local ok, msg = coroutine.resume(coUpdate)
	if ok then
		bar:SetScript("OnUpdate", UpdateTick)
	else
		EndUpdate()
		message("[InspectEquip] Could not update database: " .. msg)
	end

end
