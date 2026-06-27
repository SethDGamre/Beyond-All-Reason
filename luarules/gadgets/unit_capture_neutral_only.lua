local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Capture Neutral Only",
		desc = "Units with capture_neutral_only can only capture Gaia team units",
		author = "Floris",
		date = "June 2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = Spring.GetModOptions().experimental_builder_claim,
	}
end

if not gadgetHandler:IsSyncedCode() then
	return
end

local spAreTeamsAllied = Spring.AreTeamsAllied
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetAllUnits = Spring.GetAllUnits

local gaiaTeamID = Spring.GetGaiaTeamID()
local ALL_UNITS = Spring.ALL_UNITS
local reissueOrder = Game.Commands.ReissueOrder

local neutralOnlyUnitDefIDs = {}

for unitDefID = 1, #UnitDefs do
	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.capture_neutral_only == "1" then
		neutralOnlyUnitDefIDs[unitDefID] = true
	end
end

local function isValidClaimTarget(targetUnitID, builderTeamID)
	if not targetUnitID then
		return false
	end
	local targetTeamID = spGetUnitTeam(targetUnitID)
	if not targetTeamID then
		return false
	end
	if targetTeamID == gaiaTeamID then
		return true
	end
	if spAreTeamsAllied(builderTeamID, targetTeamID) then
		return false
	end
	return spGetUnitIsBeingBuilt(targetUnitID) == true
end

local function buildGiveOrderOptions(cmdOptions, useShift)
	local options = {}
	if useShift or cmdOptions.shift then
		options[#options + 1] = "shift"
	end
	if cmdOptions.alt then
		options[#options + 1] = "alt"
	end
	if cmdOptions.ctrl then
		options[#options + 1] = "ctrl"
	end
	if cmdOptions.meta then
		options[#options + 1] = "meta"
	end
	if cmdOptions.right then
		options[#options + 1] = "right"
	end
	if #options == 0 then
		return cmdOptions
	end
	return options
end

local function getValidClaimTargetsInArea(cmdX, cmdZ, radius, builderTeamID)
	local validTargets = {}
	local seenTargets = {}

	local gaiaUnits = spGetUnitsInCylinder(cmdX, cmdZ, radius, gaiaTeamID)
	if gaiaUnits then
		for i = 1, #gaiaUnits do
			local targetUnitID = gaiaUnits[i]
			if not seenTargets[targetUnitID] then
				seenTargets[targetUnitID] = true
				validTargets[#validTargets + 1] = targetUnitID
			end
		end
	end

	local unitsInArea = spGetUnitsInCylinder(cmdX, cmdZ, radius, ALL_UNITS)
	if unitsInArea then
		for i = 1, #unitsInArea do
			local targetUnitID = unitsInArea[i]
			if not seenTargets[targetUnitID] and isValidClaimTarget(targetUnitID, builderTeamID) then
				seenTargets[targetUnitID] = true
				validTargets[#validTargets + 1] = targetUnitID
			end
		end
	end

	return validTargets
end

local function cancelCaptureOrdersOnTarget(targetUnitID)
	local allUnits = spGetAllUnits()
	for i = 1, #allUnits do
		local builderID = allUnits[i]
		local builderDefID = spGetUnitDefID(builderID)
		if neutralOnlyUnitDefIDs[builderDefID] then
			local tags = {}
			local tagCount = 0
			for index = 1, spGetUnitCommandCount(builderID) do
				local command, _, tag, targetID = spGetUnitCurrentCommand(builderID, index)
				if command == CMD.CAPTURE and targetID == targetUnitID then
					tagCount = tagCount + 1
					tags[tagCount] = tag
				end
			end
			if tagCount > 0 then
				spGiveOrderToUnit(builderID, CMD.REMOVE, tags)
			end
		end
	end
end

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, cmdTag, fromSynced, fromLua, fromInsert)
	if not neutralOnlyUnitDefIDs[unitDefID] then
		return true
	end

	local nParams = #cmdParams

	if nParams == 1 or nParams == 5 then
		local targetUnitID = cmdParams[1]
		return isValidClaimTarget(targetUnitID, teamID)
	elseif nParams == 4 then
		if cmdOptions.ctrl then
			cmdOptions.ctrl = false
			reissueOrder(unitID, cmdID, cmdParams, cmdOptions, cmdTag, fromInsert)
			return false
		end
		local cmdX, cmdZ, radius = cmdParams[1], cmdParams[3], cmdParams[4]
		local validTargets = getValidClaimTargetsInArea(cmdX, cmdZ, radius, teamID)
		for i = 1, #validTargets do
			spGiveOrderToUnit(unitID, CMD.CAPTURE, { validTargets[i] }, buildGiveOrderOptions(cmdOptions, i > 1))
		end
		return false
	end
	return false
end

function gadget:AllowUnitCaptureStep(builderID, builderTeam, unitID, unitDefID, part)
	local builderDefID = spGetUnitDefID(builderID)
	if not neutralOnlyUnitDefIDs[builderDefID] then
		return true
	end
	return isValidClaimTarget(unitID, builderTeam)
end

function gadget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == gaiaTeamID then
		return
	end
	cancelCaptureOrdersOnTarget(unitID)
end

function gadget:Initialize()
	gadgetHandler:RegisterAllowCommand(CMD.CAPTURE)
end
