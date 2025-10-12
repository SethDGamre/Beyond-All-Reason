local widget = widget ---@type Widget

-- Include the substitution logic directly with a shorter alias
local SubLogic = VFS.Include("luaui/Include/blueprint_substitution/logic.lua")

function widget:GetInfo()
	return {
		name = "Pregame Queue",
		desc = "Drawing and queue handling for pregame building",
		author = "Hobo Joe, based on buildmenu from assorted authors",
		date = "May 2023",
		license = "GNU GPL, v2 or later",
		layer = 1,
		enabled = true,
	}
end

local spTestBuildOrder = Spring.TestBuildOrder
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spGetModKeyState = Spring.GetModKeyState
local spGetBuildFacing = Spring.GetBuildFacing
local spSetBuildFacing = Spring.SetBuildFacing
local spPos2BuildPos = Spring.Pos2BuildPos
local spGetTeamStartPosition = Spring.GetTeamStartPosition
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spSendCommands = Spring.SendCommands
local spGetMapDrawMode = Spring.GetMapDrawMode
local spGetBuildSpacing = Spring.GetBuildSpacing
local spSetBuildSpacing = Spring.SetBuildSpacing
local spGetGameFrame = Spring.GetGameFrame
local spGetMyTeamID = Spring.GetMyTeamID
local spGetMyPlayerID = Spring.GetMyPlayerID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetGroundHeight = Spring.GetGroundHeight
local spGetGameRulesParam = Spring.GetGameRulesParam
local spEcho = Spring.Echo
local spLog = Spring.Log
local spGetSpectatingState = Spring.GetSpectatingState
local spGetConfigInt = Spring.GetConfigInt
local spGetInvertQueueKey = Spring.GetInvertQueueKey
local spIsGUIHidden = Spring.IsGUIHidden

local unitDefCache = {}
local buildingOutlineCache = {}
local circleCache = {}

local function getUnitDef(unitDefID)
	if not unitDefID or unitDefID <= 0 then return nil end
	if not unitDefCache[unitDefID] then
		unitDefCache[unitDefID] = UnitDefs and UnitDefs[unitDefID]
	end
	return unitDefCache[unitDefID]
end

local function getBuildingDimensions(unitDefID, facing)
	local def = getUnitDef(unitDefID)
	if not def then return 16, 16 end -- fallback
	if facing % 2 == 1 then
		return 4 * def.zsize, 4 * def.xsize
	else
		return 4 * def.xsize, 4 * def.zsize
	end
end

local function getBuildingOutlineVertices(unitDefID, facing)
	local cacheKey = unitDefID .. ":" .. facing
	if not buildingOutlineCache[cacheKey] then
		local bw, bh = getBuildingDimensions(unitDefID, facing)
		buildingOutlineCache[cacheKey] = {
			{ v = { -bw, 0, -bh } },
			{ v = { bw, 0, -bh } },
			{ v = { bw, 0, bh } },
			{ v = { -bw, 0, bh } },
		}
	end
	return buildingOutlineCache[cacheKey]
end

local function getCircleVertices(radius, segments)
	local cacheKey = radius .. ":" .. segments
	if not circleCache[cacheKey] then
		local vertices = {}
		for i = 0, segments do
			local angle = (i / segments) * (math.pi * 2)
			vertices[i + 1] = { v = { math.cos(angle) * radius, 0, math.sin(angle) * radius } }
		end
		circleCache[cacheKey] = vertices
	end
	return circleCache[cacheKey]
end

local function isUnderwater(unitDefID)
	local def = getUnitDef(unitDefID)
	return def and def.modCategories and def.modCategories.underwater or false
end

local function getUnitCanCompleteQueue(unitID)
	local unitDefID = spGetUnitDefID(unitID)
	if startDefID and unitDefID == startDefID then
		return true
	end

	local def = getUnitDef(unitDefID)
	if not def or not def.buildOptions then return false end

	-- What can this unit build?
	for i = 1, #buildQueue do
		if not def.buildOptions[buildQueue[i][1]] then
			return false
		end
	end
	return true
end

local buildQueue = {}
local selBuildQueueDefID
local facingMap = { south = 0, east = 1, north = 2, west = 3 }

local isSpec = spGetSpectatingState()
local myTeamID = spGetMyTeamID()
local preGamestartPlayer = spGetGameFrame() == 0 and not isSpec
local startDefID = spGetTeamRulesParam(myTeamID, "startUnit")
local prevStartDefID = startDefID
local metalMap = false

local unitshapes = {}

local dragActive = false
local dragStartPosition = nil
local dragPreviewPositions = {}
local DRAG_PREVIEW_ALPHA = 0.5
local potentialDragStart = false
local dragStartMousePos = nil
local DRAG_THRESHOLD = spGetConfigInt("MouseDragSelectionThreshold", 4)

local function clearDrag()
	dragActive = false
	dragStartPosition = nil
	dragPreviewPositions = {}
	potentialDragStart = false
	dragStartMousePos = nil
end

local function snapBuildPosition(unitDefID, worldX, worldY, worldZ, buildFacing)
	local snappedX, snappedY, snappedZ = spPos2BuildPos(unitDefID, worldX, worldY, worldZ, buildFacing)
	return snappedX, snappedY, snappedZ
end


local function getBuildingCenterStep(unitDefID, buildFacing)
	local SQUARE_SIZE = 8
	local buildSpacing = spGetBuildSpacing() or 0
	
	local def = getUnitDef(unitDefID)
	local footprintWidth
	local footprintHeight
	if buildFacing % 2 == 1 then
		footprintWidth = SQUARE_SIZE * def.zsize
		footprintHeight = SQUARE_SIZE * def.xsize
	else
		footprintWidth = SQUARE_SIZE * def.xsize
		footprintHeight = SQUARE_SIZE * def.zsize
	end
	
	local stepWidth = footprintWidth + SQUARE_SIZE * buildSpacing * 2
	local stepHeight = footprintHeight + SQUARE_SIZE * buildSpacing * 2
	
	return stepWidth, stepHeight
end

local function buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
	return snappedX..":"..snappedY..":"..snappedZ..":"..buildFacing
end


local function fillRow(x, z, xStep, zStep, n, facing)
	local result = {}
	for _ = 1, n do
		result[#result + 1] = { x, 0, z, facing }
		x = x + xStep
		z = z + zStep
	end
	return result
end

local function computeBoxPreviewPositions(unitDefID, startPosition, endPosition, buildFacing)
	local computedPositions = {}
	local seenPositions = {}
	local startX, startY, startZ = snapBuildPosition(unitDefID, startPosition[1], startPosition[2], startPosition[3], buildFacing)
	local endX, endY, endZ = snapBuildPosition(unitDefID, endPosition[1], endPosition[2], endPosition[3], buildFacing)
	local stepWidth, stepDepth = getBuildingCenterStep(unitDefID, buildFacing)
	local deltaX = endX - startX
	local deltaZ = endZ - startZ
	
	local xSteps = math.floor(math.abs(deltaX) / stepWidth) + 1
	local zSteps = math.floor(math.abs(deltaZ) / stepDepth) + 1
	
	local xDirection = deltaX >= 0 and 1 or -1
	local zDirection = deltaZ >= 0 and 1 or -1
	
	local xStep = stepWidth * xDirection
	local zStep = stepDepth * zDirection
	
	if xSteps > 1 and zSteps > 1 then
		-- go down left side
		local leftSide = fillRow(startX, startZ + zStep, 0, zStep, zSteps - 1, buildFacing)
		for _, pos in ipairs(leftSide) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
		
		-- go right bottom side
		local bottomSide = fillRow(startX + xStep, startZ + (zSteps - 1) * zStep, xStep, 0, xSteps - 1, buildFacing)
		for _, pos in ipairs(bottomSide) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
		
		-- go up right side
		local rightSide = fillRow(startX + (xSteps - 1) * xStep, startZ + (zSteps - 2) * zStep, 0, -zStep, zSteps - 1, buildFacing)
		for _, pos in ipairs(rightSide) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
		
		-- go left top side
		local topSide = fillRow(startX + (xSteps - 2) * xStep, startZ, -xStep, 0, xSteps - 1, buildFacing)
		for _, pos in ipairs(topSide) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
	elseif xSteps == 1 then
		local singleRow = fillRow(startX, startZ, 0, zStep, zSteps, buildFacing)
		for _, pos in ipairs(singleRow) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
	elseif zSteps == 1 then
		local singleRow = fillRow(startX, startZ, xStep, 0, xSteps, buildFacing)
		for _, pos in ipairs(singleRow) do
			local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, pos[1], startY, pos[3], buildFacing)
			local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
			if not seenPositions[k] then
				seenPositions[k] = true
				computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
			end
		end
	end
	
	return computedPositions
end

local function computeDragPreviewPositions(unitDefID, startPosition, endPosition, buildFacing, useGridPlacement, useBoxPlacement)
	if useBoxPlacement then
		return computeBoxPreviewPositions(unitDefID, startPosition, endPosition, buildFacing)
	end
	
	local computedPositions = {}
	local seenPositions = {}
	local startX, startY, startZ = snapBuildPosition(unitDefID, startPosition[1], startPosition[2], startPosition[3], buildFacing)
	local endX, endY, endZ = snapBuildPosition(unitDefID, endPosition[1], endPosition[2], endPosition[3], buildFacing)
	local stepWidth, stepDepth = getBuildingCenterStep(unitDefID, buildFacing)
	local deltaX = endX - startX
	local deltaZ = endZ - startZ
	if useGridPlacement then
		local numX = math.max(1, math.floor(math.abs(deltaX) / stepWidth) + 1)
		local numZ = math.max(1, math.floor(math.abs(deltaZ) / stepDepth) + 1)
		local stepDirX = deltaX >= 0 and stepWidth or -stepWidth
		local stepDirZ = deltaZ >= 0 and stepDepth or -stepDepth
		local rowStartX = startX
		local rowZ = startZ
		for _ = 1, numZ do
			local currentX = rowStartX
			for _ = 1, numX do
				local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, currentX, startY, rowZ, buildFacing)
				local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
				if not seenPositions[k] then
					seenPositions[k] = true
					computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
				end
				currentX = currentX + stepDirX
			end
			rowZ = rowZ + stepDirZ
		end
	else
		local lineDominatesX = math.abs(deltaX) >= math.abs(deltaZ)
		if lineDominatesX then
			local count = math.max(1, math.floor(math.abs(deltaX) / stepWidth) + 1)
			local dir = deltaX >= 0 and stepWidth or -stepWidth
			local currentX = startX
			for i = 1, count do
				local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, currentX, startY, startZ + math.floor((deltaZ / math.max(1, count - 1)) * (i - 1)), buildFacing)
				local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
				if not seenPositions[k] then
					seenPositions[k] = true
					computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
				end
				currentX = currentX + dir
			end
		else
			local count = math.max(1, math.floor(math.abs(deltaZ) / stepDepth) + 1)
			local dir = deltaZ >= 0 and stepDepth or -stepDepth
			local currentZ = startZ
			for i = 1, count do
				local snappedX, snappedY, snappedZ = snapBuildPosition(unitDefID, startX + math.floor((deltaX / math.max(1, count - 1)) * (i - 1)), startY, currentZ, buildFacing)
				local k = buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
				if not seenPositions[k] then
					seenPositions[k] = true
					computedPositions[#computedPositions + 1] = { unitDefID, snappedX, snappedY, snappedZ, buildFacing }
				end
				currentZ = currentZ + dir
			end
		end
	end
	return computedPositions
end

local function buildFacingHandler(_, _, args)
	if not (preGamestartPlayer and selBuildQueueDefID) then
		return
	end

	local facing = spGetBuildFacing()
	if args and args[1] == "inc" then
		facing = (facing + 1) % 4
		spSetBuildFacing(facing)
		return true
	elseif args and args[1] == "dec" then
		facing = (facing - 1) % 4
		spSetBuildFacing(facing)
		return true
	elseif args and facingMap[args[1]] then
		spSetBuildFacing(facingMap[args[1]])
		return true
	end
end

------------------------------------------
---          QUEUE HANDLING            ---
------------------------------------------
local function handleBuildMenu(shift)
	local grid = WG["gridmenu"]
	if not grid or not grid.clearCategory or not grid.getAlwaysReturn or not grid.setCurrentCategory then
		return
	end

	if shift and grid.getAlwaysReturn() then
		grid.setCurrentCategory(nil)
	elseif not shift then
		grid.clearCategory()
	end
end

local FORCE_SHOW_REASON = "gui_pregame_build"
local function setPreGamestartDefID(uDefID)
	selBuildQueueDefID = uDefID

	-- Communicate selected unit to quick start UI via WG
	if preGamestartPlayer then
		WG["pregame-unit-selected"] = uDefID or -1
	end

	if WG.buildinggrid ~= nil and WG.buildinggrid.setForceShow ~= nil then
		WG.buildinggrid.setForceShow(FORCE_SHOW_REASON, uDefID ~= nil, uDefID)
	end

	if WG.easyfacing ~= nil and WG.easyfacing.setForceShow ~= nil then
		WG.easyfacing.setForceShow(FORCE_SHOW_REASON, uDefID ~= nil, uDefID)
	end

	local unitDef = getUnitDef(uDefID)
	local isMex = unitDef and unitDef.extractsMetal > 0

	if isMex then
		if spGetMapDrawMode() ~= "metal" then
			spSendCommands("ShowMetalMap")
		end
	elseif spGetMapDrawMode() == "metal" then
		spSendCommands("ShowStandard")
	end

	return true
end


local function clearPregameBuildQueue()
	if not preGamestartPlayer then
		return
	end

	setPreGamestartDefID()
	buildQueue = {}

	return true
end

local function buildmenuPregameDeselectHandler()
	if not (preGamestartPlayer and selBuildQueueDefID) then
		return
	end

	setPreGamestartDefID()

	return true
end

local function convertBuildQueueFaction(previousFactionSide, currentFactionSide)
	spLog("gui_pregame_build", LOG.DEBUG, string.format("Calling SubLogic.processBuildQueueSubstitution (in-place) from %s to %s for %d queue items.", previousFactionSide, currentFactionSide, #buildQueue))
	local result = SubLogic.processBuildQueueSubstitution(buildQueue, previousFactionSide, currentFactionSide)
	
	if result.substitutionFailed then
		spEcho(string.format("[gui_pregame_build] %s", result.summaryMessage))
	end
end

local function handleSelectedBuildingConversion(currentSelDefID, prevFactionSide, currentFactionSide, currentSelBuildData)
	if not currentSelDefID then 
		spLog("gui_pregame_build", LOG.WARNING, "handleSelectedBuildingConversion: Called with nil currentSelDefID.")
		return currentSelDefID 
	end

	local newSelDefID = SubLogic.getEquivalentUnitDefID(currentSelDefID, currentFactionSide)

	if newSelDefID ~= currentSelDefID then
		setPreGamestartDefID(newSelDefID)
		if currentSelBuildData then
			currentSelBuildData[1] = newSelDefID
		end
		local newUnitDef = getUnitDef(newSelDefID)
		local successMsg = "[Pregame Build] Selected item converted to " .. (newUnitDef and (newUnitDef.humanName or newUnitDef.name) or ("UnitDefID " .. tostring(newSelDefID)))
		spEcho(successMsg)
	else
		if prevFactionSide ~= currentFactionSide then
			local originalUnitDef = getUnitDef(currentSelDefID)
			local originalUnitName = originalUnitDef and (originalUnitDef.humanName or originalUnitDef.name) or ("UnitDefID " .. tostring(currentSelDefID))
			spLog("gui_pregame_build", LOG.INFO, string.format("Selected item '%s' remains unchanged for %s faction (or was already target faction).", originalUnitName, currentFactionSide))
		else
			spLog("gui_pregame_build", LOG.DEBUG, string.format("selBuildQueueDefID %s remained unchanged (sides were the same: %s).", tostring(currentSelDefID), currentFactionSide))
		end
	end
	return newSelDefID
end

local function buildSpacingHandler(cmd, line, words, playerID)
	if not preGamestartPlayer then
		return
	end
	
	local currentSpacing = spGetBuildSpacing() or 0
	local newSpacing = currentSpacing

	if words[1] == "inc" then
		newSpacing = math.min(16, currentSpacing + 1)
	elseif words[1] == "dec" then
		newSpacing = math.max(0, currentSpacing - 1)
	elseif words[1] == "set" and words[2] then
		newSpacing = math.max(0, math.min(16, tonumber(words[2]) or currentSpacing))
	end

	if newSpacing ~= currentSpacing then
		spSetBuildSpacing(newSpacing)

		-- Refresh current drag preview if active
		if dragActive and selBuildQueueDefID then
			local mx, my = spGetMouseState()
			local _, pos = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			if pos then
				local buildFacing = spGetBuildFacing()
				local alt, ctrl, meta, shift = spGetModKeyState()
				local useBoxPlacement = alt and ctrl and shift
				local useGridPlacement = alt and not useBoxPlacement
				dragPreviewPositions = computeDragPreviewPositions(selBuildQueueDefID, dragStartPosition, { pos[1], pos[2], pos[3] }, buildFacing, useGridPlacement, useBoxPlacement)
			end
		end
	end
	
	return true
end

------------------------------------------
---               INIT                 ---
------------------------------------------
function widget:Initialize()
	widgetHandler:AddAction("stop", clearPregameBuildQueue, nil, "p")
	widgetHandler:AddAction("buildfacing", buildFacingHandler, nil, "p")
	widgetHandler:AddAction("buildmenu_pregame_deselect", buildmenuPregameDeselectHandler, nil, "p")
	widgetHandler:AddAction("buildspacing", buildSpacingHandler, nil, "p")

	spLog(widget:GetInfo().name, LOG.INFO, "Pregame Queue Initializing. Local SubLogic is assumed available.")

	-- Get our starting unit
	if preGamestartPlayer then
		if not startDefID or startDefID ~= spGetTeamRulesParam(myTeamID, "startUnit") then
			startDefID = spGetTeamRulesParam(myTeamID, "startUnit")
		end
	end

	metalMap = WG.resource_spot_finder and WG.resource_spot_finder.isMetalMap

	WG["pregame-build"] = {}
	WG["pregame-build"].getPreGameDefID = function()
		return selBuildQueueDefID
	end
	WG["pregame-build"].setPreGamestartDefID = function(value)
		local inBuildOptions = {}
		-- Ensure startDefID is valid before trying to access unit def
		local startDef = startDefID and getUnitDef(startDefID)
		if startDef and startDef.buildOptions then
		    for _, opt in ipairs(startDef.buildOptions) do
			    inBuildOptions[opt] = true
		    end
		else
		    spLog(widget:GetInfo().name, LOG.WARNING, "setPreGamestartDefID: startDefID is nil or invalid, cannot determine build options.")
        end

		if inBuildOptions[value] then
			setPreGamestartDefID(value)
		else
			setPreGamestartDefID(nil)
		end
	end

	WG["pregame-build"].setBuildQueue = function(value)
		buildQueue = value
	end
	WG["pregame-build"].getBuildQueue = function()
		return buildQueue
	end
	WG["pregame-build"].getDragPreviewPositions = function()
		return dragPreviewPositions
	end
	WG["pregame-build"].isDragActive = function()
		return dragActive
	end
	widgetHandler:RegisterGlobal("GetPreGameDefID", WG["pregame-build"].getPreGameDefID)
	widgetHandler:RegisterGlobal("GetBuildQueue", WG["pregame-build"].getBuildQueue)
end


local function DoBuildingsClash(buildData1, buildData2)
	local w1, h1 = getBuildingDimensions(buildData1[1], buildData1[5])
	local w2, h2 = getBuildingDimensions(buildData2[1], buildData2[5])

	return math.abs(buildData1[2] - buildData2[2]) < w1 + w2 and math.abs(buildData1[4] - buildData2[4]) < h1 + h2
end

local function removeUnitShape(id)
	if unitshapes[id] then
		WG.StopDrawUnitShapeGL4(unitshapes[id])
		unitshapes[id] = nil
	end
end

local function addUnitShape(id, unitDefID, px, py, pz, rotationY, teamID, alpha)
	if unitshapes[id] then
		removeUnitShape(id)
	end
	unitshapes[id] = WG.DrawUnitShapeGL4(unitDefID, px, py, pz, rotationY, alpha or 1, teamID, nil, nil, nil)
	return unitshapes[id]
end

local function DrawBuilding(buildData, borderColor, drawRanges, alpha)
	local bDefID, bx, by, bz, facing = buildData[1], buildData[2], buildData[3], buildData[4], buildData[5]

	gl.DepthTest(false)
	gl.Color(borderColor)

	-- Use cached outline vertices and translate them to position
	local outlineVertices = getBuildingOutlineVertices(bDefID, facing)
	local translatedVertices = {}
	for i = 1, #outlineVertices do
		local v = outlineVertices[i].v
		translatedVertices[i] = { v = { bx + v[1], by + v[2], bz + v[3] } }
	end
	gl.Shape(GL.LINE_LOOP, translatedVertices)

	if drawRanges then
		local unitDef = getUnitDef(bDefID)
		local isMex = unitDef and unitDef.extractsMetal > 0
		if isMex then
			gl.Color(1.0, 0.0, 0.0, 0.5)
			-- Use cached circle vertices for metal extractor radius
			local circleVertices = getCircleVertices(Game.extractorRadius, 50)
			local translatedCircle = {}
			for i = 1, #circleVertices do
				local v = circleVertices[i].v
				translatedCircle[i] = { v = { bx + v[1], by + v[2], bz + v[3] } }
			end
			gl.Shape(GL.LINE_LOOP, translatedCircle)
		end

		local wRange = false --unitMaxWeaponRange[bDefID]
		if wRange then
			gl.Color(1.0, 0.3, 0.3, 0.7)
			local circleVertices = getCircleVertices(wRange, 40)
			local translatedCircle = {}
			for i = 1, #circleVertices do
				local v = circleVertices[i].v
				translatedCircle[i] = { v = { bx + v[1], by + v[2], bz + v[3] } }
			end
			gl.Shape(GL.LINE_LOOP, translatedCircle)
		end
	end
	if WG.StopDrawUnitShapeGL4 then
		local id = buildData[1]
			.. "_"
			.. buildData[2]
			.. "_"
			.. buildData[3]
			.. "_"
			.. buildData[4]
			.. "_"
			.. buildData[5]
		addUnitShape(id, buildData[1], buildData[2], buildData[3], buildData[4], buildData[5] * (math.pi / 2), myTeamID, alpha)
	end
end

-- Special handling for buildings before game start, since there isn't yet a unit spawned to give normal orders to
function widget:MousePress(mx, my, button)
	if spIsGUIHidden() then
		return false
	end

	if WG.topbar and WG.topbar.showingQuit() then
		return false
	end

	if not preGamestartPlayer then
		return false
	end

	local _, ctrl, meta, shift = spGetModKeyState()
	local queueShift = spGetInvertQueueKey() and (not shift) or shift

	if selBuildQueueDefID then
		if button == 1 and queueShift then
			local unitDef = getUnitDef(selBuildQueueDefID)
			local isMex = unitDef and unitDef.extractsMetal > 0
			
			if isMex and not metalMap then
				local _, pos = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
				if WG.ExtractorSnap then
					local snapPos = WG.ExtractorSnap.position
					if snapPos then
						pos = { snapPos.x, snapPos.y, snapPos.z }
					end
				end

				if not pos then
					return false
				end

				local buildFacing = spGetBuildFacing()
				local bx, by, bz = spPos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
				local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
				local cx, cy, cz = spGetTeamStartPosition(myTeamID)

				if cx ~= -100 then
					local cbx, cby, cbz = spPos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)
					if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then
						return true
					end
				end

				if spTestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
					local spot = WG.resource_spot_finder.GetClosestMexSpot(bx, bz)
					local spotIsTaken = spot and WG.resource_spot_builder.SpotHasExtractorQueued(spot, nil) or false
					if not spot or spotIsTaken then
						return true
					end

					local anyClashes = false
					for i = #buildQueue, 1, -1 do
						if buildQueue[i][1] > 0 and DoBuildingsClash(buildData, buildQueue[i]) then
							anyClashes = true
							table.remove(buildQueue, i)
						end
					end

					if not anyClashes then
						buildQueue[#buildQueue + 1] = buildData
						handleBuildMenu(queueShift)
					end
				end
				return true
			end
			
			local _, worldPosition = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			if not worldPosition then
				return false
			end
			potentialDragStart = true
			dragStartMousePos = { mx, my }
			dragStartPosition = { worldPosition[1], worldPosition[2], worldPosition[3] }
			dragPreviewPositions = {}
			return true
		end
		
		if button == 1 then
			local _, pos = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			local unitDef = getUnitDef(selBuildQueueDefID)
			local isMex = unitDef and unitDef.extractsMetal > 0
			if WG.ExtractorSnap then
				local snapPos = WG.ExtractorSnap.position
				if snapPos then
					pos = { snapPos.x, snapPos.y, snapPos.z }
				end
			end

			if not pos then
				return false
			end

			local buildFacing = spGetBuildFacing()
			local bx, by, bz = spPos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
			local cx, cy, cz = spGetTeamStartPosition(myTeamID) -- Returns -100, -100, -100 when none chosen

			if (meta or not queueShift) and cx ~= -100 then
				local cbx, cby, cbz = spPos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)

				if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then -- avoid clashing building and commander position
					return true
				end
			end

			if spTestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
                if meta then
                    table.insert(buildQueue, 1, buildData)
                elseif queueShift then
					local anyClashes = false
					for i = #buildQueue, 1, -1 do
						if buildQueue[i][1] > 0 then
							if DoBuildingsClash(buildData, buildQueue[i]) then
								anyClashes = true
								table.remove(buildQueue, i)
							end
						end
					end

					if isMex and not metalMap then
						local spot = WG["resource_spot_finder"].GetClosestMexSpot(bx, bz)
						local spotIsTaken = spot and WG["resource_spot_builder"].SpotHasExtractorQueued(spot, nil) or false
						if not spot or spotIsTaken then
							return true
						end
					end

					if not anyClashes then
						buildQueue[#buildQueue + 1] = buildData
						handleBuildMenu(queueShift)
					end
				else
					if isMex then
						if WG.ExtractorSnap.position or metalMap then
							buildQueue = { buildData }
						end
					else
						buildQueue = { buildData }
						handleBuildMenu(queueShift)
					end
				end

				if not queueShift then
					setPreGamestartDefID(nil)
					handleBuildMenu(queueShift)
				end
			end

			return true
		elseif button == 3 then
			setPreGamestartDefID(nil)
			return true
		end
	elseif button == 1 and #buildQueue > 0 and buildQueue[1][1]>0 then
		local _, pos = spTraceScreenRay(mx, my, true, false, false, isUnderwater(startDefID))
		if not pos then
			return false
		end
		local cbx, cby, cbz = spPos2BuildPos(tonumber(startDefID) or 0, pos[1], pos[2], pos[3])

		if DoBuildingsClash({ startDefID, cbx, cby, cbz, 1 }, buildQueue[1]) then
			return true
		end
	elseif button == 3 and queueShift then
		local x, y, _ = spGetMouseState()
		local _, pos = spTraceScreenRay(x, y, true, false, false, true)
		if pos and pos[1] then
			local buildData = { -CMD.MOVE, pos[1], pos[2], pos[3], nil }
			buildQueue[#buildQueue + 1] = buildData
		end
		return true
	elseif button == 3 and #buildQueue > 0 then
		table.remove(buildQueue, #buildQueue)
		return true
	end
	
	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not selBuildQueueDefID then
		return false
	end
	
	local unitDef = getUnitDef(selBuildQueueDefID)
	local isMex = unitDef and unitDef.extractsMetal > 0
	if isMex and not metalMap then
		if potentialDragStart then
			clearDrag()
		end
		return false
	end
	
	if potentialDragStart and not dragActive then
		local mouseDeltaX = mx - dragStartMousePos[1]
		local mouseDeltaY = my - dragStartMousePos[2]
		local mouseDistance = math.sqrt(mouseDeltaX * mouseDeltaX + mouseDeltaY * mouseDeltaY)
		
		if mouseDistance > DRAG_THRESHOLD then
			dragActive = true
			potentialDragStart = false
		else
			return false
		end
	end
	
	if not dragActive then
		return false
	end
	
	local altPressed, ctrlPressed, metaPressed, shiftPressed = spGetModKeyState()
	local _, worldPosition = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
	if not worldPosition then
		return false
	end
	local buildFacing = spGetBuildFacing()
	local useBoxPlacement = altPressed and ctrlPressed and shiftPressed
	local useGridPlacement = altPressed and not useBoxPlacement
	dragPreviewPositions = computeDragPreviewPositions(selBuildQueueDefID, dragStartPosition, { worldPosition[1], worldPosition[2], worldPosition[3] }, buildFacing, useGridPlacement, useBoxPlacement)
	return true
end

function widget:MouseRelease(mx, my, button)
	if button == 1 and selBuildQueueDefID then
		if dragActive then
			local unitDef = getUnitDef(selBuildQueueDefID)
	local isMex = unitDef and unitDef.extractsMetal > 0
			for i = 1, #dragPreviewPositions do
				local positionData = dragPreviewPositions[i]
				local removedAny = false
				for j = #buildQueue, 1, -1 do
					local queued = buildQueue[j]
					if queued[1] > 0 and DoBuildingsClash(positionData, queued) then
						table.remove(buildQueue, j)
						removedAny = true
					end
				end
				if not removedAny then
					if spTestBuildOrder(positionData[1], positionData[2], positionData[3], positionData[4], positionData[5]) ~= 0 then
						if isMex then
							if WG.ExtractorSnap.position or metalMap then
								buildQueue[#buildQueue + 1] = { positionData[1], positionData[2], positionData[3], positionData[4], positionData[5] }
							end
						else
							buildQueue[#buildQueue + 1] = { positionData[1], positionData[2], positionData[3], positionData[4], positionData[5] }
						end
					end
				end
			end
			handleBuildMenu(true)
			clearDrag()
			return true
		elseif potentialDragStart then
			local _, pos = spTraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			local unitDef = getUnitDef(selBuildQueueDefID)
	local isMex = unitDef and unitDef.extractsMetal > 0
			
			if isMex and not metalMap then
				clearDrag()
				return false
			end
			
			if isMex and not metalMap and WG.ExtractorSnap then
				local snapPos = WG.ExtractorSnap.position
				if snapPos then
					pos = { snapPos.x, snapPos.y, snapPos.z }
				end
			end

			if not pos then
				clearDrag()
				return false
			end

			local buildFacing = spGetBuildFacing()
			local bx, by, bz = spPos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
			local cx, cy, cz = spGetTeamStartPosition(myTeamID)

			if cx ~= -100 then
				local cbx, cby, cbz = spPos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)
				if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then
					clearDrag()
					return true
				end
			end

			if spTestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
				if isMex and not metalMap then
					local spot = WG["resource_spot_finder"].GetClosestMexSpot(bx, bz)
					local spotIsTaken = spot and WG["resource_spot_builder"].SpotHasExtractorQueued(spot, nil) or false
					if not spot or spotIsTaken then
						clearDrag()
						return true
					end
				end

				local anyClashes = false
				for i = #buildQueue, 1, -1 do
					if buildQueue[i][1] > 0 and DoBuildingsClash(buildData, buildQueue[i]) then
						anyClashes = true
						table.remove(buildQueue, i)
					end
				end

				if not anyClashes then
					buildQueue[#buildQueue + 1] = buildData
					handleBuildMenu(true)
				end
			end
			clearDrag()
			return true
		end
	end
	clearDrag()
	return false
end

function widget:DrawWorld()
	if not WG.StopDrawUnitShapeGL4 then
		return
	end

	-- remove unit shape queue to re-add again later
	for id, _ in pairs(unitshapes) do
		removeUnitShape(id)
	end

	-- Avoid unnecessary overhead after buildqueue has been setup in early frames
	if spGetGameFrame() > 0 then
		widgetHandler:RemoveCallIn("DrawWorld")
		return
	end

	if not preGamestartPlayer then
		return
	end

	-- draw pregame build queue
	local ALPHA_SPAWNED = 1.0
	local ALPHA_DEFAULT = 0.5

	local BORDER_COLOR_SPAWNED = { 1.0, 0.0, 1.0, 0.7 }
	local BORDER_COLOR_NORMAL = { 0.3, 1.0, 0.3, 0.5 }
	local BORDER_COLOR_CLASH = { 0.7, 0.3, 0.3, 1.0 }
	local BORDER_COLOR_INVALID = { 1.0, 0.0, 0.0, 1.0 }
	local BORDER_COLOR_VALID = { 0.0, 1.0, 0.0, 1.0 }
	local BUILD_DISTANCE_COLOR = { 0.3, 1.0, 0.3, 0.6 }
	local BUILD_LINES_COLOR = { 0.3, 1.0, 0.3, 0.6 }

	gl.LineWidth(1.49)

	-- We need data about currently selected building, for drawing clashes etc
	local selBuildData
	if selBuildQueueDefID then
		local x, y, _ = spGetMouseState()
		local _, pos = spTraceScreenRay(x, y, true, false, false, isUnderwater(selBuildQueueDefID))
		if pos then
			local buildFacing = spGetBuildFacing()
			local bx, by, bz = spPos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			selBuildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
		end
	end

	-- Update startDefID if it changed
	local currentStartDefID = spGetTeamRulesParam(myTeamID, "startUnit")
	if startDefID ~= currentStartDefID then
		startDefID = currentStartDefID
	end

	local sx, sy, sz = spGetTeamStartPosition(myTeamID)
	local startChosen = (sx ~= 0) or (sy ~= 0) or (sz ~= 0)
	local buildDistance = startChosen and startDefID and
		(spGetGameRulesParam("overridePregameBuildDistance") or getUnitDef(startDefID).buildDistance)

	if startChosen and startDefID and buildDistance then
		-- Correction for start positions in the air
		sy = spGetGroundHeight(sx, sz)

		-- Draw start units build radius using cached circle geometry
		gl.Color(BUILD_DISTANCE_COLOR)
		local circleVertices = getCircleVertices(buildDistance, 40)
		local translatedCircle = {}
		for i = 1, #circleVertices do
			local v = circleVertices[i].v
			translatedCircle[i] = { v = { sx + v[1], sy + v[2], sz + v[3] } }
		end
		gl.Shape(GL.LINE_LOOP, translatedCircle)
	end

	-- Check for faction change
	if prevStartDefID ~= startDefID then
        local prevDef = getUnitDef(prevStartDefID)
        local currentDef = getUnitDef(startDefID)
        local prevDefName = prevDef and prevDef.name
        local currentDefName = currentDef and currentDef.name

        local previousFactionSide = prevDefName and SubLogic.getSideFromUnitName(prevDefName)
        local currentFactionSide = currentDefName and SubLogic.getSideFromUnitName(currentDefName)

        if previousFactionSide and currentFactionSide and previousFactionSide ~= currentFactionSide then
            convertBuildQueueFaction(previousFactionSide, currentFactionSide) 
            if selBuildQueueDefID then
                selBuildQueueDefID = handleSelectedBuildingConversion(selBuildQueueDefID, previousFactionSide, currentFactionSide, selBuildData)
            end
        elseif previousFactionSide and currentFactionSide and previousFactionSide == currentFactionSide then
            spLog(widget:GetInfo().name, LOG.DEBUG, string.format(
                "Sides determined but are the same (%s), no conversion needed.", currentFactionSide))
        else
            spLog(widget:GetInfo().name, LOG.WARNING, string.format(
                "Could not determine sides for conversion: prevDefID=%s (name: %s), currentDefID=%s (name: %s). Names might be unhandled by SubLogic.getSideFromUnitName, or SubLogic itself might be incomplete from a non-critical load error.", 
                tostring(prevStartDefID), tostring(prevDefName), tostring(startDefID), tostring(currentDefName)))
        end
        prevStartDefID = startDefID
	end

	local getBuildQueueSpawnStatus = WG.getBuildQueueSpawnStatus

	local alphaResults = { queueAlphas = {}, selectedAlpha = ALPHA_DEFAULT }
	local spawnedQueueKeySet = {}

	if getBuildQueueSpawnStatus then
		local spawnStatus = getBuildQueueSpawnStatus(buildQueue, selBuildData)

		for i = 1, #buildQueue do
			local isSpawned = spawnStatus.queueSpawned[i] or false
			alphaResults.queueAlphas[i] = isSpawned and ALPHA_SPAWNED or ALPHA_DEFAULT
			if isSpawned then
				local bdi = buildQueue[i]
				local kq = buildPositionKey(bdi[2], bdi[3], bdi[4], bdi[5])
				spawnedQueueKeySet[kq] = true
			end
		end

		alphaResults.selectedAlpha = spawnStatus.selectedSpawned and ALPHA_SPAWNED or ALPHA_DEFAULT
	else
		for i = 1, #buildQueue do
			alphaResults.queueAlphas[i] = ALPHA_DEFAULT
		end
	end

	local queueLineVerts = startChosen and { { v = { sx, sy, sz } } } or {}
	for b = 1, #buildQueue do
		local buildData = buildQueue[b]

		if buildData[1] > 0 then
			local alpha = alphaResults.queueAlphas[b] or 0.5
			local isSpawned = alpha >= ALPHA_SPAWNED
			local borderColor = isSpawned and BORDER_COLOR_SPAWNED or BORDER_COLOR_NORMAL

			if selBuildData and DoBuildingsClash(selBuildData, buildData) then
				DrawBuilding(buildData, BORDER_COLOR_CLASH, false, alpha)
			else
				DrawBuilding(buildData, borderColor, false, alpha)
			end
			
			if alpha < ALPHA_SPAWNED then
				queueLineVerts[#queueLineVerts + 1] = { v = { buildData[2], buildData[3], buildData[4] } }
			end
		else
			queueLineVerts[#queueLineVerts + 1] = { v = { buildData[2], buildData[3], buildData[4] } }
		end
	end

	-- Draw queue lines
	gl.Color(BUILD_LINES_COLOR)
	gl.LineStipple("springdefault")
	gl.Shape(GL.LINE_STRIP, queueLineVerts)
	gl.LineStipple(false)

	-- Draw selected building
	if selBuildData and not dragActive then
		local selectedAlpha = alphaResults.selectedAlpha or ALPHA_DEFAULT
		local isSelectedSpawned = selectedAlpha >= ALPHA_SPAWNED
		
		local unitDef = getUnitDef(selBuildQueueDefID)
	local isMex = unitDef and unitDef.extractsMetal > 0
		local testOrder = spTestBuildOrder(
			selBuildQueueDefID,
			selBuildData[2],
			selBuildData[3],
			selBuildData[4],
			selBuildData[5]
		) ~= 0
		if not isMex then
			local color = testOrder and (isSelectedSpawned and BORDER_COLOR_SPAWNED or BORDER_COLOR_VALID) or BORDER_COLOR_INVALID
			DrawBuilding(selBuildData, color, true, selectedAlpha)
		elseif isMex then
			if WG.ExtractorSnap.position or metalMap then
				local color = isSelectedSpawned and BORDER_COLOR_SPAWNED or BORDER_COLOR_VALID
				DrawBuilding(selBuildData, color, true, selectedAlpha)
			else
				DrawBuilding(selBuildData, BORDER_COLOR_INVALID, true, selectedAlpha)
			end
		else
			local color = isSelectedSpawned and BORDER_COLOR_SPAWNED or BORDER_COLOR_VALID
			DrawBuilding(selBuildData, color, true, selectedAlpha)
		end
	end

	if dragActive and selBuildQueueDefID and #dragPreviewPositions > 0 then
		local hideKey = nil
		if selBuildData then
			hideKey = buildPositionKey(selBuildData[2], selBuildData[3], selBuildData[4], selBuildData[5])
		end
		
		local dragSpawnedKeySet = {}
		local getBuildQueueSpawnStatus = WG["getBuildQueueSpawnStatus"]
		if getBuildQueueSpawnStatus then
			local spawnStatus = getBuildQueueSpawnStatus(buildQueue, nil, dragPreviewPositions)
			if spawnStatus and spawnStatus.dragSpawned then
				for i = 1, #dragPreviewPositions do
					if spawnStatus.dragSpawned[i] then
						local positionData = dragPreviewPositions[i]
						local posKey = buildPositionKey(positionData[2], positionData[3], positionData[4], positionData[5])
						dragSpawnedKeySet[posKey] = true
					end
				end
			end
		else
		end
		
		for i = 1, #dragPreviewPositions do
			local positionData = dragPreviewPositions[i]
			local posKey = buildPositionKey(positionData[2], positionData[3], positionData[4], positionData[5])
			if posKey ~= hideKey then
				local canBuild = spTestBuildOrder(positionData[1], positionData[2], positionData[3], positionData[4], positionData[5]) ~= 0
				local isSpawned = dragSpawnedKeySet[posKey] == true
				local color
				if canBuild then
					color = isSpawned and BORDER_COLOR_SPAWNED or BORDER_COLOR_VALID
				else
					color = BORDER_COLOR_INVALID
				end
				
				
				DrawBuilding(positionData, color, false, isSpawned and ALPHA_SPAWNED or DRAG_PREVIEW_ALPHA)
			end
		end
	end

	-- Reset gl
	gl.Color(1, 1, 1, 1)
	gl.LineWidth(1.0)
end

function widget:GameFrame(n)
	-- Avoid unnecessary overhead after buildqueue has been setup in early frames
	if #buildQueue == 0 then
		widgetHandler:RemoveCallIn("GameFrame")
		widgetHandler:RemoveWidget()
		return
	end

	-- handle the pregame build queue
	if not (n <= 60 and n > 1) then
		return
	end

	-- inform gadget how long is our queue
	local t = 0
	local startDef = startDefID and getUnitDef(startDefID)
	local startBuildSpeed = startDef and startDef.buildSpeed or 1

	for i = 1, #buildQueue do
		local buildItem = buildQueue[i]
		if buildItem[1] > 0 then
			local unitDef = getUnitDef(buildItem[1])
			if unitDef then
				t = t + unitDef.buildTime
			end
		end
	end

	if startDefID and startBuildSpeed > 0 then
		local buildTime = t / startBuildSpeed
		spSendCommands("luarules initialQueueTime " .. buildTime)
	end

	local tasker
	-- Search for our starting unit
	local units = spGetTeamUnits(myTeamID)
	for u = 1, #units do
		local uID = units[u]
		if getUnitCanCompleteQueue(uID) then
			tasker = uID
			if spGetUnitRulesParam(uID, "startingOwner") == spGetMyPlayerID() then
				-- we found our com even if cooping, assigning queue to this particular unit
				break
			end
		end
	end
	if tasker then
		for b = 1, #buildQueue do
			local buildData = buildQueue[b]
			spGiveOrderToUnit(
				tasker,
				-buildData[1],
				{ buildData[2], buildData[3], buildData[4], buildData[5] },
				{ "shift" }
			)
		end
		buildQueue = {}
	end
end

function widget:GameStart()
	preGamestartPlayer = false

	-- Ensure startDefID is current for GameStart logic, though DrawWorld might have already updated prevStartDefID
	local currentStartDefID_GS = spGetTeamRulesParam(myTeamID, "startUnit")
	if startDefID ~= currentStartDefID_GS then
	    spLog("gui_pregame_build", LOG.DEBUG, string.format("GameStart: startDefID (%s) differs from current rules param (%s). Updating.", tostring(startDefID), tostring(currentStartDefID_GS)))
	    startDefID = currentStartDefID_GS
	end

	if prevStartDefID ~= startDefID then
		local prevDef = getUnitDef(prevStartDefID)
		local currentDef = getUnitDef(startDefID)
		local prevDefName = prevDef and prevDef.name
		local currentDefName = currentDef and currentDef.name

		local previousFactionSide = prevDefName and SubLogic.getSideFromUnitName(prevDefName)
		local currentFactionSide = currentDefName and SubLogic.getSideFromUnitName(currentDefName)

		if previousFactionSide and currentFactionSide and previousFactionSide ~= currentFactionSide then
			convertBuildQueueFaction(previousFactionSide, currentFactionSide)
		elseif previousFactionSide and currentFactionSide and previousFactionSide == currentFactionSide then
			-- Sides are the same, no conversion needed.
		else
			spLog("gui_pregame_build", LOG.WARNING, string.format("Could not determine sides for conversion in GameStart: prevDefID=%s, currentDefID=%s", tostring(prevStartDefID), tostring(startDefID)))
		end
		prevStartDefID = startDefID
	end

	-- Deattach pregame action handlers
	widgetHandler:RemoveAction("stop")
	widgetHandler:RemoveAction("buildfacing")
	widgetHandler:RemoveAction("buildmenu_pregame_deselect")
end

function widget:Shutdown()
	-- Stop drawing all ghosts
	if WG.StopDrawUnitShapeGL4 then
		for id, _ in pairs(unitshapes) do
			removeUnitShape(id)
		end
	end
	widgetHandler:DeregisterGlobal("GetPreGameDefID")
	widgetHandler:DeregisterGlobal("GetBuildQueue")

	WG["pregame-build"] = nil
	if WG["buildinggrid"] ~= nil and WG["buildinggrid"].setForceShow ~= nil then
		WG["buildinggrid"].setForceShow(FORCE_SHOW_REASON, false)
	end

	if WG["easyfacing"] ~= nil and WG["easyfacing"].setForceShow ~= nil then
		WG["easyfacing"].setForceShow(FORCE_SHOW_REASON, false)
	end
end

function widget:GetConfigData()
	return {
		buildQueue = buildQueue,
		gameID = Game.gameID and Game.gameID or spGetGameRulesParam("GameID"),
		buildSpacing = spGetBuildSpacing() or 0,
	}
end

function widget:SetConfigData(data)
	if
		data.buildQueue
		and spGetGameFrame() == 0
		and data.gameID
		and data.gameID == (Game.gameID and Game.gameID or spGetGameRulesParam("GameID"))
	then
		buildQueue = data.buildQueue
	end

	if data.buildSpacing and spGetGameFrame() == 0 then
		spSetBuildSpacing(data.buildSpacing)
	end
end
