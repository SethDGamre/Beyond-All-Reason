-- commander_range_utils.lua
-- Pure math utility for calculating circle intersection boundaries and build range validation

local mathAbs = math.abs

-- ============================================================================
-- DEBUGGING CODE - REMOVE BEFORE RELEASE
-- ============================================================================
-- Storage for virtual commanders (for debugging)
local virtualCommanders = {}

-- Add a virtual commander circle (for debugging)
-- Input: x, z, radius - circle parameters
-- Output: index of the added virtual commander
local function addVirtualCommander(x, z, radius)
	local index = #virtualCommanders + 1
	virtualCommanders[index] = {
		x = x,
		z = z,
		radius = radius or 384
	}
	return index
end

-- Clear all virtual commanders (for debugging)
local function clearVirtualCommanders()
	virtualCommanders = {}
end

-- Get all virtual commander circles (for debugging)
-- Output: table of {x, z, radius} circles
local function getVirtualCommanders()
	return virtualCommanders
end
-- ============================================================================
-- END DEBUGGING CODE
-- ============================================================================

-- Get "no go" lines from intersecting circles
-- Input: circles - table of {x, z, radius} for each circle
-- Input: referenceCircleIndex - index of the reference circle (to determine which side is "no go")
-- Output: table of no-go lines, each line is {centerX, centerZ, perpX, perpZ, referenceX, referenceZ, intersectionWidth}
local function getNoGoLines(circles, referenceCircleIndex)
	local noGoLines = {}
	local referenceCircle = circles[referenceCircleIndex]

	if not referenceCircle then
		return noGoLines
	end

	for i = 1, #circles do
		if i ~= referenceCircleIndex then
			local c1 = referenceCircle
			local c2 = circles[i]

			local dx = c2.x - c1.x
			local dz = c2.z - c1.z
			local dist = math.distance2d(c1.x, c1.z, c2.x, c2.z)

			-- Check if circles intersect
			if dist > 0 and dist <= c1.radius + c2.radius and dist >= mathAbs(c1.radius - c2.radius) then
				-- Calculate the intersection points to determine the width of the intersection area
				local a = (c1.radius^2 - c2.radius^2 + dist^2) / (2 * dist)
				local h = math.sqrt(c1.radius^2 - a^2)

				local xm = c1.x + a * dx / dist
				local zm = c1.z + a * dz / dist

				local xs1 = xm + h * dz / dist
				local zs1 = zm - h * dx / dist

				local xs2 = xm - h * dz / dist
				local zs2 = zm + h * dx / dist

				-- Calculate the width of the intersection area (distance between intersection points)
				local intersectionWidth = math.distance2d(xs1, zs1, xs2, zs2)

				-- Calculate the perpendicular bisector between the two circles
				local centerX = (c1.x + c2.x) / 2
				local centerZ = (c1.z + c2.z) / 2

				-- Perpendicular direction (rotate 90 degrees)
				local perpX = -dz / dist
				local perpZ = dx / dist

				-- Store the line with reference point and intersection width
				noGoLines[#noGoLines + 1] = {
					centerX = centerX,
					centerZ = centerZ,
					perpX = perpX,
					perpZ = perpZ,
					referenceX = c1.x,
					referenceZ = c1.z,
					intersectionWidth = intersectionWidth
				}
			end
		end
	end

	return noGoLines
end

-- Check if a point is beyond a list of "no go" lines
-- Input: x, z - point to check
-- Input: noGoLines - table of no-go lines from getNoGoLines()
-- Output: true if point is beyond any no-go line (on the restricted side)
local function isPointBeyondNoGoLines(x, z, noGoLines)
	for _, line in ipairs(noGoLines) do
		-- Vector from line center to test point
		local vx = x - line.centerX
		local vz = z - line.centerZ

		-- Cross product to determine side (negative = one side, positive = other side)
		local cross = line.perpX * vz - line.perpZ * vx

		-- Determine which side is the "allowed" side by checking where reference point is
		local referenceVectorX = line.referenceX - line.centerX
		local referenceVectorZ = line.referenceZ - line.centerZ
		local referenceCross = line.perpX * referenceVectorZ - line.perpZ * referenceVectorX

		-- If the point is on the opposite side from the reference point, it's beyond the line
		if cross * referenceCross < 0 then
			return true
		end
	end

	return false
end

-- Check if a build position is within build range and not beyond no-go lines
-- Input: x, z - build position to check
-- Input: buildRadius - radius of the build range circle
-- Input: buildCenterX, buildCenterZ - center of the build range circle
-- Input: noGoLines - table of no-go lines from getNoGoLines()
-- Output: true if point is within build range AND not beyond any no-go lines
local function isPointInBuildRange(x, z, buildRadius, buildCenterX, buildCenterZ, noGoLines)
	-- First check if point is within build radius
	local distToBuildCenter = math.distance2d(x, z, buildCenterX, buildCenterZ)
	if distToBuildCenter > buildRadius then
		return false
	end

	-- Then check if point is beyond any no-go lines
	if isPointBeyondNoGoLines(x, z, noGoLines) then
		return false
	end

	return true
end

return {
	getNoGoLines = getNoGoLines,
	isPointBeyondNoGoLines = isPointBeyondNoGoLines,
	isPointInBuildRange = isPointInBuildRange,
	-- ============================================================================
	-- DEBUGGING EXPORTS - REMOVE BEFORE RELEASE
	-- ============================================================================
	addVirtualCommander = addVirtualCommander,
	clearVirtualCommanders = clearVirtualCommanders,
	getVirtualCommanders = getVirtualCommanders
	-- ============================================================================
	-- END DEBUGGING EXPORTS
	-- ============================================================================
}