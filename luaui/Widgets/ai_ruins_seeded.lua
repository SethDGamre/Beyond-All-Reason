
local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name      = "ruin grid visualizer",
		desc      = "Draws grid lines for ruin spawn points",
		author    = "Damgam, SethDGamre",
		date      = "2020",
		license   = "GNU GPL, v2 or later",
		layer     = 0,
		enabled   = true,
	}
end

-- Widgets are always unsynced, no need to check

local mapsizeX = Game.mapSizeX
local mapsizeZ = Game.mapSizeZ
local gl = gl

function widget:DrawWorld()
	local segmentLength = 64 -- Length of each line segment
	local heightOffset = 10 -- All lines 10 units above ground

	-- Draw 512-unit grid lines (red - largest grid) - thickest lines
	gl.Color(1, 0, 0, 0.5)
	local gridSpacing = 512
	gl.LineWidth(4)

	-- Vertical lines (along Z axis)
	gl.BeginEnd(GL.LINES, function()
		for x = 0, mapsizeX, gridSpacing do
			for z = 0, mapsizeZ - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x, z + segmentLength) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x, y2, z + segmentLength)
			end
		end
	end)

	-- Horizontal lines (along X axis)
	gl.BeginEnd(GL.LINES, function()
		for z = 0, mapsizeZ, gridSpacing do
			for x = 0, mapsizeX - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x + segmentLength, z) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x + segmentLength, y2, z)
			end
		end
	end)

	-- Draw 256-unit grid lines (green - medium grid) - medium thickness
	gl.Color(0, 1, 0, 0.5)
	gridSpacing = 256
	gl.LineWidth(2)

	-- Vertical lines (along Z axis)
	gl.BeginEnd(GL.LINES, function()
		for x = 0, mapsizeX, gridSpacing do
			for z = 0, mapsizeZ - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x, z + segmentLength) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x, y2, z + segmentLength)
			end
		end
	end)

	-- Horizontal lines (along X axis)
	gl.BeginEnd(GL.LINES, function()
		for z = 0, mapsizeZ, gridSpacing do
			for x = 0, mapsizeX - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x + segmentLength, z) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x + segmentLength, y2, z)
			end
		end
	end)

	-- Draw 128-unit grid lines (blue - smallest grid) - thinnest lines
	gl.Color(0, 0, 1, 0.5)
	gridSpacing = 128
	gl.LineWidth(1)

	-- Vertical lines (along Z axis)
	gl.BeginEnd(GL.LINES, function()
		for x = 0, mapsizeX, gridSpacing do
			for z = 0, mapsizeZ - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x, z + segmentLength) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x, y2, z + segmentLength)
			end
		end
	end)

	-- Horizontal lines (along X axis)
	gl.BeginEnd(GL.LINES, function()
		for z = 0, mapsizeZ, gridSpacing do
			for x = 0, mapsizeX - segmentLength, segmentLength do
				local y1 = Spring.GetGroundHeight(x, z) + heightOffset
				local y2 = Spring.GetGroundHeight(x + segmentLength, z) + heightOffset
				gl.Vertex(x, y1, z)
				gl.Vertex(x + segmentLength, y2, z)
			end
		end
	end)

	gl.Color(1, 1, 1, 1)
	gl.LineWidth(1)
end

