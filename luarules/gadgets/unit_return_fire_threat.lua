wlocal gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Return Fire Threat",
		desc = "Virtualizes return fire with threat-based target filtering",
		author = "SethDGamre",
		date = "2026.06.26",
		license = "GNU GPL, v2 or later",
		layer = -1,
		enabled = true
	}
end

if not gadgetHandler:IsSyncedCode() then
	return false
end

local DEBUG_DEFENSIVE_TARGETING = true
local ACCURACY_RANGE_FRACTION = 0.75
local THREAT_MARGIN = 1.25

local CMD_FIRE_STATE = CMD.FIRE_STATE
local FIRE_STATE_RETURN_FIRE = 1
local FIRE_STATE_FIRE_AT_WILL = 2
local RETURN_FIRE_RULES_PARAM = "returnFireVirtual"
local INLOS_TRUE = {inlos = true}
local FIRE_STATE_PARAMS = {"Passive", "Defensive", "Aggressive", "Fire at neutral"}

local spEditUnitCmdDesc = Spring.EditUnitCmdDesc
local spEcho = Spring.Echo
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
local spGetAllUnits = Spring.GetAllUnits
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitStates = Spring.GetUnitStates
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spSetUnitRulesParam = Spring.SetUnitRulesParam
local mathDistance2dSquared = math.distance2dSquared
local mathSqrt = math.sqrt
local mathMax = math.max
local mathDiag = math.diag
local stringFormat = string.format

local footprintElmos = Game.footprintScale * Game.squareSize

local eligibleUnitDef = {}
local attackerEffectiveDps = {}
local unitThreatData = {}
local smallestTargetRadius = 0
local watchedWeaponDef = {}
local applyingFireState = false

local function debugLog(message)
	if DEBUG_DEFENSIVE_TARGETING then
		spEcho("[defensiveTargeting] " .. message)
	end
end

local function getUnitDefName(unitDefID)
	local unitDef = unitDefID and UnitDefs[unitDefID]
	return unitDef and unitDef.name or "unknown"
end

local function isQualifyingWeapon(unitDef, weapon)
	local weaponDef = WeaponDefs[weapon.weaponDef]
	return weaponDef
		and weaponDef.range
		and weaponDef.range > 0
		and weapon.slavedTo == 0
		and not weaponDef.customParams.bogus
		and not (unitDef.canManualFire and weaponDef.manualFire)
end

local function getUnitRadius(unitDef)
	return mathDiag(unitDef.xsize * footprintElmos, unitDef.zsize * footprintElmos) * 0.5
end

local function getWeaponSpreadAtRange(weaponDef, rangeFraction)
	local weaponRange = weaponDef.range or 0
	if weaponRange <= 0 then
		return 0
	end
	local scatter = (weaponDef.accuracy or 0) + (weaponDef.sprayAngle or 0)
	local rangeAtEval = weaponRange * rangeFraction
	return mathMax(weaponDef.damageAreaOfEffect or 0, rangeAtEval * scatter)
end

local function getWeaponAccuracyFactor(weaponDef)
	local spreadAtEval = getWeaponSpreadAtRange(weaponDef, ACCURACY_RANGE_FRACTION)
	if spreadAtEval <= 0 then
		return 1
	end
	local damageRadius = mathMax(weaponDef.damageAreaOfEffect or 0, smallestTargetRadius)
	if damageRadius >= spreadAtEval then
		return 1
	end
	local ratio = damageRadius / spreadAtEval
	return ratio * ratio
end

local function calculateWeaponDps(weaponDef)
	local damages = weaponDef.damages
	local damage = damages and damages[0]
	local reload = weaponDef.reload
	if not damage or damage <= 0 or not reload or reload <= 0 then
		return 0
	end
	local salvoSize = weaponDef.salvoSize or 1
	local projectiles = weaponDef.projectiles or 1
	return damage * salvoSize * projectiles / reload
end

local function calculateWeaponEffectiveDps(weaponDef)
	return calculateWeaponDps(weaponDef) * getWeaponAccuracyFactor(weaponDef)
end

local function getFireStateCmdParams(unitID, state)
	local cmdDescID = spFindUnitCmdDesc(unitID, CMD_FIRE_STATE)
	if cmdDescID then
		local cmdDescs = spGetUnitCmdDescs(unitID)
		local cmdDesc = cmdDescs and cmdDescs[cmdDescID]
		local params = cmdDesc and cmdDesc.params
		if params then
			local newParams = {}
			for i = 1, #params do
				newParams[i] = params[i]
			end
			newParams[1] = state
			return cmdDescID, newParams
		end
	end

	return cmdDescID, {state, FIRE_STATE_PARAMS[1], FIRE_STATE_PARAMS[2], FIRE_STATE_PARAMS[3], FIRE_STATE_PARAMS[4]}
end

local function setFireStateCmdDesc(unitID, state)
	local cmdDescID, params = getFireStateCmdParams(unitID, state)
	if cmdDescID then
		spEditUnitCmdDesc(unitID, cmdDescID, {params = params})
	end
end

local function clearVirtualReturnFire(unitID, state)
	if spGetUnitRulesParam(unitID, RETURN_FIRE_RULES_PARAM) == 1 then
		spSetUnitRulesParam(unitID, RETURN_FIRE_RULES_PARAM, 0, INLOS_TRUE)
		debugLog(stringFormat(
			"exit defensive mode unitID=%d def=%s newState=%s",
			unitID,
			getUnitDefName(spGetUnitDefID(unitID)),
			tostring(state)
		))
	end
	if state then
		setFireStateCmdDesc(unitID, state)
	end
end

local function setVirtualReturnFire(unitID, source)
	local unitDefID = spGetUnitDefID(unitID)
	spSetUnitRulesParam(unitID, RETURN_FIRE_RULES_PARAM, 1, INLOS_TRUE)
	debugLog(stringFormat(
		"enter defensive mode unitID=%d def=%s source=%s engineState=%d",
		unitID,
		getUnitDefName(unitDefID),
		source,
		FIRE_STATE_FIRE_AT_WILL
	))
	applyingFireState = true
	spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRE_STATE_FIRE_AT_WILL}, 0)
	applyingFireState = false
	setFireStateCmdDesc(unitID, FIRE_STATE_RETURN_FIRE)
end

local function initializeUnit(unitID, unitDefID)
	if not eligibleUnitDef[unitDefID] then
		return
	end
	local states = spGetUnitStates(unitID)
	if states and states.firestate == FIRE_STATE_RETURN_FIRE then
		setVirtualReturnFire(unitID, "initialize")
	end
end

local function calculateUnitThreat(unitDef)
	local threat = {
		dps = 0,
		maxRange = 0,
		speed = unitDef.speed or 0,
		health = unitDef.health or 0,
	}
	local weapons = unitDef.weapons
	for i = 1, #weapons do
		local weapon = weapons[i]
		if isQualifyingWeapon(unitDef, weapon) then
			local weaponDef = WeaponDefs[weapon.weaponDef]
			threat.dps = threat.dps + calculateWeaponDps(weaponDef)
			if weaponDef.range > threat.maxRange then
				threat.maxRange = weaponDef.range
			end
		end
	end
	return threat
end

local function getTimeUntilTargetCanShootUs(dist, targetThreat)
	if targetThreat.maxRange <= 0 then
		return math.huge
	end
	if dist <= targetThreat.maxRange then
		return 0
	end
	if targetThreat.speed <= 0 then
		return math.huge
	end
	return (dist - targetThreat.maxRange) / targetThreat.speed
end

local function getTimeWeKillTarget(attackerDefID, targetThreat)
	local ourDps = attackerEffectiveDps[attackerDefID]
	if not ourDps or ourDps <= 0 or targetThreat.health <= 0 then
		return
	end
	return targetThreat.health / ourDps
end

local function allowTarget(attackerID, targetID, attackerDefID, targetDefID, defPriority, attackerWeaponNum, attackerWeaponDefID)
	local attackerName = getUnitDefName(attackerDefID)
	local targetName = getUnitDefName(targetDefID)
	local weaponName = attackerWeaponDefID and WeaponDefs[attackerWeaponDefID] and WeaponDefs[attackerWeaponDefID].name or "unknown"
	debugLog(stringFormat(
		"sweep check attacker=%s(%d) weapon=%s(#%s) target=%s(%d) priority=%s",
		attackerName,
		attackerID,
		weaponName,
		tostring(attackerWeaponNum),
		targetName,
		targetID,
		tostring(defPriority)
	))

	local targetThreat = unitThreatData[targetDefID]
	local timeWeKillTarget = getTimeWeKillTarget(attackerDefID, targetThreat)
	if not timeWeKillTarget then
		debugLog(stringFormat("allow %s -> %s: no kill time cap", attackerName, targetName))
		return true
	end

	local ourDps = attackerEffectiveDps[attackerDefID]

	local attackerX, _, attackerZ = spGetUnitPosition(attackerID)
	local targetX, _, targetZ = spGetUnitPosition(targetID)
	if not attackerX or not targetX then
		debugLog(stringFormat("allow %s -> %s: missing position data", attackerName, targetName))
		return true
	end

	local distSq = mathDistance2dSquared(attackerX, attackerZ, targetX, targetZ)
	local dist = mathSqrt(distSq)
	local timeUntilTargetCanShootUs = getTimeUntilTargetCanShootUs(dist, targetThreat)
	local timeWeKillWithMargin = timeWeKillTarget * THREAT_MARGIN
	local allowed = timeUntilTargetCanShootUs <= timeWeKillWithMargin
	debugLog(stringFormat(
		"%s %s -> %s dist=%.0f targetRange=%.0f effectiveDps=%.1f timeTheyShoot=%.2fs timeWeKill=%.2fs marginKill=%.2fs",
		allowed and "allow" or "block",
		attackerName,
		targetName,
		dist,
		targetThreat.maxRange,
		ourDps,
		timeUntilTargetCanShootUs,
		timeWeKillTarget,
		timeWeKillWithMargin
	))
	return allowed
end

for unitDefID, unitDef in pairs(UnitDefs) do
	local radius = getUnitRadius(unitDef)
	if smallestTargetRadius <= 0 or radius < smallestTargetRadius then
		smallestTargetRadius = radius
	end
	unitThreatData[unitDefID] = calculateUnitThreat(unitDef)
end

for unitDefID, unitDef in pairs(UnitDefs) do
	local threat = unitThreatData[unitDefID]
	local hasWeapon = threat.maxRange > 0
	local effectiveDps = 0
	local weapons = unitDef.weapons
	for i = 1, #weapons do
		local weapon = weapons[i]
		if isQualifyingWeapon(unitDef, weapon) then
			local weaponDefID = weapon.weaponDef
			local weaponDef = WeaponDefs[weaponDefID]
			if not watchedWeaponDef[weaponDefID] then
				watchedWeaponDef[weaponDefID] = true
				Script.SetWatchAllowTarget(weaponDefID, true)
			end
			effectiveDps = effectiveDps + calculateWeaponEffectiveDps(weaponDef)
		end
	end

	if hasWeapon then
		eligibleUnitDef[unitDefID] = true
		if effectiveDps > 0 then
			attackerEffectiveDps[unitDefID] = effectiveDps
		end
	end
end

function gadget:AllowCommand_GetWantedCommand()
	return {[CMD_FIRE_STATE] = true}
end

function gadget:AllowCommand_GetWantedUnitDefID()
	return true
end

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions, cmdTag, playerID, fromSynced, fromLua)
	if applyingFireState or not eligibleUnitDef[unitDefID] or not cmdParams then
		return true
	end

	local state = cmdParams[1]
	if state == FIRE_STATE_RETURN_FIRE then
		debugLog(stringFormat(
			"firestate command intercepted unitID=%d def=%s requested=Defensive",
			unitID,
			getUnitDefName(unitDefID)
		))
		setVirtualReturnFire(unitID, "allowCommand")
		return false
	end

	if state ~= FIRE_STATE_RETURN_FIRE then
		debugLog(stringFormat(
			"firestate command passthrough unitID=%d def=%s requestedState=%s",
			unitID,
			getUnitDefName(unitDefID),
			tostring(state)
		))
	end
	clearVirtualReturnFire(unitID, state)
	return true
end

function gadget:AllowWeaponTarget(attackerID, targetID, attackerWeaponNum, attackerWeaponDefID, defPriority)
	if not targetID or targetID <= 0 then
		return
	end

	if spGetUnitRulesParam(attackerID, RETURN_FIRE_RULES_PARAM) ~= 1 then
		return
	end

	debugLog(stringFormat(
		"AllowWeaponTarget call attackerID=%d targetID=%d weaponNum=%s defPriority=%s",
		attackerID,
		targetID,
		tostring(attackerWeaponNum),
		tostring(defPriority)
	))

	local attackerDefID = spGetUnitDefID(attackerID)
	local targetDefID = spGetUnitDefID(targetID)
	if not attackerDefID or not targetDefID then
		debugLog(stringFormat(
			"allow targetID=%d: missing unitDef attacker=%s target=%s",
			targetID,
			tostring(attackerDefID),
			tostring(targetDefID)
		))
		return
	end

	if not allowTarget(attackerID, targetID, attackerDefID, targetDefID, defPriority, attackerWeaponNum, attackerWeaponDefID) then
		return false
	end
end

function gadget:UnitCreated(unitID, unitDefID)
	initializeUnit(unitID, unitDefID)
end

function gadget:UnitDestroyed(unitID)
	spSetUnitRulesParam(unitID, RETURN_FIRE_RULES_PARAM, 0, INLOS_TRUE)
end

function gadget:Initialize()
	gadgetHandler:RegisterAllowCommand(CMD_FIRE_STATE)
	for _, unitID in ipairs(spGetAllUnits()) do
		initializeUnit(unitID, spGetUnitDefID(unitID))
	end
end
