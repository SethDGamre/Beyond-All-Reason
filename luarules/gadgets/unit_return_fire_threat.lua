local gadget = gadget ---@type Gadget

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
local stringFormat = string.format

local eligibleUnitDef = {}
local maxEngageDistSquared = {}
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

	local targetDistances = maxEngageDistSquared[attackerDefID]
	local maxDistSq = targetDistances and targetDistances[targetDefID]
	if not maxDistSq then
		debugLog(stringFormat("allow %s -> %s: no threat distance cap", attackerName, targetName))
		return true
	end

	local attackerX, _, attackerZ = spGetUnitPosition(attackerID)
	local targetX, _, targetZ = spGetUnitPosition(targetID)
	if not attackerX or not targetX then
		debugLog(stringFormat("allow %s -> %s: missing position data", attackerName, targetName))
		return true
	end

	local distSq = mathDistance2dSquared(attackerX, attackerZ, targetX, targetZ)
	local allowed = distSq <= maxDistSq
	debugLog(stringFormat(
		"%s %s -> %s dist=%.0f maxDist=%.0f",
		allowed and "allow" or "block",
		attackerName,
		targetName,
		mathSqrt(distSq),
		mathSqrt(maxDistSq)
	))
	return allowed
end

for unitDefID, unitDef in pairs(UnitDefs) do
	local dps = 0
	local hasWeapon = false
	local weapons = unitDef.weapons
	for i = 1, #weapons do
		local weapon = weapons[i]
		if isQualifyingWeapon(unitDef, weapon) then
			hasWeapon = true
			local weaponDefID = weapon.weaponDef
			local weaponDef = WeaponDefs[weaponDefID]
			dps = dps + calculateWeaponDps(weaponDef)
			if not watchedWeaponDef[weaponDefID] then
				watchedWeaponDef[weaponDefID] = true
				Script.SetWatchAllowTarget(weaponDefID, true)
			end
		end
	end

	if hasWeapon then
		eligibleUnitDef[unitDefID] = true
		if dps > 0 then
			maxEngageDistSquared[unitDefID] = {}
			for targetDefID, targetDef in pairs(UnitDefs) do
				local maxRange = targetDef.maxWeaponRange or 0
				local speed = targetDef.speed or 0
				local health = targetDef.health or 0
				local maxEngageDist = maxRange + speed * health / dps
				maxEngageDistSquared[unitDefID][targetDefID] = maxEngageDist * maxEngageDist
			end
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
