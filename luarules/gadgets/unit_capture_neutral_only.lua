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

local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGiveOrderToUnit = Spring.GiveOrderToUnit

local gaiaTeamID = Spring.GetGaiaTeamID()
local reissueOrder = Game.Commands.ReissueOrder

local neutralOnlyUnitDefIDs = {}

for unitDefID = 1, #UnitDefs do
	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.capture_neutral_only == "1" then
		neutralOnlyUnitDefIDs[unitDefID] = true
	end
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

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, cmdTag, fromSynced, fromLua, fromInsert)
	if not neutralOnlyUnitDefIDs[unitDefID] then
		return true
	end

	local nParams = #cmdParams

	if nParams == 1 or nParams == 5 then
		local targetUnitID = cmdParams[1]
		local targetTeamID = targetUnitID and spGetUnitTeam(targetUnitID)
		if targetTeamID then
			return targetTeamID == gaiaTeamID
		end
	elseif nParams == 4 then
		if cmdOptions.ctrl then
			cmdOptions.ctrl = false
			reissueOrder(unitID, cmdID, cmdParams, cmdOptions, cmdTag, fromInsert)
			return false
		end
		local cmdX, cmdZ, radius = cmdParams[1], cmdParams[3], cmdParams[4]
		local gaiaUnits = spGetUnitsInCylinder(cmdX, cmdZ, radius, gaiaTeamID)
		if gaiaUnits then
			for i = 1, #gaiaUnits do
				spGiveOrderToUnit(unitID, CMD.CAPTURE, { gaiaUnits[i] }, buildGiveOrderOptions(cmdOptions, i > 1))
			end
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
	return spGetUnitTeam(unitID) == gaiaTeamID
end

function gadget:Initialize()
	gadgetHandler:RegisterAllowCommand(CMD.CAPTURE)
end
