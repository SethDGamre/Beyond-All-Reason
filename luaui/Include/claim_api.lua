local ClaimApi = {}

local gaiaTeamID = Spring.GetGaiaTeamID()
local modEnabled = Spring.GetModOptions().experimental_builder_claim == true
local claimUnitDefIDs = {}

if modEnabled then
	for unitDefID, unitDef in pairs(UnitDefs) do
		if unitDef.customParams and unitDef.customParams.capture_neutral_only == "1" then
			claimUnitDefIDs[unitDefID] = true
		end
	end
end

function ClaimApi.IsModEnabled()
	return modEnabled
end

function ClaimApi.IsClaimUnitDef(unitDefID)
	return claimUnitDefIDs[unitDefID] == true
end

function ClaimApi.GetGaiaTeamID()
	return gaiaTeamID
end

function ClaimApi.IsValidClaimTarget(unitID)
	return Spring.GetUnitTeam(unitID) == gaiaTeamID
end

function ClaimApi.SelectionIsClaimOnly(selectedUnits)
	if not modEnabled then
		return false
	end
	local hasClaimUnit = false
	local hasNonClaimCaptureUnit = false
	for i = 1, #selectedUnits do
		local unitDefID = Spring.GetUnitDefID(selectedUnits[i])
		local unitDef = UnitDefs[unitDefID]
		if unitDef and unitDef.canCapture and unitDef.buildDistance and unitDef.buildDistance > 0 then
			if claimUnitDefIDs[unitDefID] then
				hasClaimUnit = true
			else
				hasNonClaimCaptureUnit = true
			end
		end
	end
	return hasClaimUnit and not hasNonClaimCaptureUnit
end

return ClaimApi
