local widget = widget ---@type Widget

local ClaimApi = VFS.Include("luaui/Include/claim_api.lua")

function widget:GetInfo()
	return {
		name = "Claim Cursor",
		desc = "Shows valid/invalid cursor for builder claim command",
		author = "Floris",
		date = "June 2026",
		license = "GNU GPL, v2 or later",
		layer = 99999,
		handler = true,
		enabled = ClaimApi.IsModEnabled(),
	}
end

local spGetActiveCommand = Spring.GetActiveCommand
local spGetMouseState = Spring.GetMouseState
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetUnitTeam = Spring.GetUnitTeam
local spSetMouseCursor = Spring.SetMouseCursor
local spTraceScreenRay = Spring.TraceScreenRay

local function isValidClaimTarget(unitID)
	return unitID and spGetUnitTeam(unitID) == ClaimApi.GetGaiaTeamID()
end

function widget:Update()
	if Spring.IsGUIHidden() then
		return
	end

	local _, cmdID = spGetActiveCommand()
	if cmdID ~= CMD.CAPTURE then
		return
	end

	local selectedUnits = spGetSelectedUnits()
	if not ClaimApi.SelectionIsClaimOnly(selectedUnits) then
		return
	end

	local mx, my = spGetMouseState()
	local targetType, targetUnitID = spTraceScreenRay(mx, my, false)

	if targetType == "unit" and isValidClaimTarget(targetUnitID) then
		spSetMouseCursor("Capture")
	else
		spSetMouseCursor("cursorbuildbad")
	end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
	if cmdID ~= CMD.CAPTURE then
		return false
	end

	local selectedUnits = spGetSelectedUnits()
	if not ClaimApi.SelectionIsClaimOnly(selectedUnits) then
		return false
	end

	if #cmdParams == 1 then
		local targetUnitID = cmdParams[1]
		if not isValidClaimTarget(targetUnitID) then
			return true
		end
	end

	return false
end

function widget:Initialize()
	WG.claim = ClaimApi
end

function widget:Shutdown()
	WG.claim = nil
end
