if not gadgetHandler:IsSyncedCode() then
	return
end

local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Capture Neutral Description",
		desc = "Replaces Capture with Claim for neutral-only capture units",
		author = "Floris",
		date = "June 2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = Spring.GetModOptions().experimental_builder_claim,
	}
end

local spEditUnitCmdDesc = Spring.EditUnitCmdDesc
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc

local claimUnitDefIDs = {}

for unitDefID = 1, #UnitDefs do
	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.capture_neutral_only == "1" then
		claimUnitDefIDs[unitDefID] = true
	end
end

local function applyClaimDesc(unitID, unitDefID)
	if not claimUnitDefIDs[unitDefID] then
		return
	end
	local cmdDesc = spFindUnitCmdDesc(unitID, CMD.CAPTURE)
	if cmdDesc then
		spEditUnitCmdDesc(unitID, cmdDesc, { action = "claim" })
	end
end

function gadget:UnitCreated(unitID, unitDefID)
	applyClaimDesc(unitID, unitDefID)
end

function gadget:Initialize()
	for _, unitID in ipairs(Spring.GetAllUnits()) do
		applyClaimDesc(unitID, Spring.GetUnitDefID(unitID))
	end
end
