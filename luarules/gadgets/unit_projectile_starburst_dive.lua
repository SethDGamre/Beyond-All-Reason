local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Starburst Dive Targeting",
		desc = "Retargets starburst missiles to a sky waypoint, then restores the original target for a vertical dive",
		author = "SethDGamre",
		layer = 1,
		enabled = true
	}
end

local ORIGINAL_TARGET_SYNC_ACTION = "starburstDiveOriginalTarget"

if not gadgetHandler:IsSyncedCode() then
	local function forwardOriginalTarget(_, proID, targetX, targetY, targetZ)
		if Script.LuaUI("StarburstDiveOriginalTarget") then
			Script.LuaUI.StarburstDiveOriginalTarget(proID, targetX, targetY, targetZ)
		end
	end

	function gadget:Initialize()
		gadgetHandler:AddSyncAction(ORIGINAL_TARGET_SYNC_ACTION, forwardOriginalTarget)
	end

	function gadget:Shutdown()
		gadgetHandler:RemoveSyncAction(ORIGINAL_TARGET_SYNC_ACTION)
	end

	return
end

local CallAsTeam = CallAsTeam
local mathCos = math.cos
local mathFloor = math.floor
local mathMax = math.max
local mathMin = math.min
local mathPi = math.pi
local mathSin = math.sin
local mathSqrt = math.sqrt
local spGetGroundHeight = Spring.GetGroundHeight
local spGetProjectileOwnerID = Spring.GetProjectileOwnerID
local spGetProjectilePosition = Spring.GetProjectilePosition
local spGetProjectileTarget = Spring.GetProjectileTarget
local spGetProjectileTeamID = Spring.GetProjectileTeamID
local spGetProjectileVelocity = Spring.GetProjectileVelocity
local spGetUnitIsDead = Spring.GetUnitIsDead
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitTeam = Spring.GetUnitTeam
local spSetProjectileTarget = Spring.SetProjectileTarget

local TARGETED_GROUND = string.byte('g')
local TARGETED_UNIT = string.byte('u')

local defWatchTable = {}
local proData = {}
local restoreWatch = {}

local readAs = { read = -1 }

local function readAsTeam(teamID, ...)
	local read = readAs
	read.read = teamID or -1
	return CallAsTeam(read, ...)
end

local function calculateDistanceForFrames(initialVelocity, maximumVelocity, accelerationRate, frames)
	if frames <= 0 then
		return 0
	end
	if accelerationRate <= 0 then
		return maximumVelocity * frames
	end

	local framesToMaxVelocity = (maximumVelocity - initialVelocity) / accelerationRate
	if frames <= framesToMaxVelocity then
		return initialVelocity * frames + 0.5 * accelerationRate * frames ^ 2
	end

	local distanceAccelerating = initialVelocity * framesToMaxVelocity + 0.5 * accelerationRate * framesToMaxVelocity ^ 2
	return distanceAccelerating + maximumVelocity * (frames - framesToMaxVelocity)
end

local function calculateTurnDisplacement(initialVelocity, maximumVelocity, accelerationRate, turnRate)
	if turnRate <= 0 or initialVelocity <= 0 then
		return 0, 0
	end
	if accelerationRate <= 0 or initialVelocity >= maximumVelocity then
		local radius = mathMin(initialVelocity, maximumVelocity) / turnRate
		return radius, radius
	end

	local turnFrames = mathPi * 0.5 / turnRate
	local framesToMaximumVelocity = (maximumVelocity - initialVelocity) / accelerationRate
	if framesToMaximumVelocity >= turnFrames then
		local inverseTurnRate = 1 / turnRate
		local inverseTurnRateSquared = inverseTurnRate * inverseTurnRate
		local horizontalDistance = initialVelocity * inverseTurnRate + accelerationRate * inverseTurnRateSquared * (mathPi * 0.5 - 1)
		local verticalDistance = initialVelocity * inverseTurnRate + accelerationRate * inverseTurnRateSquared
		return horizontalDistance, verticalDistance
	end

	local maximumVelocityAngle = turnRate * framesToMaximumVelocity
	local sine = mathSin(maximumVelocityAngle)
	local cosine = mathCos(maximumVelocityAngle)
	local inverseTurnRate = 1 / turnRate
	local inverseTurnRateSquared = inverseTurnRate * inverseTurnRate
	local horizontalDistance = initialVelocity * sine * inverseTurnRate
		+ accelerationRate * (framesToMaximumVelocity * sine * inverseTurnRate + (cosine - 1) * inverseTurnRateSquared)
		+ maximumVelocity * (1 - sine) * inverseTurnRate
	local verticalDistance = initialVelocity * (1 - cosine) * inverseTurnRate
		+ accelerationRate * (-framesToMaximumVelocity * cosine * inverseTurnRate + sine * inverseTurnRateSquared)
		+ maximumVelocity * cosine * inverseTurnRate
	return horizontalDistance, verticalDistance
end

local function setRestoreFrame(proID, newFlightTime)
	local triggerFrame = Spring.GetGameFrame() + mathMax(1, newFlightTime)
	restoreWatch[triggerFrame] = restoreWatch[triggerFrame] or {}
	restoreWatch[triggerFrame][#restoreWatch[triggerFrame] + 1] = proID
end

local function cleanupProjectile(proID)
	proData[proID] = nil
end

local function restoreOriginalTarget(proID, data)
	if data.originalTargetType == TARGETED_UNIT then
		if spGetUnitIsDead(data.originalTarget) == false then
			spSetProjectileTarget(proID, data.originalTarget, TARGETED_UNIT)
		else
			local groundY = mathMax(spGetGroundHeight(data.targetX, data.targetZ), 0)
			spSetProjectileTarget(proID, data.targetX, groundY, data.targetZ)
		end
	else
		local target = data.originalTarget
		spSetProjectileTarget(proID, target[1], target[2], target[3])
	end
	cleanupProjectile(proID)
end

local function customParamIsTrue(value)
	return value == true or value == 1 or value == "1" or value == "true"
end

local function resolveTargetPosition(proID, targetType, target)
	if targetType == TARGETED_UNIT then
		local teamID = spGetProjectileTeamID(proID) or spGetUnitTeam(spGetProjectileOwnerID(proID) or -1)
		local _, _, _, targetX, targetY, targetZ = readAsTeam(teamID, spGetUnitPosition, target, false, true)
		return targetX, targetY, targetZ
	elseif targetType == TARGETED_GROUND then
		return target[1], target[2], target[3]
	end
end

local function resolveUnitGroundPosition(proID, unitID)
	local teamID = spGetProjectileTeamID(proID) or spGetUnitTeam(spGetProjectileOwnerID(proID) or -1)
	local unitX, _, unitZ = readAsTeam(teamID, spGetUnitPosition, unitID)
	if not unitX or not unitZ then
		return
	end
	local groundY = mathMax(spGetGroundHeight(unitX, unitZ), 0)
	return unitX, groundY, unitZ
end

for weaponDefID, weaponDef in pairs(WeaponDefs) do
	if weaponDef.type == "StarburstLauncher" and (not weaponDef.interceptor or weaponDef.interceptor == 0) then
		local turnRate = weaponDef.turnRate or 0
		local fullUptimeFrames = mathMax(0, mathFloor(weaponDef.uptime * Game.gameSpeed))
		local initialVelocity = weaponDef.startvelocity
		local maximumVelocity = weaponDef.projectilespeed
		local accelerationRate = weaponDef.weaponAcceleration
		local ascentHeight = calculateDistanceForFrames(initialVelocity, maximumVelocity, accelerationRate, fullUptimeFrames)

		defWatchTable[weaponDefID] = {
			ascentFrames = fullUptimeFrames,
			ascentHeight = ascentHeight,
			fullUptimeFrames = fullUptimeFrames,
			maximumVelocity = maximumVelocity,
			accelerationRate = accelerationRate,
			turnRate = turnRate,
			trackingActuallyFalse = customParamIsTrue(weaponDef.customParams and weaponDef.customParams.tracking_actually_false),
		}
		Script.SetWatchProjectile(weaponDefID, true)
	end
end

function gadget:ProjectileCreated(proID, proOwnerID, weaponDefID)
	local defData = defWatchTable[weaponDefID]
	if not defData then return end

	local targetType, target = spGetProjectileTarget(proID)
	if not targetType then return end

	local originalTargetType = targetType
	local originalTarget = target
	local targetX, targetY, targetZ

	if defData.trackingActuallyFalse and targetType == TARGETED_UNIT then
		targetX, targetY, targetZ = resolveUnitGroundPosition(proID, target)
		if not targetX then return end
		originalTargetType = TARGETED_GROUND
		originalTarget = { targetX, targetY, targetZ }
	else
		targetX, targetY, targetZ = resolveTargetPosition(proID, targetType, target)
		if not targetX or not targetZ then return end
		if targetType == TARGETED_GROUND then
			originalTarget = { target[1], target[2], target[3] }
		end
	end

	local originX, _, originZ = spGetUnitPosition(proOwnerID)
	local _, createdY = spGetProjectilePosition(proID)
	if not originX then
		originX, _, originZ = spGetProjectilePosition(proID)
	end
	if not originX or not originZ then return end

	local groundY = mathMax(spGetGroundHeight(targetX, targetZ), 0)
	local skyY = (createdY or groundY) + defData.ascentHeight
	SendToUnsynced(ORIGINAL_TARGET_SYNC_ACTION, proID, targetX, groundY, targetZ)
	spSetProjectileTarget(proID, targetX, skyY, targetZ)

	proData[proID] = {
		weaponDefID = weaponDefID,
		originalTargetType = originalTargetType,
		originalTarget = originalTarget,
		targetX = targetX,
		targetZ = targetZ,
		createdFrame = Spring.GetGameFrame(),
	}

	setRestoreFrame(proID, mathMax(1, defData.ascentFrames))
end

function gadget:ProjectileDestroyed(proID)
	SendToUnsynced(ORIGINAL_TARGET_SYNC_ACTION, proID)
	cleanupProjectile(proID)
end

function gadget:GameFrame(frame)
	local frameWatch = restoreWatch[frame]
	if not frameWatch then return end

	for _, proID in ipairs(frameWatch) do
		local data = proData[proID]
		if data then
			local projectileX, projectileY, projectileZ = spGetProjectilePosition(proID)
			if projectileX then
				local deltaX = projectileX - data.targetX
				local deltaZ = projectileZ - data.targetZ
				local dist = mathSqrt(deltaX * deltaX + deltaZ * deltaZ)
				local ageFrames = frame - (data.createdFrame or frame)
				local fullUptimeFrames = defWatchTable[data.weaponDefID].fullUptimeFrames
				if ageFrames >= fullUptimeFrames then
					spSetProjectileTarget(proID, data.targetX, projectileY, data.targetZ)
				end
				local weaponData = defWatchTable[data.weaponDefID]
				local velocityX, velocityY, velocityZ = spGetProjectileVelocity(proID)
				if not velocityX or not velocityZ then
					cleanupProjectile(proID)
				else
					local horizontalSpeed = mathSqrt(velocityX * velocityX + velocityZ * velocityZ)
					local predictedHorizontalTurnDistance = calculateTurnDisplacement(
						horizontalSpeed,
						weaponData.maximumVelocity,
						weaponData.accelerationRate,
						weaponData.turnRate
					)
					if dist > predictedHorizontalTurnDistance then
						setRestoreFrame(proID, 1)
					else
						restoreOriginalTarget(proID, data)
					end
				end
			else
				cleanupProjectile(proID)
			end
		end
	end
	restoreWatch[frame] = nil
end
