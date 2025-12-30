local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Pre-aim",
		desc = "Makes units preaim their weapons before its actually in range'",
		author = "Doo, Floris",
		date = "April 2018",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
	}
end

if not gadgetHandler:IsSyncedCode() then
	return
end

local spSetUnitWeaponState = Spring.SetUnitWeaponState
local spGetUnitWeaponTarget = Spring.GetUnitWeaponTarget
local spGetGameFrame = Spring.GetGameFrame

--use weaponDef.customparams.exclude_preaim = true to exclude units from being able to pre-aim at targets almost within firing range.
--this is a good idea for pop-up turrets so they don't prematurely reveal themselves.
--also when proximityPriority is heavily biased toward far targets

local autoTargetRangeBoost = {}
local proximityPriorityUnits = {}
local gameFrameCheckInterval = math.floor(Game.gameSpeed * 0.5)
local nextCheckFrame = 0
local unitsWithBoost = {}
local activeProximityUnits = {}

for unitDefID, unitDef in pairs(UnitDefs) do
	if not unitDef.canFly then
		local weaponBoost = {}
		local hasProximityPriority = false

		local weapons = unitDef.weapons
		for i = 1, #weapons do
			local weaponDefID = weapons[i].weaponDef
			local weaponDef = WeaponDefs[weaponDefID]

			if weaponDef.proximityPriority and weaponDef.proximityPriority < 0 then
				hasProximityPriority = true
			end

			if not weaponDef.customParams.exclude_preaim then
				local range = weaponDef.range
				local param = tonumber(weaponDef.customParams.preaim_range)
				local boost = math.max(20, range * 0.10, (param or 0) - range)
				weaponBoost[i] = boost
			end
		end

		if next(weaponBoost) then
			autoTargetRangeBoost[unitDefID] = weaponBoost
		end

		if hasProximityPriority then
			proximityPriorityUnits[unitDefID] = true
		end
	end
end

function gadget:UnitCreated(unitID, unitDefID)
	local unitData = autoTargetRangeBoost[unitDefID]
	if unitData then
		for weaponNum, rangeBoost in pairs(unitData) do
			spSetUnitWeaponState(unitID, weaponNum, "autoTargetRangeBoost", rangeBoost)
		end
	end

	if proximityPriorityUnits[unitDefID] then
		activeProximityUnits[unitID] = true
	end
end

function gadget:UnitDestroyed(unitID, unitDefID)
	activeProximityUnits[unitID] = nil
	unitsWithBoost[unitID] = nil
end

function gadget:GameFrame(gameFrame)
	if gameFrame < nextCheckFrame then
		return
	end
	nextCheckFrame = gameFrame + gameFrameCheckInterval

	for unitID in pairs(activeProximityUnits) do
		local hasTarget = false
		local unitDefID = Spring.GetUnitDefID(unitID)
		if unitDefID and autoTargetRangeBoost[unitDefID] then
			local unitData = autoTargetRangeBoost[unitDefID]
			for weaponNum in pairs(unitData) do
				local targetType, _, target = spGetUnitWeaponTarget(unitID, weaponNum)
				if target then
					hasTarget = true
					break
				end
			end

			local currentlyHasBoost = unitsWithBoost[unitID]
			if hasTarget and currentlyHasBoost then
				-- Remove boost
				for weaponNum in pairs(unitData) do
					spSetUnitWeaponState(unitID, weaponNum, "autoTargetRangeBoost", 0)
				end
				unitsWithBoost[unitID] = nil
			elseif not hasTarget and not currentlyHasBoost then
				-- Apply boost
				for weaponNum, rangeBoost in pairs(unitData) do
					spSetUnitWeaponState(unitID, weaponNum, "autoTargetRangeBoost", rangeBoost)
				end
				unitsWithBoost[unitID] = true
			end
		end
	end
end
