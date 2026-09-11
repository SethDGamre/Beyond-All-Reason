if not RmlUi then
	return
end

local WIDGET = widget

function WIDGET:GetInfo()
	return {
		name = "Territorial Domination Score Display",
		desc = "Displays Territorial Domination scores and Deadlines",
		author = "SethDGamre",
		date = "2026-09",
		license = "GNU GPL, v2 or later",
		layer = 2,
		enabled = true,
	}
end

local MOD_OPTIONS = Spring.GetModOptions() or {}

if MOD_OPTIONS.deathmode ~= "territorial_domination" then
	return false
end

if BAR.Utilities.Gametype.IsRaptors() or BAR.Utilities.Gametype.IsScavengers() then
	return false
end

local MODEL_NAME = "territorial_score_model"
local RML_PATH = "luaui/RmlWidgets/gui_territorial_domination/gui_territorial_domination.rml"
local PANEL_POSITION_X_KEY = "td_posX"
local PANEL_POSITION_Y_KEY = "td_posY"
local EMOJI_FONT_PATH = "fonts/fallbacks/NotoEmoji-VariableFont_wght.ttf"
local PANEL_WIDTH_DP = 240
local PANEL_COLLAPSED_HEIGHT_DP = 110
local PANEL_EXPANDED_HEIGHT_DP = 204
local PANEL_MARGIN_DP = 10
local PANEL_ORIGIN_SNAP_DISTANCE_DP = 36
local REVERT_TO_ORIGIN_POSITION = true
local VERTICAL_SLOT_WIDTH_DP = 42
local VERTICAL_CONTENT_MINIMUM_WIDTH_DP = 218
local VERTICAL_CONTENT_PADDING_DP = 6
local VERTICAL_TRACK_HEIGHT_DP = 112
local VERTICAL_TRACK_BOTTOM_DP = 24
local TOOLTIP_WIDTH_DP = 300
local TOOLTIP_VERTICAL_PADDING_DP = 16
local TOOLTIP_ROW_HEIGHT_DP = 22
local TOOLTIP_CURRENT_SCORE_WIDTH_DP = 145
local TOOLTIP_COUNTDOWN_WIDTH_DP = 310
local TOOLTIP_TARGET_WIDTH_DP = 520
local TOOLTIP_OFFSET_X = 16
local TOOLTIP_OFFSET_Y = 22
local POSITION_SCALE = 10000
local COLOR_BYTE_MAXIMUM = 255
local DARK_COLOR_MULTIPLIER = 0.48
local DATA_UPDATE_INTERVAL = 0.2
local POPUP_DURATION_SECONDS = 5
local POPUP_INITIAL_WINDOW_SECONDS = 10
local COUNTDOWN_WARNING_SECONDS = 10
local SECONDS_PER_MINUTE = 60
local DEADLINE_SKULL_ICON = "💀"
local DEADLINE_LABEL_OFFSET_DP = 10
local KEY_ESCAPE = 27
local TOOLTIP_SOURCE_CURRENT_SCORE = "currentScore"
local TOOLTIP_SOURCE_COUNTDOWN = "countdown"
local TOOLTIP_SOURCE_TARGET = "target"
local DEFAULT_COLOR = {
	red = 0.5,
	green = 0.5,
	blue = 0.5,
}
local DEADLINES_BY_CONFIG = {
	["20_minutes"] = 4,
	["25_minutes"] = 5,
	["30_minutes"] = 6,
	["35_minutes"] = 7,
}
local DEFAULT_MAX_DEADLINES = DEADLINES_BY_CONFIG[MOD_OPTIONS.territorial_domination_config] or 5
local I18N = BAR.I18N
local FLOW_UI_PANEL_API_NAMES = {
	"advplayerlist_api",
	"music",
	"unittotals",
	"displayinfo",
	"playertv",
	"advplayerlist_mascot",
}

local widgetState = {
	rmlContext = nil,
	dmHandle = nil,
	document = nil,
	allyTeams = {},
	allyTeamsByID = {},
	selectedAllyTeamID = -1,
	spectatorSelectedAllyTeamID = nil,
	leaderAllyTeamID = -1,
	currentDeadline = 0,
	maxDeadlines = DEFAULT_MAX_DEADLINES,
	deadlineEndTimestamp = 0,
	deadlineScore = 0,
	totalTerritories = 0,
	hasDeadline = false,
	isExpanded = false,
	hiddenByLobby = false,
	shouldShow = false,
	updateAccumulator = DATA_UPDATE_INTERVAL,
	lastUpdateClock = os.clock(),
	dragActive = false,
	isDragging = false,
	isNearOrigin = false,
	isInDanger = false,
	isInFirstPlace = false,
	dragOffsetX = 0,
	dragOffsetY = 0,
	panelPixelX = 0,
	panelPixelY = 0,
	hasUserPosition = false,
	tooltipActive = false,
	tooltipIsScore = true,
	tooltipIsSimple = false,
	tooltipAllyTeamID = nil,
	tooltipSimpleSource = nil,
	tooltipRowCount = 1,
	tooltipWidthDp = TOOLTIP_WIDTH_DP,
	popupActive = false,
	popupStartClock = 0,
	hasObservedDeadline = false,
	lastObservedDeadline = 0,
	lastWasInLead = nil,
	cachedTeamColors = {},
}

local function clampNumber(value, minimum, maximum)
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function roundNumber(value)
	return math.floor(value + 0.5)
end

local function formatScore(value)
	local scoreText = string.format("%.1f", tonumber(value) or 0)
	return (scoreText:gsub("%.0$", ""))
end

local function formatPercentage(value)
	return string.format("%.3f%%", clampNumber(value, 0, 100))
end

local function formatOrdinal(place)
	local numericPlace = math.max(0, math.floor(tonumber(place) or 0))
	local finalTwoDigits = numericPlace % 100
	local suffix = "th"

	if finalTwoDigits < 11 or finalTwoDigits > 13 then
		local finalDigit = numericPlace % 10
		if finalDigit == 1 then
			suffix = "st"
		elseif finalDigit == 2 then
			suffix = "nd"
		elseif finalDigit == 3 then
			suffix = "rd"
		end
	end

	return tostring(numericPlace) .. suffix
end

local function formatCountdown(deadlineEndTimestamp, currentDeadline, maxDeadlines)
	if currentDeadline > maxDeadlines then
		return I18N("ui.territorialDomination.deadline.end"), 0
	end

	if deadlineEndTimestamp <= 0 then
		return "0:00", 0
	end

	local remainingSeconds = math.max(0, deadlineEndTimestamp - Spring.GetGameSeconds())
	local displayedSeconds = math.ceil(remainingSeconds)
	local minutes = math.floor(displayedSeconds / SECONDS_PER_MINUTE)
	local seconds = displayedSeconds % SECONDS_PER_MINUTE
	return string.format("%d:%02d", minutes, seconds), remainingSeconds
end

local function getFallbackAllyTeamTitle(allyTeamID)
	return I18N("ui.territorialDomination.team.ally", { allyNumber = allyTeamID + 1 })
end

local function getAllyTeamColor(allyTeamID, teamList)
	local cachedColor = widgetState.cachedTeamColors[allyTeamID]
	if cachedColor then
		return cachedColor
	end

	local color = {
		red = DEFAULT_COLOR.red,
		green = DEFAULT_COLOR.green,
		blue = DEFAULT_COLOR.blue,
	}

	if teamList[1] then
		local red, green, blue = Spring.GetTeamColor(teamList[1])
		color.red = red or color.red
		color.green = green or color.green
		color.blue = blue or color.blue
	end

	widgetState.cachedTeamColors[allyTeamID] = color
	return color
end

local function makeColorString(color, multiplier)
	local colorMultiplier = multiplier or 1
	local red = roundNumber(clampNumber(color.red * colorMultiplier, 0, 1) * COLOR_BYTE_MAXIMUM)
	local green = roundNumber(clampNumber(color.green * colorMultiplier, 0, 1) * COLOR_BYTE_MAXIMUM)
	local blue = roundNumber(clampNumber(color.blue * colorMultiplier, 0, 1) * COLOR_BYTE_MAXIMUM)
	return string.format("rgba(%d, %d, %d, 255)", red, green, blue)
end

local function getPlayerTeamColor(teamID)
	local red, green, blue = Spring.GetTeamColor(teamID)
	local isSpectating = Spring.GetSpectatingState()
	local anonymousMode = MOD_OPTIONS.teamcolors_anonymous_mode

	if not isSpectating and anonymousMode ~= "disabled" and teamID ~= Spring.GetLocalTeamID() then
		red = Spring.GetConfigInt("anonymousColorR", COLOR_BYTE_MAXIMUM) / COLOR_BYTE_MAXIMUM
		green = Spring.GetConfigInt("anonymousColorG", 0) / COLOR_BYTE_MAXIMUM
		blue = Spring.GetConfigInt("anonymousColorB", 0) / COLOR_BYTE_MAXIMUM
	end

	return makeColorString({
		red = red or DEFAULT_COLOR.red,
		green = green or DEFAULT_COLOR.green,
		blue = blue or DEFAULT_COLOR.blue,
	})
end

local function getAIName(teamID)
	local _, _, _, aiName = Spring.GetAIInfo(teamID)
	aiName = Spring.GetGameRulesParam("ainame_" .. teamID) or aiName or Spring.GetTeamLuaAI(teamID)
	return I18N("ui.playersList.aiName", { name = aiName or "AI" })
end

local function getAllyTeamPlayers(allyTeamID, teamList, fallbackColor)
	local players = {}
	local seenPlayerIDs = {}

	for teamIndex = 1, #teamList do
		local teamID = teamList[teamIndex]
		local playerList = Spring.GetPlayerList(teamID) or {}
		local initialPlayerCount = #players

		for playerIndex = 1, #playerList do
			local playerID = playerList[playerIndex]
			if not seenPlayerIDs[playerID] then
				local playerName, _, isSpectator = Spring.GetPlayerInfo(playerID, false)
				if playerName and not isSpectator then
					seenPlayerIDs[playerID] = true
					if WG.playernames and WG.playernames.getPlayername then
						playerName = WG.playernames.getPlayername(playerID) or playerName
					end
					players[#players + 1] = {
						name = playerName,
						color = getPlayerTeamColor(teamID),
					}
				end
			end
		end

		if #players == initialPlayerCount then
			local _, _, _, isAI = Spring.GetTeamInfo(teamID, false)
			if isAI then
				players[#players + 1] = {
					name = getAIName(teamID),
					color = getPlayerTeamColor(teamID),
				}
			end
		end
	end

	if #players == 0 then
		players[1] = {
			name = getFallbackAllyTeamTitle(allyTeamID),
			color = fallbackColor,
		}
	end

	return players
end

local function getFirstLivingTeamID(teamList)
	local firstLivingTeamID = nil
	for teamIndex = 1, #teamList do
		local teamID = teamList[teamIndex]
		local _, _, isDead = Spring.GetTeamInfo(teamID, false)
		if not isDead and (firstLivingTeamID == nil or teamID < firstLivingTeamID) then
			firstLivingTeamID = teamID
		end
	end
	return firstLivingTeamID
end

local function compareRankedAllyTeams(firstAllyTeam, secondAllyTeam)
	if firstAllyTeam.rank ~= secondAllyTeam.rank then
		return firstAllyTeam.rank < secondAllyTeam.rank
	end
	if firstAllyTeam.score ~= secondAllyTeam.score then
		return firstAllyTeam.score > secondAllyTeam.score
	end
	if firstAllyTeam.territoryCount ~= secondAllyTeam.territoryCount then
		return firstAllyTeam.territoryCount > secondAllyTeam.territoryCount
	end
	return firstAllyTeam.allyTeamID < secondAllyTeam.allyTeamID
end

local function compareAscendingScores(firstAllyTeam, secondAllyTeam)
	if firstAllyTeam.score ~= secondAllyTeam.score then
		return firstAllyTeam.score < secondAllyTeam.score
	end
	if firstAllyTeam.territoryCount ~= secondAllyTeam.territoryCount then
		return firstAllyTeam.territoryCount < secondAllyTeam.territoryCount
	end
	return firstAllyTeam.allyTeamID < secondAllyTeam.allyTeamID
end

local function collectAllyTeamData()
	local gaiaTeamID = Spring.GetGaiaTeamID()
	local gaiaAllyTeamID = select(6, Spring.GetTeamInfo(gaiaTeamID, false))
	local allyTeamList = Spring.GetAllyTeamList() or {}
	local allyTeams = {}
	local allyTeamsByID = {}

	for allyTeamIndex = 1, #allyTeamList do
		local allyTeamID = allyTeamList[allyTeamIndex]
		if allyTeamID ~= gaiaAllyTeamID then
			local teamList = Spring.GetTeamList(allyTeamID) or {}
			if #teamList > 0 then
				local parameterPrefix = "territorialDomination_ally_" .. allyTeamID .. "_"
				local color = getAllyTeamColor(allyTeamID, teamList)
				local score = tonumber(Spring.GetGameRulesParam(parameterPrefix .. "score")) or 0
				local projectedScore = tonumber(Spring.GetGameRulesParam(parameterPrefix .. "projectedScore")) or score
				local firstLivingTeamID = getFirstLivingTeamID(teamList)
				local allyTeamData = {
					allyTeamID = allyTeamID,
					players = getAllyTeamPlayers(allyTeamID, teamList, makeColorString(color)),
					score = score,
					projectedScore = math.max(score, projectedScore),
					territoryCount = tonumber(Spring.GetGameRulesParam(parameterPrefix .. "territoryCount")) or 0,
					rank = tonumber(Spring.GetGameRulesParam(parameterPrefix .. "rank")) or 1,
					isAlive = firstLivingTeamID ~= nil,
					firstLivingTeamID = firstLivingTeamID,
					color = makeColorString(color),
					darkColor = makeColorString(color, DARK_COLOR_MULTIPLIER),
				}
				allyTeams[#allyTeams + 1] = allyTeamData
				allyTeamsByID[allyTeamID] = allyTeamData
			end
		end
	end

	table.sort(allyTeams, compareRankedAllyTeams)
	return allyTeams, allyTeamsByID
end

local function findLivingLeader(allyTeams)
	for allyTeamIndex = 1, #allyTeams do
		if allyTeams[allyTeamIndex].isAlive then
			return allyTeams[allyTeamIndex]
		end
	end
	return allyTeams[1]
end

local function chooseSelectedAllyTeam(allyTeams, allyTeamsByID, livingLeader)
	local isSpectating = Spring.GetSpectatingState()
	local localAllyTeamID = Spring.GetLocalAllyTeamID()

	if isSpectating then
		local spectatorSelectedAllyTeamID = widgetState.spectatorSelectedAllyTeamID
		if spectatorSelectedAllyTeamID then
			if spectatorSelectedAllyTeamID == localAllyTeamID then
				widgetState.spectatorSelectedAllyTeamID = nil
			else
				local spectatorSelectedAllyTeam = allyTeamsByID[spectatorSelectedAllyTeamID]
				if spectatorSelectedAllyTeam and spectatorSelectedAllyTeam.isAlive then
					return spectatorSelectedAllyTeam
				end
				widgetState.spectatorSelectedAllyTeamID = nil
			end
		end
	else
		widgetState.spectatorSelectedAllyTeamID = nil
	end

	local localAllyTeam = localAllyTeamID and allyTeamsByID[localAllyTeamID]
	return localAllyTeam or livingLeader or allyTeams[1]
end

local function getHighestScore(allyTeams)
	local highestScore = 0
	for allyTeamIndex = 1, #allyTeams do
		highestScore = math.max(highestScore, allyTeams[allyTeamIndex].score)
	end
	return highestScore
end

local function buildDistributionData(allyTeams)
	local ascendingAllyTeams = {}
	local totalScore = 0

	for allyTeamIndex = 1, #allyTeams do
		local allyTeam = allyTeams[allyTeamIndex]
		ascendingAllyTeams[allyTeamIndex] = allyTeam
		totalScore = totalScore + math.max(0, allyTeam.score)
	end

	table.sort(ascendingAllyTeams, compareAscendingScores)

	local distributionSegments = {}
	local equalWidth = #ascendingAllyTeams > 0 and 100 / #ascendingAllyTeams or 0

	for allyTeamIndex = 1, #ascendingAllyTeams do
		local allyTeam = ascendingAllyTeams[allyTeamIndex]
		local width = totalScore > 0 and math.max(0, allyTeam.score) / totalScore * 100 or equalWidth
		distributionSegments[#distributionSegments + 1] = {
			allyTeamID = allyTeam.allyTeamID,
			width = formatPercentage(width),
			color = allyTeam.color,
		}
	end

	return distributionSegments, ascendingAllyTeams
end

local function buildVerticalBars(ascendingAllyTeams, verticalScale)
	local verticalBars = {}

	for allyTeamIndex = 1, #ascendingAllyTeams do
		local allyTeam = ascendingAllyTeams[allyTeamIndex]
		verticalBars[#verticalBars + 1] = {
			allyTeamID = allyTeam.allyTeamID,
			rank = formatOrdinal(allyTeam.rank),
			isAlive = allyTeam.isAlive,
			projectedHeight = formatPercentage(allyTeam.projectedScore / verticalScale * 100),
			darkColor = allyTeam.darkColor,
			actualHeight = formatPercentage(allyTeam.score / verticalScale * 100),
			color = allyTeam.color,
			score = formatScore(allyTeam.score),
		}
	end

	return verticalBars
end

local function getDpRatio()
	if widgetState.rmlContext and widgetState.rmlContext.dp_ratio then
		return widgetState.rmlContext.dp_ratio
	end
	return 1
end

local function getPanelPixelSize()
	local dpRatio = getDpRatio()
	local panelHeight = widgetState.isExpanded and PANEL_EXPANDED_HEIGHT_DP or PANEL_COLLAPSED_HEIGHT_DP
	return PANEL_WIDTH_DP * dpRatio, panelHeight * dpRatio
end

local function setPanelPosition(panelPixelX, panelPixelY)
	widgetState.panelPixelX = roundNumber(panelPixelX)
	widgetState.panelPixelY = roundNumber(panelPixelY)

	if widgetState.dmHandle then
		widgetState.dmHandle.panelLeft = tostring(widgetState.panelPixelX) .. "px"
		widgetState.dmHandle.panelTop = tostring(widgetState.panelPixelY) .. "px"
	end
end

local function updateHaloState()
	if not widgetState.dmHandle then
		return
	end

	local showOriginHalo = widgetState.dragActive and widgetState.isNearOrigin
	local showFirstPlaceHalo = not widgetState.dragActive and widgetState.isInFirstPlace
	local showDangerHalo = not widgetState.dragActive and not showFirstPlaceHalo and widgetState.isInDanger
	widgetState.dmHandle.showOriginHalo = showOriginHalo
	widgetState.dmHandle.showFirstPlaceHalo = showFirstPlaceHalo
	widgetState.dmHandle.showDangerHalo = showDangerHalo
end

local function clampPanelPosition(panelPixelX, panelPixelY)
	local viewSizeX, viewSizeY = Spring.GetViewGeometry()
	local panelWidth, panelHeight = getPanelPixelSize()
	local maximumX = math.max(0, viewSizeX - panelWidth)
	local maximumY = math.max(0, viewSizeY - panelHeight)
	setPanelPosition(clampNumber(panelPixelX, 0, maximumX), clampNumber(panelPixelY, 0, maximumY))
end

local function savePanelPosition()
	local viewSizeX, viewSizeY = Spring.GetViewGeometry()
	if viewSizeX <= 0 or viewSizeY <= 0 then
		return
	end

	Spring.SetConfigInt(PANEL_POSITION_X_KEY, roundNumber(widgetState.panelPixelX / viewSizeX * POSITION_SCALE))
	Spring.SetConfigInt(PANEL_POSITION_Y_KEY, roundNumber(widgetState.panelPixelY / viewSizeY * POSITION_SCALE))
	widgetState.hasUserPosition = true
end

local function clearSavedPanelPosition()
	Spring.SetConfigInt(PANEL_POSITION_X_KEY, -1)
	Spring.SetConfigInt(PANEL_POSITION_Y_KEY, -1)
	widgetState.hasUserPosition = false
end

local function getFlowUIPanelTop(panelAPI)
	if not panelAPI or not panelAPI.GetPosition then
		return nil, nil
	end
	if panelAPI.isActive and not panelAPI.isActive() then
		return nil, nil
	end

	local panelPosition = panelAPI.GetPosition()
	if type(panelPosition) ~= "table" or type(panelPosition[1]) ~= "number" then
		return nil, nil
	end
	return panelPosition[1], tonumber(panelPosition[5]) or 1
end

local function getFlowUIAnchorTop()
	local highestPanelTop = 0

	for panelIndex = 1, #FLOW_UI_PANEL_API_NAMES do
		local panelTop = getFlowUIPanelTop(WG[FLOW_UI_PANEL_API_NAMES[panelIndex]])
		if panelTop and panelTop > highestPanelTop then
			highestPanelTop = panelTop
		end
	end

	return highestPanelTop
end

local function getPanelOriginPosition()
	local viewSizeX, viewSizeY = Spring.GetViewGeometry()
	local panelWidth, panelHeight = getPanelPixelSize()
	local margin = PANEL_MARGIN_DP * getDpRatio()
	local flowUIAnchorTop = getFlowUIAnchorTop()
	local maximumX = math.max(0, viewSizeX - panelWidth)
	local maximumY = math.max(0, viewSizeY - panelHeight)
	local panelPixelX = clampNumber(viewSizeX - panelWidth, 0, maximumX)
	local panelPixelY = clampNumber(viewSizeY - flowUIAnchorTop - panelHeight - margin, 0, maximumY)
	return panelPixelX, panelPixelY
end

local function positionPanelAtOrigin()
	local panelPixelX, panelPixelY = getPanelOriginPosition()
	setPanelPosition(panelPixelX, panelPixelY)
	widgetState.hasUserPosition = false
end

local function loadPanelPosition()
	local viewSizeX, viewSizeY = Spring.GetViewGeometry()
	local storedPositionX = Spring.GetConfigInt(PANEL_POSITION_X_KEY, -1)
	local storedPositionY = Spring.GetConfigInt(PANEL_POSITION_Y_KEY, -1)

	if not REVERT_TO_ORIGIN_POSITION and storedPositionX >= 0 and storedPositionY >= 0 then
		widgetState.hasUserPosition = true
		clampPanelPosition(storedPositionX / POSITION_SCALE * viewSizeX, storedPositionY / POSITION_SCALE * viewSizeY)
		return
	end

	positionPanelAtOrigin()
end

local function finishPanelDrag()
	if not widgetState.dragActive then
		return
	end
	widgetState.dragActive = false
	widgetState.isDragging = false
	local shouldSnapToOrigin = widgetState.isNearOrigin or REVERT_TO_ORIGIN_POSITION
	widgetState.isNearOrigin = false
	if widgetState.dmHandle then
		widgetState.dmHandle.isDragging = false
	end
	if shouldSnapToOrigin then
		positionPanelAtOrigin()
		clearSavedPanelPosition()
	else
		savePanelPosition()
	end
	updateHaloState()
end

local function updatePanelDrag()
	if not widgetState.dragActive then
		return
	end

	local mouseX, mouseY, _, _, _, isOffscreen = Spring.GetMouseState()
	if isOffscreen then
		return
	end

	local _, viewSizeY = Spring.GetViewGeometry()
	local draggedPanelPixelX = mouseX - widgetState.dragOffsetX
	local draggedPanelPixelY = viewSizeY - mouseY - widgetState.dragOffsetY
	local originPanelPixelX, originPanelPixelY = getPanelOriginPosition()
	local originDeltaX = draggedPanelPixelX - originPanelPixelX
	local originDeltaY = draggedPanelPixelY - originPanelPixelY
	local snapDistance = PANEL_ORIGIN_SNAP_DISTANCE_DP * getDpRatio()
	widgetState.isNearOrigin = originDeltaX * originDeltaX + originDeltaY * originDeltaY <= snapDistance * snapDistance

	if widgetState.isNearOrigin then
		setPanelPosition(originPanelPixelX, originPanelPixelY)
	else
		clampPanelPosition(draggedPanelPixelX, draggedPanelPixelY)
	end
	updateHaloState()
end

local function positionTooltip()
	if not widgetState.tooltipActive or not widgetState.dmHandle then
		return
	end

	local mouseX, mouseY, _, _, _, isOffscreen = Spring.GetMouseState()
	if isOffscreen then
		widgetState.tooltipActive = false
		widgetState.dmHandle.tooltipVisible = false
		return
	end

	local viewSizeX, viewSizeY = Spring.GetViewGeometry()
	local dpRatio = getDpRatio()
	local tooltipWidth = widgetState.tooltipWidthDp * dpRatio
	local tooltipHeight = (TOOLTIP_VERTICAL_PADDING_DP + widgetState.tooltipRowCount * TOOLTIP_ROW_HEIGHT_DP) * dpRatio
	local tooltipX = clampNumber(mouseX + TOOLTIP_OFFSET_X, 0, math.max(0, viewSizeX - tooltipWidth))
	local tooltipY = clampNumber(viewSizeY - mouseY + TOOLTIP_OFFSET_Y, 0, math.max(0, viewSizeY - tooltipHeight))

	widgetState.dmHandle.tooltipLeft = string.format("%.3fvw", tooltipX / math.max(1, viewSizeX) * 100)
	widgetState.dmHandle.tooltipTop = string.format("%.3fvh", tooltipY / math.max(1, viewSizeY) * 100)
end

local function updateScoreTooltipContent(allyTeamID)
	local dataModel = widgetState.dmHandle
	local allyTeam = widgetState.allyTeamsByID[allyTeamID]
	if not dataModel or not allyTeam then
		return false
	end

	local leader = widgetState.allyTeamsByID[widgetState.leaderAllyTeamID] or allyTeam
	local pointsBelowDeadline = math.max(0, widgetState.deadlineScore - allyTeam.score)
	local pointsBelowLeader = math.max(0, leader.score - allyTeam.score)
	local showDeadline = widgetState.hasDeadline and pointsBelowDeadline > 0

	widgetState.tooltipIsSimple = false
	widgetState.tooltipSimpleSource = nil
	widgetState.tooltipWidthDp = TOOLTIP_WIDTH_DP
	dataModel.tooltipIsSimple = false
	dataModel.tooltipWidth = tostring(TOOLTIP_WIDTH_DP) .. "dp"
	dataModel.tooltipPlayers = allyTeam.players
	dataModel.tooltipPlace = I18N("ui.territorialDomination.tooltip.place", { place = formatOrdinal(allyTeam.rank) })
	dataModel.tooltipTerritories =
		I18N("ui.territorialDomination.tooltip.territories", { count = allyTeam.territoryCount })
	dataModel.tooltipCurrentScore =
		I18N("ui.territorialDomination.tooltip.currentPoints", { points = formatScore(allyTeam.score) })
	dataModel.tooltipProjectedScore =
		I18N("ui.territorialDomination.tooltip.projectedPoints", { points = formatScore(allyTeam.projectedScore) })
	dataModel.tooltipShowDeadline = showDeadline
	dataModel.tooltipDeadlineDifference =
		I18N("ui.territorialDomination.tooltip.belowDeadline", { points = formatScore(pointsBelowDeadline) })
	dataModel.tooltipLeaderDifference =
		I18N("ui.territorialDomination.tooltip.belowLeader", { points = formatScore(pointsBelowLeader) })
	dataModel.tooltipLeaderColor = leader.color
	widgetState.tooltipRowCount = #allyTeam.players + 5 + (showDeadline and 1 or 0)
	return true
end

local function updateTeamTooltipContent(allyTeamID)
	local dataModel = widgetState.dmHandle
	local allyTeam = widgetState.allyTeamsByID[allyTeamID]
	if not dataModel or not allyTeam then
		return false
	end

	widgetState.tooltipIsSimple = false
	widgetState.tooltipSimpleSource = nil
	widgetState.tooltipWidthDp = TOOLTIP_WIDTH_DP
	dataModel.tooltipIsSimple = false
	dataModel.tooltipWidth = tostring(TOOLTIP_WIDTH_DP) .. "dp"
	dataModel.tooltipPlayers = allyTeam.players
	widgetState.tooltipRowCount = math.max(1, #allyTeam.players)
	return true
end

local function updateSimpleTooltipContent()
	local dataModel = widgetState.dmHandle
	if not dataModel then
		return false
	end

	local tooltipText
	local tooltipWidthDp
	if widgetState.tooltipSimpleSource == TOOLTIP_SOURCE_CURRENT_SCORE then
		tooltipText = dataModel.footerScoreTooltip
		tooltipWidthDp = TOOLTIP_CURRENT_SCORE_WIDTH_DP
	elseif widgetState.tooltipSimpleSource == TOOLTIP_SOURCE_COUNTDOWN then
		tooltipText = dataModel.footerCountdownTooltip
		tooltipWidthDp = TOOLTIP_COUNTDOWN_WIDTH_DP
	elseif widgetState.tooltipSimpleSource == TOOLTIP_SOURCE_TARGET then
		tooltipText = dataModel.footerTargetTooltip
		tooltipWidthDp = TOOLTIP_TARGET_WIDTH_DP
	else
		return false
	end

	widgetState.tooltipWidthDp = tooltipWidthDp
	widgetState.tooltipRowCount = 1
	dataModel.tooltipIsSimple = true
	dataModel.tooltipIsScore = false
	dataModel.tooltipText = tooltipText
	dataModel.tooltipWidth = tostring(tooltipWidthDp) .. "dp"
	return true
end

local function showScoreTooltip(event, allyTeamID)
	widgetState.tooltipIsScore = true
	widgetState.tooltipAllyTeamID = tonumber(allyTeamID)
	widgetState.tooltipActive = updateScoreTooltipContent(widgetState.tooltipAllyTeamID)

	if widgetState.dmHandle then
		widgetState.dmHandle.tooltipIsScore = true
		widgetState.dmHandle.tooltipVisible = widgetState.tooltipActive and widgetState.shouldShow
	end
	positionTooltip()
end

local function showTeamTooltip(event, allyTeamID)
	widgetState.tooltipIsScore = false
	widgetState.tooltipAllyTeamID = tonumber(allyTeamID)
	widgetState.tooltipActive = updateTeamTooltipContent(widgetState.tooltipAllyTeamID)

	if widgetState.dmHandle then
		widgetState.dmHandle.tooltipIsScore = false
		widgetState.dmHandle.tooltipVisible = widgetState.tooltipActive and widgetState.shouldShow
	end
	positionTooltip()
end

local function showSimpleTooltip(tooltipSource)
	widgetState.tooltipIsScore = false
	widgetState.tooltipIsSimple = true
	widgetState.tooltipAllyTeamID = nil
	widgetState.tooltipSimpleSource = tooltipSource
	widgetState.tooltipActive = updateSimpleTooltipContent()

	if widgetState.dmHandle then
		widgetState.dmHandle.tooltipVisible = widgetState.tooltipActive and widgetState.shouldShow
	end
	positionTooltip()
end

local function showCurrentScoreTooltip(event)
	showSimpleTooltip(TOOLTIP_SOURCE_CURRENT_SCORE)
end

local function showCountdownTooltip(event)
	showSimpleTooltip(TOOLTIP_SOURCE_COUNTDOWN)
end

local function showTargetTooltip(event)
	showSimpleTooltip(TOOLTIP_SOURCE_TARGET)
end

local function hideTooltip(event)
	widgetState.tooltipActive = false
	widgetState.tooltipAllyTeamID = nil
	widgetState.tooltipSimpleSource = nil
	if widgetState.dmHandle then
		widgetState.dmHandle.tooltipVisible = false
	end
end

local function beginPanelDrag(event)
	local eventParameters = event and event.parameters
	if eventParameters and eventParameters.button and eventParameters.button ~= 0 then
		return
	end

	local mouseX, mouseY = Spring.GetMouseState()
	local _, viewSizeY = Spring.GetViewGeometry()
	widgetState.dragActive = true
	widgetState.isDragging = true
	widgetState.isNearOrigin = false
	widgetState.dragOffsetX = mouseX - widgetState.panelPixelX
	widgetState.dragOffsetY = viewSizeY - mouseY - widgetState.panelPixelY
	if widgetState.dmHandle then
		widgetState.dmHandle.isDragging = true
	end
	hideTooltip()
	updateHaloState()

	if event and event.StopPropagation then
		event:StopPropagation()
	end
end

local function blockPanelDrag(event)
	if event and event.StopPropagation then
		event:StopPropagation()
	end
end

local function setExpandedState(isExpanded)
	if widgetState.isExpanded == isExpanded then
		return
	end

	local expandedHeightDifference = (PANEL_EXPANDED_HEIGHT_DP - PANEL_COLLAPSED_HEIGHT_DP) * getDpRatio()
	widgetState.isExpanded = isExpanded
	if widgetState.dmHandle then
		widgetState.dmHandle.isExpanded = widgetState.isExpanded
	end
	if REVERT_TO_ORIGIN_POSITION or not widgetState.hasUserPosition then
		positionPanelAtOrigin()
	else
		local adjustedPanelPixelY = widgetState.panelPixelY
			+ (isExpanded and -expandedHeightDifference or expandedHeightDifference)
		clampPanelPosition(widgetState.panelPixelX, adjustedPanelPixelY)
	end
end

local function toggleExpanded(event)
	setExpandedState(not widgetState.isExpanded)
	hideTooltip()
	if widgetState.hasUserPosition and not REVERT_TO_ORIGIN_POSITION then
		savePanelPosition()
	end

	if event and event.StopPropagation then
		event:StopPropagation()
	end
end

local function adoptSpectatorTeam(teamID)
	local oldMapDrawMode = Spring.GetMapDrawMode()
	if Spring.SelectUnitArray then
		Spring.SelectUnitArray({})
	end
	Spring.SendCommands("specteam " .. teamID)
	local newMapDrawMode = Spring.GetMapDrawMode()
	if oldMapDrawMode == "los" and oldMapDrawMode ~= newMapDrawMode then
		Spring.SendCommands("togglelos")
	end
end

local function selectExpandedScore(event, allyTeamID)
	if not widgetState.isExpanded then
		return
	end

	if Spring.GetSpectatingState() then
		local selectedAllyTeamID = tonumber(allyTeamID)
		local selectedAllyTeam = selectedAllyTeamID and widgetState.allyTeamsByID[selectedAllyTeamID]
		if selectedAllyTeam and selectedAllyTeam.firstLivingTeamID then
			widgetState.spectatorSelectedAllyTeamID = selectedAllyTeamID
			adoptSpectatorTeam(selectedAllyTeam.firstLivingTeamID)
		else
			widgetState.spectatorSelectedAllyTeamID = nil
		end
	else
		widgetState.spectatorSelectedAllyTeamID = nil
	end

	setExpandedState(false)
	hideTooltip()
	widgetState.updateAccumulator = DATA_UPDATE_INTERVAL

	if event and event.StopPropagation then
		event:StopPropagation()
	end
end

local function initializeModel()
	return {
		isVisible = false,
		isExpanded = false,
		isDragging = false,
		showOriginHalo = false,
		showFirstPlaceHalo = false,
		showDangerHalo = false,
		panelLeft = "0px",
		panelTop = "0px",
		distributionSegments = {},
		selectedAllyTeamID = -1,
		selectedProjectedWidth = "0%",
		selectedDarkColor = makeColorString(DEFAULT_COLOR, DARK_COLOR_MULTIPLIER),
		selectedActualWidth = "0%",
		selectedColor = makeColorString(DEFAULT_COLOR),
		hasDeadline = false,
		deadlineLineBottom = tostring(VERTICAL_TRACK_BOTTOM_DP) .. "dp",
		deadlineLabel = DEADLINE_SKULL_ICON,
		deadlineLabelBottom = tostring(DEADLINE_LABEL_OFFSET_DP) .. "dp",
		verticalContentWidth = tostring(VERTICAL_CONTENT_MINIMUM_WIDTH_DP) .. "dp",
		verticalBarsOverflow = false,
		verticalBars = {},
		footerScore = "0 pts",
		countdownWarning = false,
		footerCountdown = "0:00",
		footerTargetIcon = "🏆",
		footerTargetValue = "0",
		tooltipVisible = false,
		tooltipLeft = "0px",
		tooltipTop = "0px",
		tooltipWidth = tostring(TOOLTIP_WIDTH_DP) .. "dp",
		tooltipIsScore = true,
		tooltipIsSimple = false,
		tooltipText = "",
		tooltipPlayers = {},
		tooltipTerritories = "",
		tooltipCurrentScore = "",
		tooltipProjectedScore = "",
		tooltipShowDeadline = false,
		tooltipDeadlineDifference = "",
		tooltipLeaderDifference = "",
		tooltipLeaderColor = makeColorString(DEFAULT_COLOR),
		tooltipPlace = "",
		footerScoreTooltip = I18N("ui.territorialDomination.tooltip.currentScore"),
		footerCountdownTooltip = I18N("ui.territorialDomination.tooltip.timeUntilFirstDeadline"),
		footerTargetTooltip = I18N("ui.territorialDomination.tooltip.highestScore"),
		popupVisible = false,
		popupTitle = "",
		popupRateText = "",
		popupDeadlineText = "",
		beginPanelDrag = beginPanelDrag,
		blockPanelDrag = blockPanelDrag,
		toggleExpanded = toggleExpanded,
		selectExpandedScore = selectExpandedScore,
		hideTooltip = hideTooltip,
		showTeamTooltip = showTeamTooltip,
		showScoreTooltip = showScoreTooltip,
		showCurrentScoreTooltip = showCurrentScoreTooltip,
		showCountdownTooltip = showCountdownTooltip,
		showTargetTooltip = showTargetTooltip,
	}
end

local function getShouldShow()
	local _, _, isClientPaused = Spring.GetGameState()
	local isGUIHidden = Spring.IsGUIHidden and Spring.IsGUIHidden()
	return Spring.GetGameSeconds() > 0
		and widgetState.totalTerritories > 0
		and not isClientPaused
		and not isGUIHidden
		and not widgetState.hiddenByLobby
end

local function synchronizeVisibility()
	if not widgetState.dmHandle then
		return
	end

	widgetState.shouldShow = getShouldShow()
	widgetState.dmHandle.isVisible = widgetState.shouldShow
	widgetState.dmHandle.popupVisible = widgetState.popupActive and widgetState.shouldShow

	if not widgetState.shouldShow then
		widgetState.tooltipActive = false
		widgetState.tooltipAllyTeamID = nil
	end
	widgetState.dmHandle.tooltipVisible = widgetState.tooltipActive and widgetState.shouldShow
end

local function hidePopup()
	widgetState.popupActive = false
	if widgetState.dmHandle then
		widgetState.dmHandle.popupVisible = false
	end
end

local function countLivingLeaders(allyTeams, livingLeader)
	if not livingLeader then
		return 0
	end

	local livingLeaderCount = 0
	for allyTeamIndex = 1, #allyTeams do
		local allyTeam = allyTeams[allyTeamIndex]
		if allyTeam.isAlive and allyTeam.rank == livingLeader.rank then
			livingLeaderCount = livingLeaderCount + 1
		end
	end
	return livingLeaderCount
end

local function getFinalPopupTitle(allyTeams, livingLeader)
	if countLivingLeaders(allyTeams, livingLeader) > 1 then
		return I18N("ui.territorialDomination.deadline.end")
	end

	local isSpectating = Spring.GetSpectatingState()
	if isSpectating then
		return I18N("ui.territorialDomination.deadlinePopup.gameOver")
	end

	local localAllyTeamID = Spring.GetLocalAllyTeamID()
	if livingLeader and livingLeader.allyTeamID == localAllyTeamID then
		return I18N("ui.territorialDomination.deadlinePopup.victory")
	end
	return I18N("ui.territorialDomination.deadlinePopup.defeat")
end

local function showDeadlinePopup(currentDeadline, maxDeadlines, deadlineScore, allyTeams, livingLeader)
	if not widgetState.dmHandle then
		return
	end

	if currentDeadline > maxDeadlines then
		widgetState.dmHandle.popupTitle = getFinalPopupTitle(allyTeams, livingLeader)
		widgetState.dmHandle.popupRateText = ""
		widgetState.dmHandle.popupDeadlineText = ""
	else
		if currentDeadline == maxDeadlines then
			widgetState.dmHandle.popupTitle = I18N("ui.territorialDomination.deadlinePopup.finalDeadline")
		else
			widgetState.dmHandle.popupTitle =
				I18N("ui.territorialDomination.deadlinePopup.deadline", { deadlineNumber = currentDeadline })
		end
		widgetState.dmHandle.popupRateText =
			I18N("ui.territorialDomination.deadlinePopup.territoryRate", { points = formatScore(currentDeadline) })
		widgetState.dmHandle.popupDeadlineText = deadlineScore > 0
				and I18N(
					"ui.territorialDomination.deadlinePopup.eliminationBelow",
					{ threshold = formatScore(deadlineScore) }
				)
			or ""
	end

	widgetState.popupActive = true
	widgetState.popupStartClock = os.clock()
	local shouldShow = getShouldShow()
	widgetState.dmHandle.popupVisible = shouldShow

	if shouldShow then
		Spring.PlaySoundFile("sounds/global-events/scavlootdrop.wav", 0.8, "ui")
		Spring.PlaySoundFile("sounds/replies/servlrg3.wav", 1, "ui")
	end
end

local function updateDeadlinePopup(currentDeadline, maxDeadlines, deadlineScore, allyTeams, livingLeader)
	if currentDeadline <= 0 or maxDeadlines <= 0 or Spring.GetGameSeconds() <= 0 then
		return
	end

	if not widgetState.hasObservedDeadline then
		widgetState.hasObservedDeadline = true
		widgetState.lastObservedDeadline = currentDeadline
		if currentDeadline == 1 and Spring.GetGameSeconds() <= POPUP_INITIAL_WINDOW_SECONDS then
			showDeadlinePopup(currentDeadline, maxDeadlines, deadlineScore, allyTeams, livingLeader)
		end
		return
	end

	if currentDeadline ~= widgetState.lastObservedDeadline then
		widgetState.lastObservedDeadline = currentDeadline
		showDeadlinePopup(currentDeadline, maxDeadlines, deadlineScore, allyTeams, livingLeader)
	end
end

local function updateLeadNotification(livingLeader)
	local isSpectating = Spring.GetSpectatingState()
	local localAllyTeamID = Spring.GetLocalAllyTeamID()
	local localAllyTeam = widgetState.allyTeamsByID[localAllyTeamID]

	if isSpectating or not localAllyTeam then
		widgetState.lastWasInLead = nil
		return
	end

	local isInLead = (localAllyTeam.isAlive and livingLeader and livingLeader.allyTeamID == localAllyTeam.allyTeamID)
			and true
		or false

	if widgetState.lastWasInLead == nil then
		widgetState.lastWasInLead = isInLead
		return
	end

	if isInLead ~= widgetState.lastWasInLead then
		if WG.notifications and WG.notifications.addEvent then
			if isInLead then
				WG.notifications.addEvent("TerritorialDomination/GainedLead", false)
			else
				WG.notifications.addEvent("TerritorialDomination/LostLead", false)
			end
		end
		widgetState.lastWasInLead = isInLead
	end
end

local function updateDataModel()
	local dataModel = widgetState.dmHandle
	if not dataModel then
		return
	end

	local currentDeadline = tonumber(Spring.GetGameRulesParam("territorialDominationCurrentDeadline"))
		or widgetState.currentDeadline
	local maxDeadlines = tonumber(Spring.GetGameRulesParam("territorialDominationMaxDeadlines"))
		or DEFAULT_MAX_DEADLINES
	local deadlineEndTimestamp = tonumber(Spring.GetGameRulesParam("territorialDominationDeadlineEndTimestamp")) or 0
	local deadlineScore = tonumber(Spring.GetGameRulesParam("territorialDominationDeadlineScore")) or 0
	local totalTerritories = tonumber(Spring.GetGameRulesParam("territorialDominationTotalTerritories")) or 0
	local allyTeams, allyTeamsByID = collectAllyTeamData()
	local livingLeader = findLivingLeader(allyTeams)
	local selectedAllyTeam = chooseSelectedAllyTeam(allyTeams, allyTeamsByID, livingLeader)
	local highestScore = getHighestScore(allyTeams)
	local hasDeadline = currentDeadline <= maxDeadlines and deadlineEndTimestamp > 0 and deadlineScore > 0
	local verticalScale = math.max(1, totalTerritories, highestScore, hasDeadline and deadlineScore or 0)
	local selectedScore = selectedAllyTeam and selectedAllyTeam.score or 0
	local selectedProjectedScore = selectedAllyTeam and selectedAllyTeam.projectedScore or 0
	local horizontalScale

	if hasDeadline and selectedScore < deadlineScore then
		horizontalScale = math.max(1, deadlineScore)
	else
		horizontalScale = math.max(1, highestScore, totalTerritories)
	end

	local distributionSegments, ascendingAllyTeams = buildDistributionData(allyTeams)

	widgetState.allyTeams = allyTeams
	widgetState.allyTeamsByID = allyTeamsByID
	widgetState.selectedAllyTeamID = selectedAllyTeam and selectedAllyTeam.allyTeamID or -1
	widgetState.leaderAllyTeamID = livingLeader and livingLeader.allyTeamID or -1
	widgetState.currentDeadline = currentDeadline
	widgetState.maxDeadlines = maxDeadlines
	widgetState.deadlineEndTimestamp = deadlineEndTimestamp
	widgetState.deadlineScore = deadlineScore
	widgetState.totalTerritories = totalTerritories
	widgetState.hasDeadline = hasDeadline
	widgetState.isInFirstPlace = selectedAllyTeam ~= nil and selectedAllyTeam.rank == 1
	widgetState.isInDanger = not widgetState.isInFirstPlace
		and (
			(hasDeadline and selectedProjectedScore < deadlineScore)
			or (currentDeadline == maxDeadlines and selectedAllyTeam ~= nil)
		)
	updateHaloState()

	local overflowingContentWidth = #allyTeams * VERTICAL_SLOT_WIDTH_DP + VERTICAL_CONTENT_PADDING_DP
	local verticalBarsOverflow = overflowingContentWidth > VERTICAL_CONTENT_MINIMUM_WIDTH_DP
	local verticalContentWidth = verticalBarsOverflow and overflowingContentWidth or VERTICAL_CONTENT_MINIMUM_WIDTH_DP

	dataModel.distributionSegments = distributionSegments
	dataModel.verticalBars = buildVerticalBars(ascendingAllyTeams, verticalScale)
	dataModel.verticalBarsOverflow = verticalBarsOverflow
	dataModel.verticalContentWidth = string.format("%.3fdp", verticalContentWidth)
	dataModel.selectedAllyTeamID = widgetState.selectedAllyTeamID
	dataModel.selectedColor = selectedAllyTeam and selectedAllyTeam.color or makeColorString(DEFAULT_COLOR)
	dataModel.selectedDarkColor = selectedAllyTeam and selectedAllyTeam.darkColor
		or makeColorString(DEFAULT_COLOR, DARK_COLOR_MULTIPLIER)
	dataModel.selectedActualWidth = formatPercentage(selectedScore / horizontalScale * 100)
	dataModel.selectedProjectedWidth = formatPercentage(selectedProjectedScore / horizontalScale * 100)
	dataModel.hasDeadline = hasDeadline
	dataModel.deadlineLineBottom = string.format(
		"%.3fdp",
		VERTICAL_TRACK_BOTTOM_DP + clampNumber(deadlineScore / verticalScale, 0, 1) * VERTICAL_TRACK_HEIGHT_DP
	)
	dataModel.deadlineLabel = DEADLINE_SKULL_ICON
	dataModel.deadlineLabelBottom = tostring(DEADLINE_LABEL_OFFSET_DP) .. "dp"
	dataModel.footerScore = formatScore(selectedScore) .. " pts"
	dataModel.footerScoreTooltip = I18N("ui.territorialDomination.tooltip.currentScore")

	local countdownText, remainingSeconds = formatCountdown(deadlineEndTimestamp, currentDeadline, maxDeadlines)
	dataModel.footerCountdown = countdownText
	dataModel.countdownWarning = currentDeadline <= maxDeadlines
		and deadlineEndTimestamp > 0
		and remainingSeconds <= COUNTDOWN_WARNING_SECONDS

	if currentDeadline >= maxDeadlines then
		dataModel.footerCountdownTooltip = I18N("ui.territorialDomination.tooltip.timeUntilHighestScoreWins")
	elseif currentDeadline <= 1 or not hasDeadline then
		dataModel.footerCountdownTooltip = I18N("ui.territorialDomination.tooltip.timeUntilFirstDeadline")
	else
		dataModel.footerCountdownTooltip = I18N("ui.territorialDomination.tooltip.timeUntilNextDeadline")
	end

	if hasDeadline then
		dataModel.footerTargetIcon = DEADLINE_SKULL_ICON
		dataModel.footerTargetValue = formatScore(deadlineScore)
		dataModel.footerTargetTooltip = I18N("ui.territorialDomination.tooltip.deadlineScore")
	else
		local localAllyTeamID = Spring.GetLocalAllyTeamID()
		local localAllyTeam = allyTeamsByID[localAllyTeamID]
		local isSpectating = Spring.GetSpectatingState()
		local isLocalHighestScore = not isSpectating and localAllyTeam and localAllyTeam.score == highestScore
		dataModel.footerTargetIcon = "🏆"
		dataModel.footerTargetValue = formatScore(highestScore)
		dataModel.footerTargetTooltip = isLocalHighestScore and I18N("ui.territorialDomination.tooltip.highestScoreYou")
			or I18N("ui.territorialDomination.tooltip.highestScore")
	end

	if widgetState.tooltipActive then
		if widgetState.tooltipIsSimple then
			widgetState.tooltipActive = updateSimpleTooltipContent()
		elseif widgetState.tooltipAllyTeamID and widgetState.tooltipIsScore then
			widgetState.tooltipActive = updateScoreTooltipContent(widgetState.tooltipAllyTeamID)
		elseif widgetState.tooltipAllyTeamID then
			widgetState.tooltipActive = updateTeamTooltipContent(widgetState.tooltipAllyTeamID)
		end
	end

	updateLeadNotification(livingLeader)
	updateDeadlinePopup(currentDeadline, maxDeadlines, deadlineScore, allyTeams, livingLeader)
end

function WIDGET:Initialize()
	widgetState.rmlContext = RmlUi.GetContext("shared")
	if not widgetState.rmlContext then
		return false
	end

	RmlUi.LoadFontFace(EMOJI_FONT_PATH, true)
	widgetState.dmHandle = widgetState.rmlContext:OpenDataModel(MODEL_NAME, initializeModel(), self)
	if not widgetState.dmHandle then
		widgetState.rmlContext = nil
		return false
	end

	widgetState.document = widgetState.rmlContext:LoadDocument(RML_PATH, self)
	if not widgetState.document then
		widgetState.rmlContext:RemoveDataModel(MODEL_NAME)
		widgetState.dmHandle = nil
		widgetState.rmlContext = nil
		return false
	end

	widgetState.document:Show()
	widgetState.document:AddEventListener("mouseup", function()
		finishPanelDrag()
	end, false)
	loadPanelPosition()
	updateDataModel()
	synchronizeVisibility()
	return true
end

function WIDGET:Shutdown()
	finishPanelDrag()
	hidePopup()

	if widgetState.document then
		widgetState.document:Close()
		widgetState.document = nil
	end
	if widgetState.rmlContext and widgetState.dmHandle then
		widgetState.rmlContext:RemoveDataModel(MODEL_NAME)
	end

	widgetState.dmHandle = nil
	widgetState.rmlContext = nil
end

function WIDGET:Update(deltaTime)
	updatePanelDrag()
	positionTooltip()

	local currentClock = os.clock()
	local elapsedTime = tonumber(deltaTime) or math.max(0, currentClock - widgetState.lastUpdateClock)
	widgetState.lastUpdateClock = currentClock
	widgetState.updateAccumulator = widgetState.updateAccumulator + elapsedTime

	if widgetState.updateAccumulator >= DATA_UPDATE_INTERVAL then
		widgetState.updateAccumulator = widgetState.updateAccumulator % DATA_UPDATE_INTERVAL
		updateDataModel()
		if not widgetState.dragActive and (REVERT_TO_ORIGIN_POSITION or not widgetState.hasUserPosition) then
			positionPanelAtOrigin()
		end
	end

	if widgetState.popupActive and currentClock - widgetState.popupStartClock >= POPUP_DURATION_SECONDS then
		hidePopup()
	end

	synchronizeVisibility()
end

function WIDGET:RecvLuaMsg(message, playerID)
	if message:sub(1, 19) == "LobbyOverlayActive0" then
		widgetState.hiddenByLobby = false
	elseif message:sub(1, 19) == "LobbyOverlayActive1" then
		widgetState.hiddenByLobby = true
		hidePopup()
	end
	synchronizeVisibility()
end

function WIDGET:GamePaused(playerID, isPaused)
	synchronizeVisibility()
end

function WIDGET:ViewResize()
	widgetState.dragActive = false
	widgetState.isDragging = false
	widgetState.isNearOrigin = false
	if widgetState.dmHandle then
		widgetState.dmHandle.isDragging = false
	end
	loadPanelPosition()
	positionTooltip()
	updateHaloState()
end

function WIDGET:PlayerChanged(playerID)
	widgetState.updateAccumulator = DATA_UPDATE_INTERVAL
end

function WIDGET:GameOver()
	updateDataModel()
	synchronizeVisibility()
end

function WIDGET:KeyPress(key, modifiers, isRepeat)
	if key == KEY_ESCAPE and widgetState.isExpanded then
		setExpandedState(false)
		hideTooltip()
		if widgetState.hasUserPosition and not REVERT_TO_ORIGIN_POSITION then
			savePanelPosition()
		end
		return true
	end
	return false
end
