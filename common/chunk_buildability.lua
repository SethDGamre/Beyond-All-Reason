local spTestBuildOrder = Spring.TestBuildOrder
local spGetGroundHeight = Spring.GetGroundHeight
local spPos2BuildPos = Spring.Pos2BuildPos
local floor = math.floor
local ceil = math.ceil

local CHUNK_SIZE_512 = 512
local CHUNK_SIZE_256 = 256
local CHUNK_SIZE_128 = 128
local BAD_RATIO_THRESHOLD = 0.5
local DEFAULT_UNIT_DEF_ID = UnitDefNames.armcom.id

local checkedPositions = {}
local chunkData512 = {}
local chunkData256 = {}
local chunkData128 = {}
local claimedChunks = {}

local function snapToGrid(value, gridSize)
	return floor(value / gridSize) * gridSize
end

local function getGroundHeightAt(x, z)
	return spGetGroundHeight(x, z)
end

local function isPositionBuildable(x, z, unitDefID)
	unitDefID = unitDefID or DEFAULT_UNIT_DEF_ID
	local y = getGroundHeightAt(x, z)
	local buildableX, buildableY, buildableZ = spPos2BuildPos(unitDefID, x, y, z)
	return spTestBuildOrder(unitDefID, buildableX, buildableY, buildableZ, 1) == 0
end

local function getOrCheckPosition(x, z, unitDefID)
	local coordX = checkedPositions[x]
	if coordX and coordX[z] ~= nil then
		return coordX[z]
	end

	local isBuildable = isPositionBuildable(x, z, unitDefID)

	if not checkedPositions[x] then
		checkedPositions[x] = {}
	end
	checkedPositions[x][z] = isBuildable

	return isBuildable
end

local function getChunkCorners(chunkX, chunkZ, chunkSize)
	local halfSize = chunkSize / 2
	return {
		topLeft = {x = chunkX - halfSize, z = chunkZ - halfSize},
		topRight = {x = chunkX + halfSize, z = chunkZ - halfSize},
		bottomLeft = {x = chunkX - halfSize, z = chunkZ + halfSize},
		bottomRight = {x = chunkX + halfSize, z = chunkZ + halfSize},
		center = {x = chunkX, z = chunkZ}
	}
end

local function checkPointsInOrder(corners, unitDefID)
	local results = {}
	local pointOrder = {"topLeft", "topRight", "bottomLeft", "bottomRight", "center"}

	for i, pointName in ipairs(pointOrder) do
		local point = corners[pointName]
		results[pointName] = getOrCheckPosition(point.x, point.z, unitDefID)
	end

	return results
end

local function calculateBadRatio(pointResults)
	local badCount = 0
	local totalCount = 0

	for pointName, isBuildable in pairs(pointResults) do
		totalCount = totalCount + 1
		if not isBuildable then
			badCount = badCount + 1
		end
	end

	return badCount / totalCount
end

local function initializeChunkData512(mapWidth, mapHeight, unitDefID)
	local chunks = {}
	local chunkIndex = 1

	for x = CHUNK_SIZE_512 / 2, mapWidth - CHUNK_SIZE_512 / 2, CHUNK_SIZE_512 do
		for z = CHUNK_SIZE_512 / 2, mapHeight - CHUNK_SIZE_512 / 2, CHUNK_SIZE_512 do
			local corners = getChunkCorners(x, z, CHUNK_SIZE_512)
			local pointResults = checkPointsInOrder(corners, unitDefID)
			local badRatio = calculateBadRatio(pointResults)

			chunks[chunkIndex] = {
				chunkX = x,
				chunkZ = z,
				pointResults = pointResults,
				badRatio = badRatio,
				isMaybeBad = badRatio > BAD_RATIO_THRESHOLD,
				size = CHUNK_SIZE_512
			}
			chunkIndex = chunkIndex + 1
		end
	end

	table.sort(chunks, function(a, b) return a.badRatio > b.badRatio end)

	chunkData512 = chunks
	return chunks
end

local function getChunkData512()
	return chunkData512
end

local function populateChunk256(chunkX, chunkZ, unitDefID)
	local chunkKey = chunkX .. "_" .. chunkZ
	if chunkData256[chunkKey] then
		return chunkData256[chunkKey]
	end

	local subChunks = {}
	local subChunkIndex = 1

	local subChunkCoords = {
		{x = chunkX + CHUNK_SIZE_256/2, z = chunkZ + CHUNK_SIZE_256/2}, -- bottomRight
		{x = chunkX - CHUNK_SIZE_256/2, z = chunkZ + CHUNK_SIZE_256/2}, -- bottomLeft
		{x = chunkX + CHUNK_SIZE_256/2, z = chunkZ - CHUNK_SIZE_256/2}, -- topRight
		{x = chunkX - CHUNK_SIZE_256/2, z = chunkZ - CHUNK_SIZE_256/2}  -- topLeft
	}

	for i, coords in ipairs(subChunkCoords) do
		local corners = getChunkCorners(coords.x, coords.z, CHUNK_SIZE_256)
		local pointResults = checkPointsInOrder(corners, unitDefID)
		local badRatio = calculateBadRatio(pointResults)

		subChunks[subChunkIndex] = {
			chunkX = coords.x,
			chunkZ = coords.z,
			pointResults = pointResults,
			badRatio = badRatio,
			isMaybeBad = badRatio > BAD_RATIO_THRESHOLD,
			size = CHUNK_SIZE_256
		}
		subChunkIndex = subChunkIndex + 1
	end

	table.sort(subChunks, function(a, b) return a.badRatio > b.badRatio end)

	chunkData256[chunkKey] = subChunks
	return subChunks
end

local function populateChunk128(chunkX, chunkZ, unitDefID)
	local chunkKey = chunkX .. "_" .. chunkZ
	if chunkData128[chunkKey] then
		return chunkData128[chunkKey]
	end

	local subChunks = {}
	local subChunkIndex = 1

	local subChunkCoords = {
		{x = chunkX + CHUNK_SIZE_128/2, z = chunkZ + CHUNK_SIZE_128/2}, -- bottomRight
		{x = chunkX - CHUNK_SIZE_128/2, z = chunkZ + CHUNK_SIZE_128/2}, -- bottomLeft
		{x = chunkX + CHUNK_SIZE_128/2, z = chunkZ - CHUNK_SIZE_128/2}, -- topRight
		{x = chunkX - CHUNK_SIZE_128/2, z = chunkZ - CHUNK_SIZE_128/2}  -- topLeft
	}

	for i, coords in ipairs(subChunkCoords) do
		local corners = getChunkCorners(coords.x, coords.z, CHUNK_SIZE_128)
		local pointResults = checkPointsInOrder(corners, unitDefID)
		local badRatio = calculateBadRatio(pointResults)

		subChunks[subChunkIndex] = {
			chunkX = coords.x,
			chunkZ = coords.z,
			pointResults = pointResults,
			badRatio = badRatio,
			isMaybeBad = badRatio > BAD_RATIO_THRESHOLD,
			size = CHUNK_SIZE_128
		}
		subChunkIndex = subChunkIndex + 1
	end

	table.sort(subChunks, function(a, b) return a.badRatio > b.badRatio end)

	chunkData128[chunkKey] = subChunks
	return subChunks
end

local function getExploredChunk128(chunkX, chunkZ, unitDefID)
	local chunk256s = populateChunk256(chunkX, chunkZ, unitDefID)
	local exploredChunk = {}

	for i, chunk256 in ipairs(chunk256s) do
		local chunk128s = populateChunk128(chunk256.chunkX, chunk256.chunkZ, unitDefID)
		for j, chunk128 in ipairs(chunk128s) do
			table.insert(exploredChunk, chunk128)
		end
	end

	table.sort(exploredChunk, function(a, b) return a.badRatio > b.badRatio end)

	return exploredChunk
end

local function claimChunk(chunkX, chunkZ)
	local chunkKey = chunkX .. "_" .. chunkZ
	claimedChunks[chunkKey] = true
end

local function isChunkClaimed(chunkX, chunkZ)
	local chunkKey = chunkX .. "_" .. chunkZ
	return claimedChunks[chunkKey] == true
end

local function getClaimedChunks()
	return claimedChunks
end

return {
	initializeChunkData512 = initializeChunkData512,
	getChunkData512 = getChunkData512,
	populateChunk256 = populateChunk256,
	populateChunk128 = populateChunk128,
	getExploredChunk128 = getExploredChunk128,
	claimChunk = claimChunk,
	isChunkClaimed = isChunkClaimed,
	getClaimedChunks = getClaimedChunks,
	checkedPositions = checkedPositions
}

