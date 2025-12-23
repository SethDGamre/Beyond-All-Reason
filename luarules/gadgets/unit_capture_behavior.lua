local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name      = 'Capture Behavior',
		desc      = 'Monitors units being captured and applies behavior changes when halfway captured',
		author    = 'AI Assistant',
		date      = '2025',
		license   = 'GNU GPL, v2 or later',
		layer     = 0,
		enabled   = true
	}
end

if not gadgetHandler:IsSyncedCode() then
	return false
end

local CMD_CAPTURE = CMD.CAPTURE
local CMD_FIRE_STATE = CMD.FIRE_STATE
local CMD_WAIT = CMD.WAIT
local CMD_STOP = CMD.STOP

local CHECK_INTERVAL = 1 -- frames
local WAIT_COOLDOWN = 10 * Game.gameSpeed -- 10 seconds in frames

local capturedUnits = {} -- unitID -> {originalFireState, waitCooldownExpires, isCurrentlyCaptured}
local spGetUnitHealth = Spring.GetUnitHealth
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetUnitStates = Spring.GetUnitStates
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand

function gadget:Initialize()
	Spring.Echo("[Capture Behavior] Gadget initialized")
end

function gadget:AllowUnitCaptureStep(builderID, builderTeam, unitID, unitDefID, part)
	-- Start monitoring this unit when capture actually begins
	if not capturedUnits[unitID] then
		local states = spGetUnitStates(unitID)
		capturedUnits[unitID] = {
			originalFireState = states.firestate,
			waitCooldownExpires = 0,
			isCurrentlyCaptured = true
		}
		Spring.Echo(string.format("[Capture Behavior] Started monitoring unit %d for capture (original fire state: %d)", unitID, states.firestate))
	else
		Spring.Echo(string.format("[Capture Behavior] Unit %d already being monitored for capture (part: %.4f)", unitID, part))
	end
	return true -- Allow the capture step
end

function gadget:GameFrame(frame)
	if frame % CHECK_INTERVAL ~= 0 then
		return
	end

	-- Debug: show we're checking (only every 30 frames to avoid spam)
	if frame % 30 == 0 and next(capturedUnits) then
		local count = 0
		for _ in pairs(capturedUnits) do count = count + 1 end
		Spring.Echo(string.format("[Capture Behavior] Checking %d captured units at frame %d", count, frame))
	end

	for unitID, data in pairs(capturedUnits) do
		if not Spring.ValidUnitID(unitID) then
			Spring.Echo(string.format("[Capture Behavior] Unit %d is no longer valid, removing from monitoring", unitID))
			capturedUnits[unitID] = nil
		else
			local health, maxHealth, paralyzeDamage, captureProgress = spGetUnitHealth(unitID)
			local wasCaptured = data.isCurrentlyCaptured

			if captureProgress and captureProgress > 0 then
				-- Unit is currently being captured
				data.isCurrentlyCaptured = true

				if captureProgress >= 0.5 and not data.halfwayApplied then
					-- Halfway captured, apply behavior changes
					Spring.Echo(string.format("[Capture Behavior] Unit %d reached halfway capture (%.2f), applying behavior changes", unitID, captureProgress))
					-- Set fire state to hold fire (0)
					spGiveOrderToUnit(unitID, CMD_FIRE_STATE, 0, 0)
					Spring.Echo(string.format("[Capture Behavior] Unit %d fire state set to hold fire (0)", unitID))
					-- Give stop command
					spGiveOrderToUnit(unitID, CMD_STOP, {}, 0)
					Spring.Echo(string.format("[Capture Behavior] Unit %d stop command issued", unitID))
					-- Give wait command with cooldown check
					if frame >= data.waitCooldownExpires then
						spGiveOrderToUnit(unitID, CMD_WAIT, 0, 0)
						data.waitCooldownExpires = frame + WAIT_COOLDOWN
						Spring.Echo(string.format("[Capture Behavior] Unit %d wait command issued, cooldown expires at frame %d", unitID, data.waitCooldownExpires))
					else
						local cooldownRemaining = data.waitCooldownExpires - frame
						Spring.Echo(string.format("[Capture Behavior] Unit %d wait command on cooldown, %d frames remaining", unitID, cooldownRemaining))
					end
					data.halfwayApplied = true
				elseif captureProgress < 0.5 then
					-- Not halfway yet, reset the halfway flag
					if data.halfwayApplied then
						Spring.Echo(string.format("[Capture Behavior] Unit %d capture progress dropped below 50%% (%.2f), resetting halfway flag", unitID, captureProgress))
					end
					data.halfwayApplied = false
				else
					-- Halfway behavior already applied, only log occasionally to avoid spam
					if frame % 30 == 0 then
						Spring.Echo(string.format("[Capture Behavior] Unit %d halfway behavior already applied (progress: %.2f)", unitID, captureProgress))
					end
				end
			else
				-- Unit is not currently being captured
				data.isCurrentlyCaptured = false

				if wasCaptured then
					-- Just stopped being captured, revert to original state
					Spring.Echo(string.format("[Capture Behavior] Unit %d capture ended, reverting to original state", unitID))
					if data.originalFireState then
						spGiveOrderToUnit(unitID, CMD_FIRE_STATE, data.originalFireState, 0)
						Spring.Echo(string.format("[Capture Behavior] Unit %d fire state restored to %d", unitID, data.originalFireState))
					end
					-- Remove wait command if it's active
					local currentCmdID = spGetUnitCurrentCommand(unitID)
					if currentCmdID == CMD_WAIT then
						spGiveOrderToUnit(unitID, CMD_WAIT, 0, 0)
						Spring.Echo(string.format("[Capture Behavior] Unit %d wait command removed", unitID))
					end
					data.halfwayApplied = false
				end
			end

			-- Check if cooldown has expired and remove from tracking
			if frame >= data.waitCooldownExpires and not data.isCurrentlyCaptured then
				Spring.Echo(string.format("[Capture Behavior] Unit %d cooldown expired and not captured, removing from monitoring", unitID))
				capturedUnits[unitID] = nil
			end
		end
	end
end

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam)
	if capturedUnits[unitID] then
		Spring.Echo(string.format("[Capture Behavior] Unit %d destroyed, removing from capture monitoring", unitID))
		capturedUnits[unitID] = nil
	end
end
