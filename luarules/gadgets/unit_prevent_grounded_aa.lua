function gadget:GetInfo()
	return {
		name      = "Prevent Grounded AA",
		desc      = "Prevents AA weapons that can only target VTOL from shooting at landed aircraft",
		author    = "SethDGamre",
		date      = "October 2025",
		license   = "GNU GPL, v2 or later",
		layer     = 0,
		enabled   = true
	}
end

if not gadgetHandler:IsSyncedCode() then
	return false
end

local spSetUnitRulesParam = Spring.SetUnitRulesParam
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitPosition = Spring.GetUnitPosition
local spGetGroundHeight = Spring.GetGroundHeight
local spSetUnitTarget = Spring.SetUnitTarget
local spGetAllUnits = Spring.GetAllUnits
local spGetUnitDefID = Spring.GetUnitDefID

local INLOS_ACCESS = {inlos = true}

local vtolOnlyWeaponDefs = {}
local canFlyUnitDef = {}
local flyingUnits = {}
local targetedFlyers = {}

for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.weapons and #unitDef.weapons > 0 then
		for i = 1, #unitDef.weapons do
			local weapon = unitDef.weapons[i]
			local weaponDefID = weapon.weaponDef

			if weapon.onlyTargets and weapon.onlyTargets.vtol then
				local hasOtherTargets = false
				for category, enabled in pairs(weapon.onlyTargets) do
					if category ~= "vtol" and enabled then
						hasOtherTargets = true
						break
					end
				end

				if not hasOtherTargets then
					vtolOnlyWeaponDefs[weaponDefID] = true
					Script.SetWatchAllowTarget(weapon.weaponDef, true)
				end
			end
		end
	end

	if unitDef.canFly then
		canFlyUnitDef[unitDefID] = true
	end
end

function gadget:UnitEnteredAir(unitID, unitDefID)
	if canFlyUnitDef[unitDefID] then
		spSetUnitRulesParam(unitID, "isFlying", 1, INLOS_ACCESS)
		flyingUnits[unitID] = true
	end
end

local function clearTargetsAttackers(unitID)
	if targetedFlyers[unitID] then
		for attackerID, _ in pairs(targetedFlyers[unitID]) do
			spSetUnitTarget(attackerID, nil)
		end
		targetedFlyers[unitID] = nil
	end
end

function gadget:UnitLeftAir(unitID, unitDefID)
	if canFlyUnitDef[unitDefID] then
		spSetUnitRulesParam(unitID, "isFlying", nil, INLOS_ACCESS)
		flyingUnits[unitID] = nil
		clearTargetsAttackers(unitID)
	end
end

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	flyingUnits[unitID] = nil
	targetedFlyers[unitID] = nil
end

function gadget:AllowWeaponTarget(attackerID, targetID, attackerWeaponNum, attackerWeaponDefID, defPriority)
	if targetID == -1 and attackerWeaponNum == -1 then
		return true, defPriority or 1.0
	end

	if not vtolOnlyWeaponDefs[attackerWeaponDefID] then
		targetedFlyers[targetID] = targetedFlyers[targetID] or {}
		targetedFlyers[targetID][attackerID] = true
		return true, defPriority or 1.0
	end

	if flyingUnits[targetID] and spGetUnitRulesParam(targetID, "drone_docked_untargetable") ~= 1 then
		return true, defPriority or 1.0
	end

	return false, defPriority or 0
end

function gadget:Initialize()
	local allUnits = spGetAllUnits()
	for i = 1, #allUnits do
		local unitID = allUnits[i]
		local unitDefID = spGetUnitDefID(unitID)
		if canFlyUnitDef[unitDefID] then
			local x, y, z = spGetUnitPosition(unitID)
			if x and y and z then
				local groundHeight = spGetGroundHeight(x, z)
				if y > groundHeight then
					spSetUnitRulesParam(unitID, "isFlying", 1, INLOS_ACCESS)
					flyingUnits[unitID] = true
				else
					spSetUnitRulesParam(unitID, "isFlying", nil, INLOS_ACCESS)
				end
			end
		end
	end
end