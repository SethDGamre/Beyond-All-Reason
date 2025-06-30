if not RmlUi then
	return
end

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Territorial Domination Score (RmlUi)",
		desc = "Displays the score for the Territorial Domination game mode using RmlUi.",
		author = "SethDGamre",
		date = "2025",
		license = "GNU GPL, v2",
		layer = -9,
		enabled = false,
	}
end

local modOptions = Spring.GetModOptions()
if (modOptions.deathmode ~= "territorial_domination" and not modOptions.temp_enable_territorial_domination) then return false end

local floor = math.floor
local ceil = math.ceil
local format = string.format
local abs = math.abs
local max = math.max
local min = math.min

local spGetViewGeometry = Spring.GetViewGeometry
local spGetMiniMapGeometry = Spring.GetMiniMapGeometry
local spGetGameSeconds = Spring.GetGameSeconds
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamInfo = Spring.GetTeamInfo
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetSelectedUnitsCount = Spring.GetSelectedUnitsCount
local spGetUnitTeam = Spring.GetUnitTeam
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spGetGameRulesParam = Spring.GetGameRulesParam
local spGetTeamList = Spring.GetTeamList
local spGetTeamColor = Spring.GetTeamColor
local spGetAllyTeamList = Spring.GetAllyTeamList
local spGetUnitPosition = Spring.GetUnitPosition
local spPlaySoundFile = Spring.PlaySoundFile
local spI18N = Spring.I18N
local spGetUnitDefID = Spring.GetUnitDefID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetAllUnits = Spring.GetAllUnits
local spGetTeamLuaAI = Spring.GetTeamLuaAI

local WARNING_THRESHOLD = 3
local ALERT_THRESHOLD = 10
local WARNING_SECONDS = 15
local UPDATE_FREQUENCY = 0.5
local BLINK_INTERVAL = 1
local DEFEAT_CHECK_INTERVAL = Game.gameSpeed
local TIMER_COOLDOWN = 120
local TIMER_WARNING_DISPLAY_TIME = 5

local SCORE_RULES_KEY = "territorialDominationScore"
local THRESHOLD_RULES_KEY = "territorialDominationDefeatThreshold"
local FREEZE_DELAY_KEY = "territorialDominationPauseDelay"
local MAX_THRESHOLD_RULES_KEY = "territorialDominationMaxThreshold"
local RANK_RULES_KEY = "territorialDominationRank"

local document ---@type RmlUiDoc
local context

local myCommanders = {}
local soundQueue = {}
local allyTeamDefeatTimes = {}
local aliveAllyTeams = {}

local isSkullFaded = true
local lastTimerWarningTime = 0
local timerWarningEndTime = 0
local amSpectating = false
local myAllyID = -1
local selectedAllyTeamID = -1
local gaiaAllyTeamID = -1
local lastUpdateTime = 0
local maxThreshold = 256
local currentTime = os.clock()
local defeatTime = 0
local gameSeconds = 0
local lastLoop = 0
local loopSoundEndTime = 0
local soundIndex = 1
local currentGameFrame = 0

local lastAllyTeamScores = {}
local lastTeamRanks = {}

local function isAllyTeamAlive(allyTeamID)
	if allyTeamID == gaiaAllyTeamID then
		return false
	end
	
	local teamList = spGetTeamList(allyTeamID)
	for _, teamID in ipairs(teamList) do
		local _, _, isDead = spGetTeamInfo(teamID)
		if not isDead then
			return true
		end
	end
	
	return false
end

local function isHordeModeAllyTeam(allyTeamID)
	local teamList = spGetTeamList(allyTeamID)
	if not teamList then return false end
	
	for _, teamID in ipairs(teamList) do
		local luaAI = spGetTeamLuaAI(teamID)
		if luaAI and luaAI ~= "" then
			if string.sub(luaAI, 1, 12) == 'ScavengersAI' or string.sub(luaAI, 1, 12) == 'RaptorsAI' then
				return true
			end
		end
	end
	return false
end

local function updateAliveAllyTeams()
	aliveAllyTeams = {}
	local allyTeamList = spGetAllyTeamList()
	
	for _, allyTeamID in ipairs(allyTeamList) do
		if isAllyTeamAlive(allyTeamID) and not isHordeModeAllyTeam(allyTeamID) then
			table.insert(aliveAllyTeams, allyTeamID)
		end
	end
end

local function getRepresentativeTeamDataFromAllyTeam(allyTeamID)
	local teamList = spGetTeamList(allyTeamID)
	if not teamList or #teamList == 0 then
		return nil, 0, nil
	end
	
	local representativeTeamID = teamList[1]
	local score = spGetTeamRulesParam(representativeTeamID, SCORE_RULES_KEY) or 0
	local rank = spGetTeamRulesParam(representativeTeamID, RANK_RULES_KEY)
	
	return representativeTeamID, score, rank
end

local function getBarColorBasedOnDifference(difference)
	if difference <= WARNING_THRESHOLD then
		return "critical"
	elseif difference <= ALERT_THRESHOLD then
		return "warn"
	else
		return "normal"
	end
end

local function rgbToHex(r, g, b)
	return format("#%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end

local function rgbToRgbaString(r, g, b, a)
	return format("rgba(%d, %d, %d, %.2f)", floor(r * 255), floor(g * 255), floor(b * 255), a)
end

local function createTintedColor(baseR, baseG, baseB, tintR, tintG, tintB, strength)
	local tintedR = baseR + (tintR - baseR) * strength
	local tintedG = baseG + (tintG - baseG) * strength
	local tintedB = baseB + (tintB - baseB) * strength
	return tintedR, tintedG, tintedB
end

local function updateScoreBars()
	if not document then return end
	
	local defeatThreshold = spGetGameRulesParam(THRESHOLD_RULES_KEY) or 0
	local currentMaxThreshold = spGetGameRulesParam(MAX_THRESHOLD_RULES_KEY) or 256
	local isDefeatThresholdPaused = (spGetGameRulesParam(FREEZE_DELAY_KEY) or 0) > gameSeconds
	
	maxThreshold = currentMaxThreshold
	
	local displayTeams = amSpectating and aliveAllyTeams or {myAllyID}
	local allyTeamScores = {}
	
	for _, allyTeamID in ipairs(displayTeams) do
		local teamID, score, rank = getRepresentativeTeamDataFromAllyTeam(allyTeamID)
		if teamID then
			local redComponent, greenComponent, blueComponent = spGetTeamColor(teamID)
			local teamColorHex = rgbToHex(redComponent, greenComponent, blueComponent)
			local barClass = "normal"
			
			if not amSpectating then
				local difference = score - defeatThreshold
				barClass = getBarColorBasedOnDifference(difference)
			end
			
			local defeatTimeRemaining = 0
			if allyTeamDefeatTimes[allyTeamID] and allyTeamDefeatTimes[allyTeamID] > 0 then
				defeatTimeRemaining = max(0, allyTeamDefeatTimes[allyTeamID] - gameSeconds)
			elseif not amSpectating and defeatTime and defeatTime > 0 then
				defeatTimeRemaining = max(0, defeatTime - gameSeconds)
			end
			
			table.insert(allyTeamScores, {
				allyTeamID = allyTeamID,
				teamID = teamID,
				score = score,
				rank = rank,
				teamColorHex = teamColorHex,
				barClass = barClass,
				defeatTimeRemaining = defeatTimeRemaining,
				difference = score - defeatThreshold
			})
		end
	end
	
	if amSpectating then
		table.sort(allyTeamScores, function(a, b)
			if a.score == b.score then
				return a.defeatTimeRemaining > b.defeatTimeRemaining
			end
			return a.score > b.score
		end)
	end
	
	local containerElement = document:GetElementById("score-bars-container")
	if not containerElement then return end
	
	containerElement.inner_rml = ""
	
	for index, allyTeamData in ipairs(allyTeamScores) do
		local progressPercentage = min(100, (allyTeamData.score / maxThreshold) * 100)
		local defeatThresholdPercentage = min(100, (defeatThreshold / maxThreshold) * 100)
		local exceedsThreshold = allyTeamData.score > maxThreshold
		
		local skullVisibility = defeatThreshold >= 1 and "visible" or "hidden"
		local skullOpacity = isDefeatThresholdPaused and isSkullFaded and "0.5" or "1.0"
		
		local countdownText = ""
		local countdownVisibility = "hidden"
		if allyTeamData.defeatTimeRemaining > 0 then
			countdownText = format("%d", ceil(allyTeamData.defeatTimeRemaining))
			countdownVisibility = "visible"
		end
		
		local rankText = ""
		local rankVisibility = "hidden"
		if not amSpectating and allyTeamData.rank then
			rankText = spI18N('ui.territorialDomination.rank', {rank = allyTeamData.rank})
			rankVisibility = "visible"
		end
		
		local differenceText = ""
		if allyTeamData.difference > 0 then
			differenceText = "+" .. allyTeamData.difference
		elseif allyTeamData.difference < 0 then
			differenceText = tostring(allyTeamData.difference)
		else
			differenceText = "0"
		end
		
		local redComponent, greenComponent, blueComponent = spGetTeamColor(allyTeamData.teamID)
		local tintedBgR, tintedBgG, tintedBgB = createTintedColor(0, 0, 0, redComponent, greenComponent, blueComponent, 0.15)
		local backgroundColorHex = rgbToHex(tintedBgR, tintedBgG, tintedBgB)
		
		local barHtml = format([[
			<div class="score-bar %s" style="border-color: %s;">
				<div class="score-bar-background" style="background-color: %s;"></div>
				<div class="score-bar-fill" style="width: %s%%; background-color: %s;"></div>
				<div class="score-bar-threshold" style="left: %s%%; visibility: %s;">
					<div class="skull-icon" style="opacity: %s;"></div>
				</div>
				<div class="score-text">%s</div>
				<div class="countdown-text" style="visibility: %s;">%s</div>
				<div class="rank-display" style="visibility: %s;">%s</div>
			</div>
		]], 
			allyTeamData.barClass,
			allyTeamData.teamColorHex,
			backgroundColorHex,
			progressPercentage,
			allyTeamData.teamColorHex,
			defeatThresholdPercentage,
			skullVisibility,
			skullOpacity,
			differenceText,
			countdownVisibility,
			countdownText,
			rankVisibility,
			rankText
		)
		
		containerElement.inner_rml = containerElement.inner_rml .. barHtml
	end
end

local function updateWarningMessage()
	if not document then return end
	
	local warningElement = document:GetElementById("warning-message")
	if not warningElement then return end
	
	if gameSeconds < timerWarningEndTime then
		local timeRemaining = ceil(defeatTime - gameSeconds)
		local _, score = getRepresentativeTeamDataFromAllyTeam(myAllyID)
		local defeatThreshold = spGetGameRulesParam(THRESHOLD_RULES_KEY) or 0
		local difference = score - defeatThreshold
		local territoriesNeeded = abs(difference)
		
		local dominatedMessage = spI18N('ui.territorialDomination.losingWarning1', {seconds = timeRemaining})
		local conquerMessage = spI18N('ui.territorialDomination.losingWarning2', {count = territoriesNeeded})
		
		warningElement.inner_rml = format([[
			<div class="warning-text">%s</div>
			<div class="warning-text">%s</div>
		]], dominatedMessage, conquerMessage)
		
		warningElement.style.visibility = "visible"
	else
		warningElement.style.visibility = "hidden"
	end
end

local function updatePosition()
	if not document then return end
	
	local minimapPosX, minimapPosY, minimapSizeX = spGetMiniMapGeometry()
	local rootElement = document:GetElementById("territorial-domination")
	if rootElement then
		rootElement.style.left = format("%ddp", minimapPosX)
		rootElement.style.top = format("%ddp", minimapPosY - 300)
		rootElement.style.width = format("%ddp", minimapSizeX)
	end
end

local function queueTeleportSounds()
	soundQueue = {}
	if defeatTime and defeatTime > 0 then
		table.insert(soundQueue, 1, {when = defeatTime - 2, sound = "cmd-off", volume = 0.4})
		table.insert(soundQueue, 1, {when = defeatTime - 2, sound = "teleport-windup", volume = 0.225})
	end
end

function widget:Initialize()
	context = RmlUi.GetContext("shared")
	document = context:LoadDocument("LuaUI/RmlWidgets/assets/territorial_domination.rml", widget)
	if not document then
		Spring.Echo("ERROR: Failed to load territorial domination RML document")
		return
	end
	document:Show()
	
	amSpectating = spGetSpectatingState()
	myAllyID = spGetMyAllyTeamID()
	selectedAllyTeamID = myAllyID
	gaiaAllyTeamID = select(6, spGetTeamInfo(Spring.GetGaiaTeamID()))
	
	gameSeconds = spGetGameSeconds() or 0
	defeatTime = 0
	
	updateAliveAllyTeams()
	updatePosition()
	updateScoreBars()
	
	local allUnits = spGetAllUnits()
	for _, unitID in ipairs(allUnits) do
		widget:MetaUnitAdded(unitID, spGetUnitDefID(unitID), spGetUnitTeam(unitID), nil)
	end
end

function widget:MetaUnitAdded(unitID, unitDefID, unitTeam, builderID)
	if unitTeam == spGetMyTeamID() then
		local unitDef = UnitDefs[unitDefID]
		if unitDef.customParams and unitDef.customParams.iscommander then
			myCommanders[unitID] = true
		end
	end
end

function widget:MetaUnitRemoved(unitID, unitDefID, unitTeam)
	if myCommanders[unitID] then
		myCommanders[unitID] = nil
	end
end

function widget:GameFrame(frame)
    --Spring.Echo("fart", frame)
	currentGameFrame = frame
	gameSeconds = spGetGameSeconds() or 0
	
	if frame % DEFEAT_CHECK_INTERVAL == 3 then
		updateAliveAllyTeams()
		
		if amSpectating then
			for _, allyTeamID in ipairs(aliveAllyTeams) do
				if allyTeamID ~= gaiaAllyTeamID then
					local teamList = spGetTeamList(allyTeamID)
					local allyDefeatTime = 0
					
					if teamList and #teamList > 0 then
						local representativeTeamID = teamList[1]
						allyDefeatTime = spGetTeamRulesParam(representativeTeamID, "defeatTime") or 0
					end
					
					allyTeamDefeatTimes[allyTeamID] = allyDefeatTime
				end
			end
		else
			local myTeamID = Spring.GetMyTeamID()
			local newDefeatTime = spGetTeamRulesParam(myTeamID, "defeatTime") or 0
			
			if newDefeatTime > 0 then
				if newDefeatTime ~= defeatTime then
					defeatTime = newDefeatTime
					loopSoundEndTime = defeatTime - 2
					soundQueue = nil
					queueTeleportSounds()
				end
			elseif defeatTime ~= 0 then
				defeatTime = 0
				loopSoundEndTime = 0
				soundQueue = nil
				soundIndex = 1
			end
		end
	end
	
	local isDefeatThresholdPaused = (spGetGameRulesParam(FREEZE_DELAY_KEY) or 0) > gameSeconds
	if isDefeatThresholdPaused then
		if frame % 30 == 0 then
			if amSpectating then
				for allyTeamID in pairs(allyTeamDefeatTimes) do
					allyTeamDefeatTimes[allyTeamID] = 0
				end
			else
				defeatTime = 0
				loopSoundEndTime = 0
				soundQueue = nil
				soundIndex = 1
			end
		end
		return
	end
	
	if frame % 45 == 0 then
		if loopSoundEndTime and loopSoundEndTime > gameSeconds then
			if lastLoop <= currentTime then
				lastLoop = currentTime
				
				local timeRange = loopSoundEndTime - (defeatTime - 2 - 4.7 * 10)
				local timeLeft = loopSoundEndTime - gameSeconds
				local minVolume = 0.05
				local maxVolume = 0.2
				local volumeRange = maxVolume - minVolume
				
				local volumeFactor = 1 - (timeLeft / timeRange)
				volumeFactor = max(0, min(volumeFactor, 1))
				local currentVolume = minVolume + (volumeFactor * volumeRange)
				
				for unitID in pairs(myCommanders) do
					local xPosition, yPosition, zPosition = spGetUnitPosition(unitID)
					if xPosition then
						spPlaySoundFile("teleport-charge-loop", currentVolume, xPosition, yPosition, zPosition, 0, 0, 0, "sfx")
					else
						myCommanders[unitID] = nil
					end
				end
			end
		else
			local sound = soundQueue and soundQueue[soundIndex]
			if sound and gameSeconds and sound.when < gameSeconds then
				for unitID in pairs(myCommanders) do
					local xPosition, yPosition, zPosition = spGetUnitPosition(unitID)
					if xPosition then
						spPlaySoundFile(sound.sound, sound.volume, xPosition, yPosition, zPosition, 0, 0, 0, "sfx")
					else
						myCommanders[unitID] = nil
					end
				end
				soundIndex = soundIndex + 1
			end
		end
	end
	
	if not amSpectating and defeatTime > gameSeconds then
		local timeRemaining = ceil(defeatTime - gameSeconds)
		local _, score = getRepresentativeTeamDataFromAllyTeam(myAllyID)
		local defeatThreshold = spGetGameRulesParam(THRESHOLD_RULES_KEY) or 0
		local difference = score - defeatThreshold
		
		if difference < 0 and gameSeconds >= lastTimerWarningTime + TIMER_COOLDOWN then
			spPlaySoundFile("warning1", 1)
			timerWarningEndTime = gameSeconds + TIMER_WARNING_DISPLAY_TIME
			lastTimerWarningTime = gameSeconds
		end
	end
end

function widget:Update(deltaTime)
	currentTime = os.clock()
	
	local newAmSpectating = spGetSpectatingState()
	local newMyAllyID = spGetMyAllyTeamID()
	
	if newAmSpectating ~= amSpectating or newMyAllyID ~= myAllyID then
		amSpectating = newAmSpectating
		myAllyID = newMyAllyID
		updatePosition()
		updateScoreBars()
		return
	end
	
	local isDefeatThresholdPaused = (spGetGameRulesParam(FREEZE_DELAY_KEY) or 0) > gameSeconds
	if isDefeatThresholdPaused and (spGetGameRulesParam(FREEZE_DELAY_KEY) or 0) - gameSeconds <= WARNING_SECONDS then
		local blinkPhase = (currentTime % BLINK_INTERVAL) / BLINK_INTERVAL
		isSkullFaded = blinkPhase >= 0.33
	end
	
	if currentTime - lastUpdateTime > UPDATE_FREQUENCY then
		lastUpdateTime = currentTime
		updatePosition()
		updateScoreBars()
		updateWarningMessage()
	end
end

function widget:PlayerChanged(playerID)
	if amSpectating then
		if spGetSelectedUnitsCount() > 0 then
			local unitID = spGetSelectedUnits()[1]
			local unitTeam = spGetUnitTeam(unitID)
			if unitTeam then
				local newSelectedAllyTeamID = select(6, spGetTeamInfo(unitTeam)) or myAllyID
				if newSelectedAllyTeamID ~= selectedAllyTeamID then
					selectedAllyTeamID = newSelectedAllyTeamID
					updateScoreBars()
				end
				return
			end
		end
		if selectedAllyTeamID ~= myAllyID then
			selectedAllyTeamID = myAllyID
			updateScoreBars()
		end
	end
end

function widget:Shutdown()
	if document then
		document:Close()
	end
end

function widget:RecvLuaMsg(msg, playerID)
	if msg:sub(1, 19) == 'LobbyOverlayActive0' then
		if document then document:Show() end
	elseif msg:sub(1, 19) == 'LobbyOverlayActive1' then
		if document then document:Hide() end
	end
end 