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

local buildQueue = {}
local selBuildQueueDefID
local facingMap = { south = 0, east = 1, north = 2, west = 3 }

local isSpec = Spring.GetSpectatingState()
local myTeamID = Spring.GetMyTeamID()
local preGamestartPlayer = Spring.GetGameFrame() == 0 and not isSpec
local startDefID = Spring.GetTeamRulesParam(myTeamID, "startUnit")
local prevStartDefID = startDefID
local metalMap = false

local unitshapes = {}

local dragActive = false
local dragStartPosition = nil
local dragPreviewPositions = {}
local DRAG_PREVIEW_ALPHA = 0.5
local potentialDragStart = false
local dragStartMousePos = nil
local DRAG_THRESHOLD = Spring.GetConfigInt("MouseDragSelectionThreshold", 4)

local function clearDrag()
	dragActive = false
	dragStartPosition = nil
	dragPreviewPositions = {}
	potentialDragStart = false
	dragStartMousePos = nil
end

local function snapBuildPosition(unitDefID, worldX, worldY, worldZ, buildFacing)
	local snappedX, snappedY, snappedZ = Spring.Pos2BuildPos(unitDefID, worldX, worldY, worldZ, buildFacing)
	return snappedX, snappedY, snappedZ
end

local function getBuildingCenterStep(unitDefID, buildFacing)
	local def = UnitDefs[unitDefID]
	local footprintWidth
	local footprintHeight
	if buildFacing % 2 == 1 then
		footprintWidth = 4 * def.zsize
		footprintHeight = 4 * def.xsize
	else
		footprintWidth = 4 * def.xsize
		footprintHeight = 4 * def.zsize
	end
	return footprintWidth * 2, footprintHeight * 2
end

local function buildPositionKey(snappedX, snappedY, snappedZ, buildFacing)
	return tostring(snappedX)..":"..tostring(snappedY)..":"..tostring(snappedZ)..":"..tostring(buildFacing)
end

local function computeDragPreviewPositions(unitDefID, startPosition, endPosition, buildFacing, useGridPlacement)
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

	local facing = Spring.GetBuildFacing()
	if args and args[1] == "inc" then
		facing = (facing + 1) % 4
		Spring.SetBuildFacing(facing)
		return true
	elseif args and args[1] == "dec" then
		facing = (facing - 1) % 4
		Spring.SetBuildFacing(facing)
		return true
	elseif args and facingMap[args[1]] then
		Spring.SetBuildFacing(facingMap[args[1]])
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

	if WG["buildinggrid"] ~= nil and WG["buildinggrid"].setForceShow ~= nil then
		WG["buildinggrid"].setForceShow(FORCE_SHOW_REASON, uDefID ~= nil, uDefID)
	end

	if WG["easyfacing"] ~= nil and WG["easyfacing"].setForceShow ~= nil then
		WG["easyfacing"].setForceShow(FORCE_SHOW_REASON, uDefID ~= nil, uDefID)
	end

	local isMex = UnitDefs[uDefID] and UnitDefs[uDefID].extractsMetal > 0

	if isMex then
		if Spring.GetMapDrawMode() ~= "metal" then
			Spring.SendCommands("ShowMetalMap")
		end
	elseif Spring.GetMapDrawMode() == "metal" then
		Spring.SendCommands("ShowStandard")
	end

	return true
end

local function GetUnitCanCompleteQueue(uID)
	local uDefID = Spring.GetUnitDefID(uID)
	if uDefID == startDefID then
		return true
	end

	-- What can this unit build ?
	local uCanBuild = {}
	local uBuilds = UnitDefs[uDefID].buildOptions
	for i = 1, #uBuilds do
		uCanBuild[uBuilds[i]] = true
	end

	-- Can it build everything that was queued ?
	for i = 1, #buildQueue do
		if not uCanBuild[buildQueue[i][1]] then
			return false
		end
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
	Spring.Log("gui_pregame_build", LOG.DEBUG, string.format("Calling SubLogic.processBuildQueueSubstitution (in-place) from %s to %s for %d queue items.", previousFactionSide, currentFactionSide, #buildQueue))
	local result = SubLogic.processBuildQueueSubstitution(buildQueue, previousFactionSide, currentFactionSide)
	
	if result.substitutionFailed then
		Spring.Echo(string.format("[gui_pregame_build] %s", result.summaryMessage))
	end
end

local function handleSelectedBuildingConversion(currentSelDefID, prevFactionSide, currentFactionSide, currentSelBuildData)
	if not currentSelDefID then 
		Spring.Log("gui_pregame_build", LOG.WARNING, "handleSelectedBuildingConversion: Called with nil currentSelDefID.")
		return currentSelDefID 
	end

	local newSelDefID = SubLogic.getEquivalentUnitDefID(currentSelDefID, currentFactionSide)

	if newSelDefID ~= currentSelDefID then
		setPreGamestartDefID(newSelDefID)
		if currentSelBuildData then
			currentSelBuildData[1] = newSelDefID
		end
		local newUnitDef = UnitDefs[newSelDefID]
		local successMsg = "[Pregame Build] Selected item converted to " .. (newUnitDef and (newUnitDef.humanName or newUnitDef.name) or ("UnitDefID " .. tostring(newSelDefID)))
		Spring.Echo(successMsg)
	else
		if prevFactionSide ~= currentFactionSide then
			local originalUnitDef = UnitDefs[currentSelDefID]
			local originalUnitName = originalUnitDef and (originalUnitDef.humanName or originalUnitDef.name) or ("UnitDefID " .. tostring(currentSelDefID))
			Spring.Log("gui_pregame_build", LOG.INFO, string.format("Selected item '%s' remains unchanged for %s faction (or was already target faction).", originalUnitName, currentFactionSide))
		else
			Spring.Log("gui_pregame_build", LOG.DEBUG, string.format("selBuildQueueDefID %s remained unchanged (sides were the same: %s).", tostring(currentSelDefID), currentFactionSide))
		end
	end
	return newSelDefID
end

------------------------------------------
---               INIT                 ---
------------------------------------------
function widget:Initialize()
	widgetHandler:AddAction("stop", clearPregameBuildQueue, nil, "p")
	widgetHandler:AddAction("buildfacing", buildFacingHandler, nil, "p")
	widgetHandler:AddAction("buildmenu_pregame_deselect", buildmenuPregameDeselectHandler, nil, "p")

	Spring.Log(widget:GetInfo().name, LOG.INFO, "Pregame Queue Initializing. Local SubLogic is assumed available.")

	-- Get our starting unit
	if preGamestartPlayer then
		if not startDefID or startDefID ~= Spring.GetTeamRulesParam(myTeamID, "startUnit") then
			startDefID = Spring.GetTeamRulesParam(myTeamID, "startUnit")
		end
	end

	metalMap = WG["resource_spot_finder"].isMetalMap

	WG["pregame-build"] = {}
	WG["pregame-build"].getPreGameDefID = function()
		return selBuildQueueDefID
	end
	WG["pregame-build"].setPreGamestartDefID = function(value)
		local inBuildOptions = {}
		-- Ensure startDefID is valid before trying to access UnitDefs[startDefID]
		if startDefID and UnitDefs[startDefID] and UnitDefs[startDefID].buildOptions then
		    for _, opt in ipairs(UnitDefs[startDefID].buildOptions) do
			    inBuildOptions[opt] = true
		    end
		else
		    Spring.Log(widget:GetInfo().name, LOG.WARNING, "setPreGamestartDefID: startDefID is nil or invalid, cannot determine build options.")
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

local function GetBuildingDimensions(uDefID, facing)
	local bDef = UnitDefs[uDefID]
	if facing % 2 == 1 then
		return 4 * bDef.zsize, 4 * bDef.xsize
	else
		return 4 * bDef.xsize, 4 * bDef.zsize
	end
end

local function DoBuildingsClash(buildData1, buildData2)
	local w1, h1 = GetBuildingDimensions(buildData1[1], buildData1[5])
	local w2, h2 = GetBuildingDimensions(buildData2[1], buildData2[5])

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
	local bw, bh = GetBuildingDimensions(bDefID, facing)

	gl.DepthTest(false)
	gl.Color(borderColor)

	gl.Shape(GL.LINE_LOOP, {
		{ v = { bx - bw, by, bz - bh } },
		{ v = { bx + bw, by, bz - bh } },
		{ v = { bx + bw, by, bz + bh } },
		{ v = { bx - bw, by, bz + bh } },
	})

	if drawRanges then
		local isMex = UnitDefs[bDefID] and UnitDefs[bDefID].extractsMetal > 0
		if isMex then
			gl.Color(1.0, 0.0, 0.0, 0.5)
			gl.DrawGroundCircle(bx, by, bz, Game.extractorRadius, 50)
		end

		local wRange = false --unitMaxWeaponRange[bDefID]
		if wRange then
			gl.Color(1.0, 0.3, 0.3, 0.7)
			gl.DrawGroundCircle(bx, by, bz, wRange, 40)
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

local function isUnderwater(unitDefID)
	return UnitDefs[unitDefID].modCategories.underwater
end

-- Special handling for buildings before game start, since there isn't yet a unit spawned to give normal orders to
function widget:MousePress(mx, my, button)
	if Spring.IsGUIHidden() then
		return false
	end

	if WG["topbar"] and WG["topbar"].showingQuit() then
		return false
	end

	if not preGamestartPlayer then
		return false
	end
	
	local _, ctrl, meta, shift = Spring.GetModKeyState()
	local queueShift = Spring.GetInvertQueueKey() and (not shift) or shift

	if selBuildQueueDefID then
		if button == 1 and queueShift then
			local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
			
			if isMex and not metalMap then
				local _, pos = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
				if WG.ExtractorSnap then
					local snapPos = WG.ExtractorSnap.position
					if snapPos then
						pos = { snapPos.x, snapPos.y, snapPos.z }
					end
				end

				if not pos then
					return false
				end

				local buildFacing = Spring.GetBuildFacing()
				local bx, by, bz = Spring.Pos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
				local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
				local cx, cy, cz = Spring.GetTeamStartPosition(myTeamID)

				if cx ~= -100 then
					local cbx, cby, cbz = Spring.Pos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)
					if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then
						return true
					end
				end

				if Spring.TestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
					local spot = WG["resource_spot_finder"].GetClosestMexSpot(bx, bz)
					local spotIsTaken = spot and WG["resource_spot_builder"].SpotHasExtractorQueued(spot, nil) or false
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
			
			local _, worldPosition = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
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
			local _, pos = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
			if WG.ExtractorSnap then
				local snapPos = WG.ExtractorSnap.position
				if snapPos then
					pos = { snapPos.x, snapPos.y, snapPos.z }
				end
			end

			if not pos then
				return false
			end

			local buildFacing = Spring.GetBuildFacing()
			local bx, by, bz = Spring.Pos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
			local cx, cy, cz = Spring.GetTeamStartPosition(myTeamID) -- Returns -100, -100, -100 when none chosen

			if (meta or not queueShift) and cx ~= -100 then
				local cbx, cby, cbz = Spring.Pos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)

				if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then -- avoid clashing building and commander position
					return true
				end
			end

			if Spring.TestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
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
		local _, pos = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(startDefID))
		if not pos then
			return false
		end
		local cbx, cby, cbz = Spring.Pos2BuildPos(tonumber(startDefID) or 0, pos[1], pos[2], pos[3])

		if DoBuildingsClash({ startDefID, cbx, cby, cbz, 1 }, buildQueue[1]) then
			return true
		end
	elseif button == 3 and queueShift then
		local x, y, _ = Spring.GetMouseState()
		local _, pos = Spring.TraceScreenRay(x, y, true, false, false, true)
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
	
	local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
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
	
	local altPressed = select(1, Spring.GetModKeyState())
	local _, worldPosition = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
	if not worldPosition then
		return false
	end
	local buildFacing = Spring.GetBuildFacing()
	local useGridPlacement = altPressed and true or false
	dragPreviewPositions = computeDragPreviewPositions(selBuildQueueDefID, dragStartPosition, { worldPosition[1], worldPosition[2], worldPosition[3] }, buildFacing, useGridPlacement)
	return true
end

function widget:MouseRelease(mx, my, button)
	if button == 1 and selBuildQueueDefID then
		if dragActive then
			local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
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
					if Spring.TestBuildOrder(positionData[1], positionData[2], positionData[3], positionData[4], positionData[5]) ~= 0 then
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
			local _, pos = Spring.TraceScreenRay(mx, my, true, false, false, isUnderwater(selBuildQueueDefID))
			local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
			
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

			local buildFacing = Spring.GetBuildFacing()
			local bx, by, bz = Spring.Pos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			local buildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
			local cx, cy, cz = Spring.GetTeamStartPosition(myTeamID)

			if cx ~= -100 then
				local cbx, cby, cbz = Spring.Pos2BuildPos(tonumber(startDefID) or 0, cx or 0, cy or 0, cz or 0)
				if DoBuildingsClash(buildData, { startDefID, cbx, cby, cbz, 1 }) then
					clearDrag()
					return true
				end
			end

			if Spring.TestBuildOrder(selBuildQueueDefID, bx, by, bz, buildFacing) ~= 0 then
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
	if Spring.GetGameFrame() > 0 then
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
		local x, y, _ = Spring.GetMouseState()
		local _, pos = Spring.TraceScreenRay(x, y, true, false, false, isUnderwater(selBuildQueueDefID))
		if pos then
			local buildFacing = Spring.GetBuildFacing()
			local bx, by, bz = Spring.Pos2BuildPos(selBuildQueueDefID, pos[1], pos[2], pos[3], buildFacing)
			selBuildData = { selBuildQueueDefID, bx, by, bz, buildFacing }
		end
	end

	if startDefID ~= Spring.GetTeamRulesParam(myTeamID, "startUnit") then
		startDefID = Spring.GetTeamRulesParam(myTeamID, "startUnit")
	end


	local sx, sy, sz = Spring.GetTeamStartPosition(myTeamID) -- Returns 0, 0, 0 when none chosen (was -100, -100, -100 previously)
	--should startposition not match 0,0,0 and no commander is placed, then there is a green circle on the map till one is placed
	--TODO: be based on the map, if position is changed from default(?)
	local startChosen = (sx ~= 0) or (sy ~=0) or (sz~=0)
	if startChosen and startDefID then
		-- Correction for start positions in the air
		sy = Spring.GetGroundHeight(sx, sz)

		-- Draw start units build radius
		gl.Color(BUILD_DISTANCE_COLOR)
		local buildDistance = Spring.GetGameRulesParam("overridePregameBuildDistance") or UnitDefs[startDefID].buildDistance
		if buildDistance then
			gl.DrawGroundCircle(sx, sy, sz, buildDistance, 40)
		end
	end

	-- Check for faction change
	if prevStartDefID ~= startDefID then
        local prevDefName = prevStartDefID and UnitDefs[prevStartDefID] and UnitDefs[prevStartDefID].name
        local currentDefName = startDefID and UnitDefs[startDefID] and UnitDefs[startDefID].name

        local previousFactionSide = prevDefName and SubLogic.getSideFromUnitName(prevDefName)
        local currentFactionSide = currentDefName and SubLogic.getSideFromUnitName(currentDefName)

        if previousFactionSide and currentFactionSide and previousFactionSide ~= currentFactionSide then
            convertBuildQueueFaction(previousFactionSide, currentFactionSide) 
            if selBuildQueueDefID then
                selBuildQueueDefID = handleSelectedBuildingConversion(selBuildQueueDefID, previousFactionSide, currentFactionSide, selBuildData)
            end
        elseif previousFactionSide and currentFactionSide and previousFactionSide == currentFactionSide then
            Spring.Log(widget:GetInfo().name, LOG.DEBUG, string.format(
                "Sides determined but are the same (%s), no conversion needed.", currentFactionSide))
        else
            Spring.Log(widget:GetInfo().name, LOG.WARNING, string.format(
                "Could not determine sides for conversion: prevDefID=%s (name: %s), currentDefID=%s (name: %s). Names might be unhandled by SubLogic.getSideFromUnitName, or SubLogic itself might be incomplete from a non-critical load error.", 
                tostring(prevStartDefID), tostring(prevDefName), tostring(startDefID), tostring(currentDefName)))
        end
        prevStartDefID = startDefID
	end

	local alphaResults = { queueAlphas = {}, selectedAlpha = ALPHA_DEFAULT }
	local spawnedQueueKeySet = {}
	
	local getBuildQueueSpawnStatus = WG["getBuildQueueSpawnStatus"]
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
		
		local isMex = UnitDefs[selBuildQueueDefID] and UnitDefs[selBuildQueueDefID].extractsMetal > 0
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
		for i = 1, #dragPreviewPositions do
			local positionData = dragPreviewPositions[i]
			local posKey = buildPositionKey(positionData[2], positionData[3], positionData[4], positionData[5])
			if posKey ~= hideKey then
				local canBuild = spTestBuildOrder(positionData[1], positionData[2], positionData[3], positionData[4], positionData[5]) ~= 0
				local isSpawned = spawnedQueueKeySet[posKey] == true
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
	for i = 1, #buildQueue do
		if buildQueue[i][1] > 0 then
			t = t + UnitDefs[buildQueue[i][1]].buildTime
		end
	end
	if startDefID then
		local buildTime = t / UnitDefs[startDefID].buildSpeed
		Spring.SendCommands("luarules initialQueueTime " .. buildTime)
	end

	local tasker
	-- Search for our starting unit
	local units = Spring.GetTeamUnits(Spring.GetMyTeamID())
	for u = 1, #units do
		local uID = units[u]
		if GetUnitCanCompleteQueue(uID) then
			tasker = uID
			if Spring.GetUnitRulesParam(uID, "startingOwner") == Spring.GetMyPlayerID() then
				-- we found our com even if cooping, assigning queue to this particular unit
				break
			end
		end
	end
	if tasker then
		for b = 1, #buildQueue do
			local buildData = buildQueue[b]
			Spring.GiveOrderToUnit(
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
	local currentStartDefID_GS = Spring.GetTeamRulesParam(myTeamID, "startUnit")
	if startDefID ~= currentStartDefID_GS then
	    Spring.Log("gui_pregame_build", LOG.DEBUG, string.format("GameStart: startDefID (%s) differs from current rules param (%s). Updating.", tostring(startDefID), tostring(currentStartDefID_GS)))
	    startDefID = currentStartDefID_GS
	end

	if prevStartDefID ~= startDefID then
		local prevDefName = prevStartDefID and UnitDefs[prevStartDefID] and UnitDefs[prevStartDefID].name
		local currentDefName = startDefID and UnitDefs[startDefID] and UnitDefs[startDefID].name

		local previousFactionSide = prevDefName and SubLogic.getSideFromUnitName(prevDefName)
		local currentFactionSide = currentDefName and SubLogic.getSideFromUnitName(currentDefName)

		if previousFactionSide and currentFactionSide and previousFactionSide ~= currentFactionSide then
			convertBuildQueueFaction(previousFactionSide, currentFactionSide)
		elseif previousFactionSide and currentFactionSide and previousFactionSide == currentFactionSide then
			-- Sides are the same, no conversion needed.
		else
			Spring.Log("gui_pregame_build", LOG.WARNING, string.format("Could not determine sides for conversion in GameStart: prevDefID=%s, currentDefID=%s", tostring(prevStartDefID), tostring(startDefID)))
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
		gameID = Game.gameID and Game.gameID or Spring.GetGameRulesParam("GameID"),
	}
end

function widget:SetConfigData(data)
	if
		data.buildQueue
		and Spring.GetGameFrame() == 0
		and data.gameID
		and data.gameID == (Game.gameID and Game.gameID or Spring.GetGameRulesParam("GameID"))
	then
		buildQueue = data.buildQueue
	end
end
