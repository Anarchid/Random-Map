
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function gadget:GetInfo()
	return {
		name      = "Map Terrain Generator",
		desc      = "Generates random terrain",
		author    = "GoogleFrog",
		date      = "14 August 2019",
		license   = "GNU GPL, v2 or later",
		layer    = -math.huge + 2,
		enabled   = true  --  loaded by default?
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Configuration

local MIN_EDGE_LENGTH = 10
local DISABLE_TERRAIN_GENERATOR = false
local TIME_MAP_GEN = false
local DRAW_EDGES = false

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

if not gadgetHandler:IsSyncedCode() then
	local timer
	local sumTimer = {}
	local sumTimes = {}
	function TimerEcho(_, text)
		if not timer then
			timer = Spring.GetTimer()
			Spring.Echo(text)
			return
		end
		local cur = Spring.GetTimer()
		Spring.Echo(text, "Elapsed", Spring.DiffTimers(cur, timer, true))
		timer = cur
	end

	function SumTimeStart(_, text)
		sumTimer[text] = Spring.GetTimer()
	end

	function SumTimeEnd(_, text)
		local cur = Spring.GetTimer()
		local diffTime = Spring.DiffTimers(cur, sumTimer[text], true)
		sumTimes[text] = (sumTimes[text] or 0) + diffTime
	end

	function SumTimeEcho(_, text)
		Spring.Echo("SumTime", text, sumTimes[text])
	end

	function gadget:Initialize()
		gadgetHandler:AddSyncAction("TimerEcho", TimerEcho)
		gadgetHandler:AddSyncAction("SumTimeStart", SumTimeStart)
		gadgetHandler:AddSyncAction("SumTimeEnd", SumTimeEnd)
		gadgetHandler:AddSyncAction("SumTimeEcho", SumTimeEcho)
	end

	return
end

local function EchoProgress(text)
	if TIME_MAP_GEN then
		SendToUnsynced("TimerEcho", text)
	else
		Spring.Echo(text)
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local MAP_X = Game.mapSizeX
local MAP_Z = Game.mapSizeZ
local MID_X = MAP_X/2
local MID_Z = MAP_Z/2
local SQUARE_SIZE = Game.squareSize

local spSetHeightMap = Spring.SetHeightMap

local sqrt   = math.sqrt
local pi     = math.pi
local cos    = math.cos
local sin    = math.sin
local abs    = math.abs
local log    = math.log
local floor  = math.floor
local ceil   = math.ceil
local min    = math.min
local max    = math.max
local random = math.random

local textureCounts = {
	veh = 5,
	bot = 5,
	spider = 5,
	uw = 4,
}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Heightmap manipulation

local function FlattenMap(height)
	for x = 0, MAP_X, SQUARE_SIZE do
		for z = 0, MAP_Z, SQUARE_SIZE do
			spSetHeightMap(x, z, height)
		end
		Spring.ClearWatchDogTimer()
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Vector

local function DistSq(p1, p2)
	return (p1[1] - p2[1])^2 + (p1[2] - p2[2])^2
end

local function Dist(p1, p2)
	return sqrt(DistSq(p1, p2))
end

local function Mult(b, v)
	return {b*v[1], b*v[2]}
end

local function Add(v1, v2)
	return {v1[1] + v2[1], v1[2] + v2[2]}
end

local function Subtract(v1, v2)
	return {v1[1] - v2[1], v1[2] - v2[2]}
end

local function ToVector(line)
	return Subtract(line[2], line[1])
end

local function AbsValSq(x)
	return x[1]^2 + x[2]^2
end

local function LengthSq(line)
	return DistSq(line[1], line[2])
end

local function Length(line)
	return Dist(line[1], line[2])
end

local function AbsVal(x, y, z)
	if z then
		return sqrt(x*x + y*y + z*z)
	elseif y then
		return sqrt(x*x + y*y)
	elseif x[3] then
		return sqrt(x[1]*x[1] + x[2]*x[2] + x[3]*x[3])
	else
		return sqrt(x[1]*x[1] + x[2]*x[2])
	end
end

local function Unit(v)
	local mag = AbsVal(v)
	if mag > 0 then
		return {v[1]/mag, v[2]/mag}
	else
		return v
	end
end

local function Norm(b, v)
	local mag = AbsVal(v)
	if mag > 0 then
		return {b*v[1]/mag, b*v[2]/mag}
	else
		return v
	end
end

local function RotateLeft(v)
	return {-v[2], v[1]}
end

local function RotateVector(v, angle)
	return {v[1]*cos(angle) - v[2]*sin(angle), v[1]*sin(angle) + v[2]*cos(angle)}
end

local function Dot(v1, v2)
	if v1[3] then
		return v1[1]*v2[1] + v1[2]*v2[2] + v1[3]*v2[3]
	else
		return v1[1]*v2[1] + v1[2]*v2[2]
	end
end

local function Cross(v1, v2)
	return {v1[2]*v2[3] - v1[3]*v2[2], v1[3]*v2[1] - v1[1]*v2[3], v1[1]*v2[2] - v1[2]*v2[1]}
end

local function Cross_TwoDimensions(v1, v2)
	return v1[1]*v2[2] - v1[2]*v2[1]
end

local function Angle(x,z)
	if not z then
		x, z = x[1], x[2]
	end
	if x == 0 and z == 0 then
		return 0
	end
	local mult = 1/AbsVal(x, z)
	x, z = x*mult, z*mult
	if z > 0 then
		return math.acos(x)
	elseif z < 0 then
		return 2*math.pi - math.acos(x)
	elseif x < 0 then
		return math.pi
	end
	-- x < 0
	return 0
end

local function GetAngleBetweenUnitVectors(u, v)
	return math.acos(Dot(u, v))
end

-- Projection of v1 onto v2
local function Project(v1, v2)
	local uV2 = Unit(v2)
	return Mult(Dot(v1, uV2), uV2)
end

-- The normal of v1 onto v2. Returns such that v1 = normal + projection
local function Normal(v1, v2)
	local projection = Project(v1, v2)
	return Subtract(v1, projection), projection
end

local function GetMidpoint(p1, p2)
	if not p2 then
		p2 = p1[2]
		p1 = p1[1]
	end
	local v = Subtract(p1, p2)
	return Add(p2, Mult(0.5, v))
end

local function IsPositiveIntersect(lineInt, lineMid, lineDir)
	return Dot(Subtract(lineInt, lineMid), lineDir) > 0
end

local function DistanceToBoundedLineSq(point, line)
	local startToPos = Subtract(point, line[1])
	local startToEnd = Subtract(line[2], line[1])
	local normal, projection = Normal(startToPos, startToEnd)
	local projFactor = Dot(projection, startToEnd)
	local normalFactor = Dot(normalFactor, startToEnd)
	if projFactor < 0 then
		return Dist(line[1], point)
	end
	if projFactor > 1 then
		return Dist(line[2], point)
	end
	return AbsValSq(Subtract(startToPos, normal)), normalFactor
end

local function DistanceToBoundedLine(point, line)
	local distSq, normalFactor = DistanceToBoundedLineSq(point, line)
	return sqrt(distSq), normalFactor
end

local function DistanceToLineSq(point, line)
	local startToPos = Subtract(point, line[1])
	local startToEnd = Subtract(line[2], line[1])
	local normal, projection = Normal(startToPos, startToEnd)
	return AbsValSq(normal)
end

local function GetRandomDir()
	local angle = random()*2*pi
	return {cos(angle), sin(angle)}
end

local function GetRandomSign()
	return (math.floor(random()*2))*2 - 1
end

local function SamePoint(p1, p2, acc)
	acc = acc or 1
	return ((p1[1] - p2[1] < acc) and (p2[1] - p1[1] < acc)) and ((p1[2] - p2[2] < acc) and (p2[2] - p1[2] < acc))
end

local function SameLine(l1, l2)
	local same = (SamePoint(l1[1], l2[1], 5) and SamePoint(l1[2], l2[2], 5))
	local sameButReversed = (SamePoint(l1[1], l2[2], 5) and SamePoint(l1[2], l2[1], 5))
	return same or sameButReversed, sameButReversed
end

local function CompareLength(a, b)
	return a.length > b.length
end

local function InverseBasis(a, b, c, d)
	local det = a*d - b*c
	return d/det, -b/det, -c/det, a/det
end

local function ChangeBasis(v, a, b, c, d)
	return {v[1]*a + v[2]*b, v[1]*c + v[2]*d}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Point manipulation

local function PutPointInMap(point, edgeBuffer)
	point = {point[1], point[2]}
	if point[1] < edgeBuffer then
		point[1] = edgeBuffer
	elseif point[1] > MAP_X - edgeBuffer then
		point[1] = MAP_X - edgeBuffer
	end
	
	if point[2] < edgeBuffer then
		point[2] = edgeBuffer
	elseif point[2] > MAP_Z - edgeBuffer then
		point[2] = MAP_Z - edgeBuffer
	end
	
	return point
end

local function GetClosestPoint(point, nearPoints, useSize, avoidIndex)
	if not nearPoints[1] then
		return false
	end
	local closeIndex = 1
	if avoidIndex == closeIndex then
		if not nearPoints[2] then
			return false
		end
		closeIndex = 2
	end
	local closeDist = Dist(point, nearPoints[closeIndex]) - ((useSize and nearPoints[closeIndex].size) or 0)
	for i = 2, #nearPoints do
		if avoidIndex ~= i then
			local thisDist = Dist(point, nearPoints[i]) - ((useSize and nearPoints[i].size) or 0)
			if thisDist < closeDist then
				closeIndex = i
				closeDist = thisDist
			end
		end
	end
	
	return closeIndex, closeDist
end

local function GetClosestCell(point, nearCells)
	if not nearCells[1] then
		return false
	end
	local closeIndex = 1
	local closeDistSq = DistSq(point, nearCells[1].site)
	for i = 2, #nearCells do
		local thisDistSq = DistSq(point, nearCells[i].site)
		if thisDistSq < closeDistSq then
			closeIndex = i
			closeDistSq = thisDistSq
		end
	end
	
	return nearCells[closeIndex], closeDistSq
end

local function GetClosestLine(point, nearLines, FilterFunc)
	if not nearLines[1] then
		return false
	end
	local closeIndex, closeDistSq
	for i = 1, #nearLines do
		if (not FilterFunc) or FilterFunc(nearLines[i]) then
			local thisDistSq = DistanceToLineSq(point, nearLines[i])
			if (not closeDistSq) or (thisDistSq < closeDistSq) then
				closeIndex = i
				closeDistSq = thisDistSq
			end
		end
	end
	
	return closeIndex, closeDistSq
end

local function GetPointCell(point, cells)
	if not cells[1] then
		return false
	end
	local closeIndex = 1
	local closeDistSq = DistSq(point, cells[1].site)
	for i = 2, #cells do
		local thisDistSq = DistSq(point, cells[i].site)
		if thisDistSq < closeDistSq then
			closeIndex = i
			closeDistSq = thisDistSq
		end
	end
	
	return closeIndex, closeDistSq
end

local function RandomWithCornerBias(edgeBias)
	if (edgeBias or 1) == 1 then
		return random()
	end
	local base = random()
	local sign = (base > 0.5 and 1) or -1
	local val = abs(base - 0.5)*2
	return 0.5 + 0.5*sign*(1 - val^edgeBias)
end

local function GetRandomCoordWithEdgeBias(edgeBias)
	if (edgeBias or 1) == 1 then
		return {random()*MAP_X, random()*MAP_Z}
	end
	
	local distToEdge = 0.5*(1 - sqrt(random()))^edgeBias
	local sideLength = 1 - 2*distToEdge
	local pos = random()
	
	if pos < 0.25 then
		return {(distToEdge + sideLength*random())*MAP_X, distToEdge*MAP_Z}
	elseif pos < 0.5 then
		return {distToEdge*MAP_X, (distToEdge + sideLength*random())*MAP_Z}
	elseif pos < 0.75 then
		return {(distToEdge + sideLength*random())*MAP_X, (sideLength + distToEdge)*MAP_Z}
	else
		return {(sideLength + distToEdge)*MAP_X, (distToEdge + sideLength*random())*MAP_Z}
	end
end

local function GetRandomMapCoord(avoidDist, avoidPoints, maxAttempts, useOtherSize, edgeBias)
	local point = GetRandomCoordWithEdgeBias(edgeBias)
	if not avoidDist then
		return point
	end
	
	local attempts = 1
	while (select(2, GetClosestPoint(point, avoidPoints, useOtherSize)) or 0) < avoidDist do
		point = GetRandomCoordWithEdgeBias(edgeBias)
		attempts = attempts + 1
		if attempts > maxAttempts then
			break
		end
	end
	
	return point
end

local function GetRandomPointInCircle(pos, radius, edgeBuffer, onBorder)
	if not onBorder then
		radius = radius*sqrt(random())
	end
	local randomPos = Add(pos, Mult(radius, GetRandomDir()))
	if not edgeBuffer then
		return randomPos
	end
	
	return PutPointInMap(randomPos, edgeBuffer)
end

local function GetRandomPointInCircleAvoid(avoidDist, avoidPoints, maxAttempts, pos, radius, edgeBuffer, onBorder, useOtherSize)
	local point = GetRandomPointInCircle(pos, radius, edgeBuffer, onBorder)
	local attempts = 1
	while (select(2, GetClosestPoint(point, avoidPoints, useOtherSize)) or 0) < avoidDist do
		point = GetRandomPointInCircle(pos, radius, edgeBuffer, onBorder)
		attempts = attempts + 1
		if attempts > maxAttempts then
			break
		end
	end
	
	return point
end

local function ApplyRotSymmetry(p1, p2)
	if not p2 then
		return {MAP_X - p1[1], MAP_Z - p1[2]}
	end
	return {ApplyRotSymmetry(p1), ApplyRotSymmetry(p2)}
end

local function RotateAround(point, pivot)
	return {pivot[1]*2 - point[1], pivot[2]*2 - point[2]}
end

local function GetBoundedLineIntersection(line1, line2)
	local x1, y1, x2, y2 = line1[1][1], line1[1][2], line1[2][1], line1[2][2]
	local x3, y3, x4, y4 = line2[1][1], line2[1][2], line2[2][1], line2[2][2]
	
	local denominator = ((x1 - x2)*(y3 - y4) - (y1 - y2)*(x3 - x4))
	if denominator == 0 then
		return false
	end
	local first = ((x1 - x3)*(y3 - y4) - (y1 - y3)*(x3 - x4))/denominator
	local second = -1*((x1 - x2)*(y1 - y3) - (y1 - y2)*(x1 - x3))/denominator
	
	if first < 0 or first > 1 or (second < 0 or second > 1) then
		return false
	end
	
	local px = x1 + first*(x2 - x1)
	local py = y1 + first*(y2 - y1)
	
	return {px, py}
end

local function InMapBounds(point)
	return not (point[1] < 0 or point[2] < 0 or point[1] > MAP_X or point[2] > MAP_Z)
end

local function GetPosIndex(x, z)
	return x + (MAP_X + 1)*z
end

local function EdgeAdjacentToCellIndex(edge, cellIndex)
	for i = 1, #edge.faces do
		if edge.faces[i].index == cellIndex then
			return true
		end
	end
	return false
end

local function GetAnticlockwiseIntAndEdge(edge, cellIndex)
	for n = 1, #edge.neighbours do
		local nbhd = edge.neighbours[n]
		for i = 1, #nbhd do
			local otherEdge = nbhd[i]
			if edge.anticlockwiseNeighbour[otherEdge.index] and EdgeAdjacentToCellIndex(otherEdge, cellIndex) then
				return edge[n], otherEdge
			end
		end
	end
end

local function AreaOfPolygon(vertices)
	-- Greens theorem line integral
	local area = 0
	local vertexCount = #vertices
	for i = 1, vertexCount do
		local p1 = vertices[i]
		local p2 = vertices[i%vertexCount + 1]
		area = area + (p2[1] + p1[1])*(p2[2] - p1[2])/2
	end
	
	return area
end

local function GetCellVertices(cell)
	local cellIndex = cell.index
	local startEdge = cell.edges[1]
	local points = {}
	
	local intPoint, thisEdge = GetAnticlockwiseIntAndEdge(startEdge, cellIndex)
	points[#points + 1] = intPoint
	
	while thisEdge.index ~= startEdge.index do
		intPoint, thisEdge = GetAnticlockwiseIntAndEdge(thisEdge, cellIndex)
		points[#points + 1] = intPoint
	end
	
	return points
end

local function AveragePoints(points)
	local sumX = 0
	local sumZ = 0
	for i = 1, #points do
		sumX = sumX + points[i][1]
		sumZ = sumZ + points[i][2]
	end
	
	return {sumX/#points, sumZ/#points}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Heightmap Functions

local function GetHeight(heights, pos)
	local x, z = pos[1], pos[2]
	if x < 0 then
		x = 0
	end
	if x > MAP_X then
		x = MAP_X
	end
	if z < 0 then
		z = 0
	end
	if z > MAP_Z then
		z = MAP_Z
	end
	x = SQUARE_SIZE*floor((x + SQUARE_SIZE*0.5)/SQUARE_SIZE)
	z = SQUARE_SIZE*floor((z + SQUARE_SIZE*0.5)/SQUARE_SIZE)
	return heights[x][z]
end

local function SufficientlyFlat(pos, heights, checkSquare, flatRequirement, heightRequirement)
	local minHeight = GetHeight(heights, Add(pos, {checkSquare, checkSquare}))
	local maxHeight = minHeight
	
	local toCheck = {
		Add(pos, {-checkSquare, -checkSquare}),
		Add(pos, {checkSquare, -checkSquare}),
		Add(pos, {-checkSquare, checkSquare}),
	}
	for i = 1, #toCheck do
		local height = GetHeight(heights, toCheck[i])
		minHeight = min(minHeight, height)
		maxHeight = max(maxHeight, height)
	end
	
	if heightRequirement and minHeight < heightRequirement then
		return false
	end
	
	return (maxHeight - minHeight) < flatRequirement
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Baked Tables

local OUTER_POINTS = {
	{ -4*MAP_X,  -4*MAP_Z},
	{ -4*MAP_X,   5*MAP_Z},
	{  5*MAP_X,  -4*MAP_Z},
	{  5*MAP_X,   5*MAP_Z},
}

local MAP_BORDER = {
	{{-10*MAP_X,     0}, {10*MAP_X,     0}},
	{{-10*MAP_X, MAP_Z}, {10*MAP_X, MAP_Z}},
	{{    0, -10*MAP_Z}, {    0, 10*MAP_Z}},
	{{MAP_X, -10*MAP_Z}, {MAP_X, 10*MAP_Z}},
}

local smoothFilter = {}
for x = -32, 32, 8 do
	for z = -32, 32, 8 do
		local short, long
		if abs(x) < abs(z) then
			short, long = abs(x), abs(z)
		else
			short, long = abs(z), abs(x)
		end
		if short == 0 and long == 32 then
			smoothFilter[#smoothFilter + 1] = {x, z, 0.33}
		elseif short == 8 and long == 32 then
			smoothFilter[#smoothFilter + 1] = {x, z, 0.18}
		elseif short == 16 and long == 24 then
			smoothFilter[#smoothFilter + 1] = {x, z, 0.75}
		elseif short + long <= 32 then
			smoothFilter[#smoothFilter + 1] = {x, z, 1}
		end
	end
end

local END_FLATTENING = 1.04
local POINT_COUNT = 11
local CIRCLE_POINTS = {}
for i = pi, pi*3/2 + pi/(4*POINT_COUNT), pi/(2*POINT_COUNT) do
	CIRCLE_POINTS[#CIRCLE_POINTS + 1] = {1 + cos(i), 1 + sin(i)}
end
local HIT_EDGE_POINTS = {}
for i = pi, pi*3/2 + pi/(4*POINT_COUNT), pi/(2*POINT_COUNT) do
	local prop = math.min(1, (i - pi)/(pi/2 + pi/(4*POINT_COUNT)))
	HIT_EDGE_POINTS[#HIT_EDGE_POINTS + 1] = {0.5 + (1 - prop)*cos(i) + prop*0.5, 1 + sin(i)}
end

local STRAIGHT_EDGE_POINTS = 18

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Voronoi

local function GetBoundedLine(pos, dir, bounder)
	local line = {Add(pos, Mult(50*MAP_X, dir)), Add(pos, Mult(-50*MAP_X, dir))}
	return line
end

local function GetBoundingCells()
	local cells = {}
	for i = 1, #OUTER_POINTS do
		local newCell = {
			site = OUTER_POINTS[i],
			edges = {},
		}
		local cellCorners = {
			{-4.5*MAP_X, -4.5*MAP_Z},
			{ 4.5*MAP_X, -4.5*MAP_Z},
			{ 4.5*MAP_X,  4.5*MAP_Z},
			{-4.5*MAP_X,  4.5*MAP_Z},
		}
		
		local sx, sz = newCell.site[1], newCell.site[2]
		for j = 1, #cellCorners do
			newCell.edges[#newCell.edges + 1] = {Add(newCell.site, cellCorners[j]), Add(newCell.site, cellCorners[(j%4) + 1])}
		end
		cells[#cells + 1] = newCell
	end
	
	local offset = {10*MAP_X, 10*MAP_Z}
	
	return cells
end

local function GenerateVoronoiCells(points)
	local outerCells = GetBoundingCells()
	local cells = {}
	local edgeIndex = 0
	
	for i = 1, #points do
		local newCell = {
			site = points[i],
			edges = {},
		}
		for j = 1 - #outerCells, #cells do
			local otherCell = (j > 0 and cells[j]) or outerCells[j + #outerCells]
			local pos = GetMidpoint(newCell.site, otherCell.site)
			local dir = RotateLeft(Unit(Subtract(newCell.site, otherCell.site)))
			local line = GetBoundedLine(pos, dir, OUTER_BOUNDS)
			
			local intersections = false
			for k = #otherCell.edges, 1, -1 do
				local otherEdge = otherCell.edges[k]
				local int = GetBoundedLineIntersection(line, otherEdge)
				if int then
					if GetBoundedLineIntersection(line, {otherEdge[1], otherCell.site}) then
						otherCell.edges[k] = {int, otherCell.edges[k][2], otherCell.edges[k][3]}
					else
						otherCell.edges[k] = {otherCell.edges[k][1], int, otherCell.edges[k][3]}
					end
					intersections = intersections or {}
					intersections[#intersections + 1] = int
				else
					if GetBoundedLineIntersection(line, {otherEdge[1], otherCell.site}) then
						otherCell.edges[k] = otherCell.edges[#otherCell.edges]
						otherCell.edges[#otherCell.edges] = nil
					end
				end
			end
			if intersections then
				if #intersections ~= 2 then
					--for e = 1, #intersections do
					--	PointEcho(intersections[e], "Int: " .. e)
					--end
					--Spring.Echo("#intersections ~= 2", #intersections)
					return false
				end
				newCell.edges[#newCell.edges + 1] = intersections
				otherCell.edges[#otherCell.edges + 1] = intersections
				
				edgeIndex = edgeIndex + 1
				intersections[3] = edgeIndex
			end
		end
		cells[#cells + 1] = newCell
	end
	
	return cells
end

local function BoundExtendedVoronoiToMapEdge(cells)
	if not cells then
		return false
	end
	
	for i = 1, #MAP_BORDER do
		local borderLine = MAP_BORDER[i]
		for j = #cells, 1, -1 do
			local thisCell = cells[j]
			local intersections = false
			for k = #thisCell.edges, 1, -1 do
				local thisEdge = thisCell.edges[k]
				local int = GetBoundedLineIntersection(borderLine, thisEdge)
				if int then
					if GetBoundedLineIntersection(borderLine, {thisEdge[1], thisCell.site}) then
						thisCell.edges[k] = {int, thisCell.edges[k][2], thisCell.edges[k][3]}
					else
						thisCell.edges[k] = {thisCell.edges[k][1], int, thisCell.edges[k][3]}
					end
					intersections = intersections or {}
					intersections[#intersections + 1] = int
				else
					if GetBoundedLineIntersection(borderLine, {thisEdge[1], thisCell.site}) then
						thisCell.edges[k] = thisCell.edges[#thisCell.edges]
						thisCell.edges[#thisCell.edges] = nil
					end
				end
			end
			if intersections then
				thisCell.edges[#thisCell.edges + 1] = intersections
			end
		end
	end
	return cells
end

local function CheckAndFillEdgeAdjacency(thisEdge, otherEdge, sharedCell)
	if otherEdge.index == thisEdge.index then
		return
	end
	for n = 1, #thisEdge.neighbours do
		local thisNbhd = thisEdge.neighbours[n]
		local otherN = (SamePoint(thisEdge[n], otherEdge[1]) and 1) or (SamePoint(thisEdge[n], otherEdge[2]) and 2)
		if otherN then
			thisEdge.anticlockwiseNeighbour[otherEdge.index] = (Cross_TwoDimensions(Subtract(thisEdge[3 - n], thisEdge[n]), Subtract(otherEdge[3 - otherN], otherEdge[otherN])) < 0)
			thisEdge.incidentEnd[otherEdge.index] = otherN
			thisEdge.incidentFace[otherEdge.index] = sharedCell
			
			thisNbhd[#thisNbhd + 1] = otherEdge
			if (otherEdge.faces[1].index ~= thisEdge.faces[1].index) and (otherEdge.faces[1].index ~= (thisEdge.faces[2] and thisEdge.faces[2].index)) then
				thisNbhd.endFace = otherEdge.faces[1]
			elseif otherEdge.faces[2] and (otherEdge.faces[2].index ~= thisEdge.faces[1].index) and (otherEdge.faces[2].index ~= (thisEdge.faces[2] and thisEdge.faces[2].index)) then
				thisNbhd.endFace = otherEdge.faces[2]
			end
		end
	end
end

local function CleanVoronoiReferences(cells)
	if not cells then
		return false
	end
	
	local edgeList = {}
	local edgesAdded = {}
	
	-- Enter mirror cell
	for i = 1, #cells do
		cells[i].neighbours = {}
		cells[i].index = i
		cells[i].mirror = cells[cells[i].site.mirror]
		cells[i].site.mirror = nil
	end
	
	-- Find cell neighbours and edge faces.
	for i = 1, #cells do
		local thisCell = cells[i]
		for j = 1, #thisCell.edges do
			local thisEdge = thisCell.edges[j]
			if thisEdge[3] and edgesAdded[thisEdge[3]] then -- Check for edgeIndex
				thisEdge = edgesAdded[thisEdge[3]]
				thisCell.edges[j] = thisEdge
				
				if thisEdge.faces[1] then
					local otherCell = thisEdge.faces[1]
					otherCell.neighbours[#otherCell.neighbours + 1] = thisCell
					thisCell.neighbours[#thisCell.neighbours + 1] = otherCell
				end
				
				thisEdge.faces[#thisEdge.faces + 1] = thisCell
			else
				edgeList[#edgeList + 1] = thisEdge
				thisEdge.faces = {thisCell}
				if thisEdge[3] then
					edgesAdded[thisEdge[3]] = thisEdge
				end
			end
		end
	end
	
	-- Set index as it is required for the self-mirror check
	for i = 1, #edgeList do
		local thisEdge = edgeList[i]
		thisEdge.index = i
	end
	
	-- Find edge mirror
	for i = 1, #cells do
		local thisCell = cells[i]
		local mirrorCell = thisCell.mirror
		if mirrorCell then
			for j = 1, #thisCell.edges do
				local thisEdge = thisCell.edges[j]
				local rotLine = ApplyRotSymmetry(thisEdge[1], thisEdge[2])
				if not thisEdge.mirror then
					for k = 1, #mirrorCell.edges do
						local otherEdge = mirrorCell.edges[k]
						local same, reversed = SameLine(otherEdge, rotLine)
						if same then
							if reversed then
								otherEdge[1], otherEdge[2] = otherEdge[2], otherEdge[1]
							end
							thisEdge.mirror = otherEdge
							otherEdge.mirror = thisEdge
							thisEdge.firstMirror = true
							
							if thisEdge.index == otherEdge.index then
								thisEdge.selfMirror = true
							end
							break
						end
					end
				end
			end
		end
	end
	
	-- Set edge length and faces
	for i = 1, #edgeList do
		local thisEdge = edgeList[i]
		thisEdge.length = Length(thisEdge)
		thisEdge.unit   = Unit(Subtract(thisEdge[2], thisEdge[1]))
		thisEdge.otherFace = {}
		if thisEdge.faces[2] then
			for j = 1, #thisEdge.faces do
				thisEdge.otherFace[thisEdge.faces[j].index] = thisEdge.faces[3 - j]
			end
			if thisEdge.faces[1].mirror == thisEdge.faces[2] then
				thisEdge.faces[1].adjacentToMirror = true
				thisEdge.faces[2].adjacentToMirror = true
			end
		else
			local thisCell = thisEdge.faces[1]
			if thisCell.adjacentToBorder then
				thisCell.adjacentToCorner = true
			end
			thisCell.adjacentToBorder = thisCell.adjacentToBorder or {}
			thisCell.adjacentToBorder[#thisCell.adjacentToBorder + 1] = thisEdge
		end
		
		if thisEdge.length < MIN_EDGE_LENGTH then
			-- Restart without one of the cells adjacent to this edge.
			--LineEcho(thisEdge, "REMOVED")
			--for i = 1, #cells do
			--	CellEcho(cells[i])
			--end
			return cells, edgeList, thisEdge.faces[random(1, #thisEdge.faces)].index
		end
	end
	
	-- Set edge neighbours
	for i = 1, #edgeList do
		local thisEdge = edgeList[i]
		thisEdge.neighbours = {
			[1] = {},
			[2] = {},
		}
		thisEdge.anticlockwiseNeighbour = {}
		thisEdge.incidentEnd = {}
		thisEdge.incidentFace = {}
		
		for j = 1, #thisEdge.faces do
			local thisCell = thisEdge.faces[j]
			for k = 1, #thisCell.edges do
				local otherEdge = thisCell.edges[k]
				CheckAndFillEdgeAdjacency(thisEdge, otherEdge, thisCell)
			end
			
			-- Get border neighbours
			if #thisEdge.faces == 1 then
				for k = 1, #thisCell.neighbours do
					local otherCell = thisCell.neighbours[k]
					if otherCell.adjacentToBorder then
						for h = 1, #otherCell.adjacentToBorder do
							local otherEdge = otherCell.adjacentToBorder[h]
							CheckAndFillEdgeAdjacency(thisEdge, otherEdge, false)
						end
					end
				end
			end
		end
	end
	
	-- Find edges that outline the non-border cells
	for i = 1, #edgeList do
		local thisEdge = edgeList[i]
		if thisEdge.faces[2] and thisEdge.faces[1].adjacentToBorder ~= thisEdge.faces[2].adjacentToBorder then
			thisEdge.innerBorderEdge = true
			if thisEdge.faces[1].adjacentToBorder then
				thisEdge.faces[2].innerBorderEdges = (thisEdge.faces[2].innerBorderEdges or 0) + 1
			else
				thisEdge.faces[1].innerBorderEdges = (thisEdge.faces[1].innerBorderEdges or 0) + 1
			end
		end
	end
	
	-- Some useful cell parameters.
	for i = 1, #cells do
		local thisCell = cells[i]
		thisCell.vertices = GetCellVertices(thisCell)
		thisCell.area = AreaOfPolygon(thisCell.vertices)
		thisCell.averageMid = AveragePoints(thisCell.vertices)
		thisCell.firstMirror = ((not thisCell.mirror) or (thisCell.index < thisCell.mirror.index))
	end
	
	return cells, edgeList
end

local function AddPointAndMirror(points, point, size)
	if not point then
		return
	end
	local pointMirror = ApplyRotSymmetry(point)
	
	point.size = size
	pointMirror.size = size

	points[#points + 1] = point
	pointMirror.mirror = #points
	points[#points + 1] = pointMirror
	point.mirror = #points
end

local function DoPointSplit(points, radius, ignoreSplit)
	local pointsToAdd = {}
	for i = 1, #points do
		local point = points[i]
		if i < point.mirror and not (ignoreSplit and ignoreSplit[i]) then
			local index, dist = GetClosestPoint(point, points, false, i)
			if dist > radius then
				local newPoint = GetRandomPointInCircle(point, radius*0.5, 50, true)
				
				-- Mirror around point and add some randomness.
				pointsToAdd[#pointsToAdd + 1] = GetRandomPointInCircleAvoid(radius*0.25, {newPoint}, 50, RotateAround(newPoint, point), 50, radius*0.25, 50)
				
				-- Replace and mirror around map centre
				local newPointMirror = ApplyRotSymmetry(newPoint)
				
				newPoint.size = point.size
				newPoint.mirror = point.mirror
				newPointMirror.size = points[point.mirror].size
				newPointMirror.mirror = points[point.mirror].mirror
				
				points[i] = newPoint
				points[point.mirror] = newPointMirror
			end
		end
	end
	
	for i = 1, #pointsToAdd do
		AddPointAndMirror(points, pointsToAdd[i], pointsToAdd[i].size)
	end
end

local function MakeRandomPoints(params)
	local pointNum, minSpacing, maxSpacing = params.points, params.minSpace, params.maxSpace
	local edgeBias, midPoints, midPointRadius = params.edgeBias, params.midPoints, params.midPointRadius
	
	local points = {}
	if params.startPoint then
		AddPointAndMirror(points, params.startPoint, params.startPointSize)
	end
	
	local avoidDist = maxSpacing
	for i = 1, pointNum do
		local point = GetRandomMapCoord(avoidDist, points, 50, true, edgeBias)
		AddPointAndMirror(points, point, avoidDist)
		avoidDist = avoidDist - (maxSpacing - minSpacing)/pointNum
	end
	
	for i = 1, midPoints do
		local point = GetRandomPointInCircleAvoid(params.midPointSpace, points, 50, {MAP_X/2, MAP_Z/2}, params.midPointRadius, 50, false, true)
		AddPointAndMirror(points, point, params.midPointSpace)
	end
	
	if params.pointSplitRadius then
		DoPointSplit(points, params.pointSplitRadius, (params.startPoint and {1, 2}) or false)
	end
	
	return points
end

local function GetVoronoi(params)
	local points = MakeRandomPoints(params)
	
	local cells, edges, badSite = CleanVoronoiReferences(BoundExtendedVoronoiToMapEdge(GenerateVoronoiCells(points)))
	while (not cells) or badSite do
		if cells then
			points = {}
			for i = 1, #cells do
				local thisCell = cells[i]
				if thisCell.site and (thisCell.index ~= badSite) and ((not thisCell.mirror) or (thisCell.mirror.index ~= badSite)) then
					local point = {thisCell.site[1], thisCell.site[2]}
					AddPointAndMirror(points, point, thisCell.size)
					
					thisCell.site = nil
					if thisCell.mirror then
						thisCell.mirror.site = nil
					end
				end
			end
		else
			points = MakeRandomPoints(params)
		end
		cells, edges, badSite = CleanVoronoiReferences(BoundExtendedVoronoiToMapEdge(GenerateVoronoiCells(points)))
	end
	return cells, edges
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Base terrain generation

local function GetWave(translational, params)
	local spread     = params.spread or ((params.spreadMin or 1) + ((params.spreadMax or 1) - (params.spreadMin or 1))*random())
	local scale      = params.scale  or ((params.scaleMin  or 1) + ((params.scaleMax  or 1) - (params.scaleMin  or 1))*random())
	local period     = params.period or ((params.periodMin or 1) + ((params.periodMax or 1) - (params.periodMin or 1))*random())
	local offset     = params.offset or ((params.offsetMin or 1) + ((params.offsetMax or 1) - (params.offsetMin or 1))*random())
	local growth     = params.growth or ((params.growthMin or 1) + ((params.growthMax or 1) - (params.growthMin or 1))*random())
	
	local wavePeriod = math.ceil(params.wavePeriod or ((params.wavePeriodMin or 1) + ((params.wavePeriodMax or 1) - (params.wavePeriodMin or 1))*random()))
	
	if params.spreadScaleMin and params.spreadScaleMax then
		local spreadScale = (params.spreadScaleMin + (params.spreadScaleMax - params.spreadScaleMin)*random())
		spread = spread*0.5 + wavePeriod*spreadScale*0.5
	end
	
	-- scale         - Amplitude of main waves.
	-- period        - Period of main waves.
	-- offset        - Constant added to waves.
	-- growth        - Peak-to-peak scaling factor of scale.
	-- spread        - Amplitude of transverse sub-waves.
	-- wavePeriod    - Period of the sub-waves in translational waves.
	-- waveRotations - Even integer that sets the rotational symmetry of sub-wave that occur along the rotational waves.
	-- spreadScale   - Sets spread to the average of spread and wavePeriod*spreadScale
	
	scale = scale*GetRandomSign()
	growth = growth*GetRandomSign()
	
	--Spring.Echo("scale", scale, "period", period, "offset", offset, "growth", growth)
	-- Growth is increase in amplitude per (unmodified) peak-to-peak distance.
	growth = growth/period
	
	-- Period is peak-to-peak distance.
	period = period/(2*pi)
	
	local dir, zeroAngle, stretchReduction
	
	if translational then
		dir = GetRandomDir()
		wavePeriod = wavePeriod/(2*pi)
	else
		zeroAngle = (not translational) and random()*2*pi
		local waveRotations = (not translational) and (params.waveRotations or ((params.waveRotationsMin or 1) + ((params.waveRotationsMax or 1) - (params.waveRotationsMin or 1))*random()))
		waveRotations = math.ceil(waveRotations/2)*2 -- Must be even for twofold rotational symmetry
		wavePeriod = 1/waveRotations
		
		spread = spread/(period*(2*pi))
		stretchReduction = spread/2
	end
	
	local function GetValue(x, z)
		x = x - MID_X
		z = z - MID_Z
		
		local distance, tranDist
		if translational then
			distance  = dir[1]*x + dir[2]*z
			tranDist  = dir[1]*z - dir[2]*x
			
			-- Implement translate spread
			distance = abs(distance - sin(tranDist/wavePeriod)*spread)
		else
			distance  = sqrt(x^2 + z^2)
			distance  = (distance*distance)/(180 + distance)
			tranDist  = Angle(x,z) + zeroAngle
			-- *(distance/(distance + stretchReduction))
			-- Implement scale spread
			distance = abs(distance*(1 + sin(tranDist/wavePeriod)*spread))
		end
		
		return -1*(cos((distance/period)) - 1)*(distance*growth + scale) + offset
	end
	
	return GetValue
end

local function GetTranslationalWave(params)
	return GetWave(true, params)
end

local function GetRotationalWave(params)
	return GetWave(false, params)
end

local function GetTerrainWaveFunction(params)
	local multParams = {
		scaleMin = 0.65,
		scaleMax = 0.8,
		periodMin = 2000,
		periodMax = 5000 - 1500*params.generalWaveMod,
		spreadMin = 200,
		spreadMax = 900,
		offsetMin = -0.2,
		offsetMax = 0.2,
		growthMin = 0.15,
		growthMax = 0.2 + 0.2*params.generalWaveMod,
		wavePeriodMin = 1000,
		wavePeriodMax = 2600,
		waveRotationsMin = 1,
		waveRotationsMax = 8,
		spreadScaleMin = 0.2,
		spreadScaleMax = 0.4,
	}
	
	local translateParams = {
		scaleMin = 60,
		scaleMax = 60 + 20*params.generalWaveMod,
		periodMin = 1800,
		periodMax = 3000,
		spreadMin = 20,
		spreadMax = 120,
		offsetMin = 30,
		offsetMax = 90,
		growthMin = 5,
		growthMax = 20,
		wavePeriodMin = 800,
		wavePeriodMax = 1700,
		waveRotationsMin = 1,
		waveRotationsMax = 8,
		spreadScaleMin = 0.025,
		spreadScaleMax = 0.07,
	}
	
	local rotParams = {
		scaleMin = 60,
		scaleMax = 60 + 20*params.generalWaveMod,
		periodMin = 1800,
		periodMax = 4000,
		spreadMin = 60,
		spreadMax = 300,
		offsetMin = 30,
		offsetMax = 90,
		growthMin = 5,
		growthMax = 20,
		wavePeriodMin = 800,
		wavePeriodMax = 1700,
		waveRotationsMin = 1,
		waveRotationsMax = 8,
	}

	local bigMultParams = {
		scaleMin = 0.9,
		scaleMax = 1 + 0.2*params.generalWaveMod,
		periodMin = 18000,
		periodMax = 45000,
		spreadMin = 2000,
		spreadMax = 8000,
		offsetMin = 0.3,
		offsetMax = 0.4,
		growthMin = 0.02,
		growthMax = 0.2,
		wavePeriodMin = 3500,
		wavePeriodMax = 5000,
		waveRotationsMin = 1,
		waveRotationsMax = 8,
	}
	
	local rotMult = GetRotationalWave(multParams)
	local transMult = GetTranslationalWave(multParams)

	local rot = GetRotationalWave(rotParams)
	local trans = GetTranslationalWave(translateParams)
	translateParams.periodMin = translateParams.periodMin*1.6
	translateParams.periodMax = translateParams.periodMax*1.6
	
	local trans2 = GetTranslationalWave(translateParams)
	local transMult2 = GetTranslationalWave(multParams)
	translateParams.periodMin = translateParams.periodMin*1.6
	translateParams.periodMax = translateParams.periodMax*1.6
	
	local trans3 = GetTranslationalWave(translateParams)
	local rotMult3 = GetRotationalWave(multParams)
	translateParams.periodMin = translateParams.periodMin*1.6
	translateParams.periodMax = translateParams.periodMax*1.6
	
	local bigMult = GetTranslationalWave(bigMultParams)
	
	local function GetValue(x, z)
		--return rot(x,z)*5 + 70
		return 1.25*(rot(x,z)*transMult(x,z) + trans(x,z)*rotMult(x,z) + bigMult(x,z)*(trans2(x,z)*transMult2(x,z) + trans3(x,z)*rotMult3(x,z)) + 70)
	end
	
	return GetValue
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Write terrain

local function TerraformByFunc(func)
	local function DoTerra()
		for x = 0, MAP_X, SQUARE_SIZE do
			for z = 0, MAP_Z, SQUARE_SIZE do
				spSetHeightMap(x, z, func(x, z))
			end
			Spring.ClearWatchDogTimer()
		end
	end
	
	Spring.SetHeightMapFunc(DoTerra)
end

local function TerraformByHeights(heights)
	local minHeight, maxHeight = 4000, -4000

	local function DoTerra()
		for x = 0, MAP_X, SQUARE_SIZE do
			for z = 0, MAP_Z, SQUARE_SIZE do
				local h = heights[x][z]
				spSetHeightMap(x, z, h or 600)
				if h < minHeight then
					minHeight = h
				end
				if h > maxHeight then
					maxHeight = h
				end
			end
			Spring.ClearWatchDogTimer()
		end
		
		Spring.SetGameRulesParam("ground_min_override", minHeight)
		Spring.SetGameRulesParam("ground_max_override", maxHeight)
	end

	Spring.SetHeightMapFunc(DoTerra)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Floodfill handler

local function GetFloodfillHandler(defaultValue)
	local values = {}
	local influenceDist = {}
	local fillX = {}
	local fillZ = {}
	
	local ORTH_X = {-8,  0, 8, 0}
	local ORTH_Z = { 0, -8, 0, 8}
	
	local function CheckAndFillNearby(x, z, val)
		for i = 1, 4 do
			local nx, nz = x + ORTH_X[i], z + ORTH_Z[i]
			if (nx >= 0 and nz >= 0 and nx <= MAP_X and nz <= MAP_Z) and not (values[nx] and values[nx][nz]) then
				values[nx] = values[nx] or {}
				values[nx][nz] = val
				fillX[#fillX + 1] = nx
				fillZ[#fillZ + 1] = nz
			end
		end
	end
	
	local externalFuncs = {}
	
	function externalFuncs.AddHeight(x, z, val, dist)
		if (x >= 0 and z >= 0 and x <= MAP_X and z <= MAP_Z) and ((not (influenceDist[x] and influenceDist[x][z])) or (dist < influenceDist[x][z])) then
			influenceDist[x] = influenceDist[x] or {}
			influenceDist[x][z] = dist
			values[x] = values[x] or {}
			values[x][z] = val
			
			fillX[#fillX + 1] = x
			fillZ[#fillZ + 1] = z
			--Spring.MarkerAddPoint(x, 0, z, val)
		end
	end
	
	function externalFuncs.RunFloodfillAndGetValues()
		if #fillX == 0 then
			for x = 0, MAP_X, SQUARE_SIZE do
				values[x] = {}
				for z = 0, MAP_Z, SQUARE_SIZE do
					values[x][z] = defaultValue
				end
			end
		end
		while #fillX > 0 do
			local x, z = fillX[#fillX], fillZ[#fillZ]
			fillX[#fillX], fillZ[#fillZ] = nil, nil
			CheckAndFillNearby(x, z, values[x][z])
		end
		return values
	end
	
	return externalFuncs
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Process the terrain squares around edges

local function GetSlopeWidth(startWidth, endWidth, startDist, endDist, dist)
	local propDist = startDist + dist*(endDist - startDist)
	if propDist < startDist then
		propDist = startDist
	elseif propDist > endDist then
		propDist = endDist
	end
	
	local prop = (cos(((propDist - 0.15)/0.7)*pi) + 1)/2
	if propDist < 0.15 then
		prop = 1
	elseif propDist > 0.85 then
		prop = 0
	end
	
	return prop*startWidth + (1 - prop)*endWidth
end

local function MakeEdgeSlope(params, tangDist, projDist, length, startWidth, endWidth, segStartWidth, segEndWidth, startDist, endDist, overshootStart, beyondFactor)
	local maxWidth = segStartWidth
	if maxWidth < segEndWidth then
		maxWidth = segEndWidth
	end
	beyondFactor = beyondFactor or 1
	
	if tangDist < -maxWidth then
		return
	end
	if tangDist > maxWidth then
		return
	end
	
	local dist = abs(tangDist)
	local propDist = startDist + dist*(endDist - startDist)
	if propDist < startDist then
		propDist = startDist
	elseif propDist > endDist then
		propDist = endDist
	end
	
	local prop
	if propDist < 0.15 then
		prop = 1
	elseif propDist > 0.85 then
		prop = 0
	else
		prop = (cos(((propDist - 0.15) * 1.4285)*pi) + 1) * 0.5
	end
	
	local width = prop*startWidth + (1 - prop)*endWidth
	local sign = ((tangDist > 0) and 1) or -1
	
	if dist > width then
		return
	end
	
	if (projDist < 0 and (not overshootStart)) or (projDist > length) then
		width = ((projDist < 0) and segStartWidth) or segEndWidth
		local offDist = ((projDist < 0) and -projDist) or (projDist - length)
		offDist = (offDist^beyondFactor)
		local distSq = offDist*offDist + dist*dist
		if distSq > width*width then
			return
		end
		dist = sqrt(distSq)
	end
	
	local change = (1 - cos(pi*(sign*dist*0.5 + width*0.5)/width))*0.5
	if change > 0.5 then
		return false, (1 - change)
	else
		return change, false
	end
end

local function MakeWaveFuncIgloo(params, tangDist, projDist, length, startWidth, endWidth, segStartWidth, segEndWidth, startDist, endDist, overshootStart, beyondFactor)
	local maxWidth = max(segStartWidth, segEndWidth)
	beyondFactor = beyondFactor or 1
	
	if tangDist < -maxWidth then
		return
	end
	if tangDist > maxWidth then
		return
	end
	
	local dist = abs(tangDist)
	local width = GetSlopeWidth(startWidth, endWidth, startDist, endDist, projDist/length)
	local sign = ((tangDist > 0) and 1) or -1
	
	if dist > width then
		return
	end
	
	if (projDist < 0 and (not overshootStart)) or (projDist > length) then
		width = ((projDist < 0) and segStartWidth) or segEndWidth
		local offDist
		if projDist < 0 then
			offDist  = -projDist
			projDist = 0
		else
			offDist  = projDist - length
			projDist = length
		end
		offDist = (offDist^beyondFactor)
		local distSq = offDist^2 + dist^2
		if distSq > width*width then
			return
		end
		dist = sqrt(distSq)
	end
	
	local scale = 1
	if params then
		local distFactor = projDist/length
		if params.startScale and params.endScale then
			scale = params.startScale*(1 - distFactor) + params.endScale*distFactor
		end
	end
	
	local change = scale*(cos(pi*dist/width) + 1)/2
	return false, false, change
end

local function ApplyLineDistanceFunc(tierFlood, cellTier, otherTier, heightMod, waveMod, lineStart, lineEnd, HeightFunc, heightParams, startWidth, endWidth, startDist, endDist, otherClockwise, overshootStart, beyondFactor)
	-- Most of the time is spent here.
	local segStartWidth = GetSlopeWidth(startWidth, endWidth, startDist, endDist, 0)
	local segEndWidth   = GetSlopeWidth(startWidth, endWidth, startDist, endDist, 1)
	local width = max(segStartWidth, segEndWidth)
	
	if overshootStart then
		width = width*2
	end
	
	local left  = floor((min(lineStart[1], lineEnd[1]) - width)/8)*8
	local right =  ceil((max(lineStart[1], lineEnd[1]) + width)/8)*8
	local top   = floor((min(lineStart[2], lineEnd[2]) - width)/8)*8
	local bot   =  ceil((max(lineStart[2], lineEnd[2]) + width)/8)*8

	local lineVector = Subtract(lineEnd, lineStart)
	local unitProjection = Unit(lineVector)
	local unitTanget = RotateLeft(unitProjection)
	local pdx, pdz = unitProjection[1], unitProjection[2]
	local tdx, tdz = unitTanget[1], unitTanget[2]
	local ox, oz = lineStart[1], lineStart[2]
	local ex, ez = lineEnd[1], lineEnd[2]
	
	local lineLength = AbsVal(lineVector)
	
	otherClockwise = ((otherClockwise and true) or false)
	
	-- Speedups
	local vx, vz, projDist, tangDist, tangDistAbs, maxWidth
	local towardsCellTier, towardsOtherTier, waveMultMod, posIndex
	
	--SendToUnsynced("SumTimeStart", "ApplyLineDistanceFunc")
	for x = left, right, 8 do
		for z = top, bot, 8 do
			vx, vz = x - ox, z - oz
			projDist = vx*pdx + vz*pdz
			tangDist = vx*tdx + vz*tdz
			
			if not otherClockwise then
				tangDist = -tangDist
			end
			
			if tierFlood and (projDist > -8 and projDist < lineLength + 8 and tangDist > -20 and tangDist < 40) then
				tangDistAbs = abs(tangDist)
				if projDist < 0 then
					tangDistAbs = tangDistAbs - projDist*3
				elseif projDist > lineLength then
					tangDistAbs = tangDistAbs + (projDist - lineLength)*3
				end
				
				tierFlood.AddHeight(x, z, ((tangDist > 0) and cellTier) or otherTier, tangDistAbs)
			end
			
			towardsCellTier, towardsOtherTier, waveMultMod = HeightFunc(heightParams, tangDist, projDist, lineLength, startWidth, endWidth, segStartWidth, segEndWidth, startDist, endDist, overshootStart, beyondFactor)
			if towardsCellTier or towardsOtherTier or waveMultMod then
				posIndex = GetPosIndex(x, z)
				
				if towardsCellTier then
					heightMod[posIndex] = heightMod[posIndex] or {}
					if ((not heightMod[posIndex][cellTier]) or heightMod[posIndex][cellTier] < towardsCellTier) then
						heightMod[posIndex][cellTier] = towardsCellTier
					end
				end
				
				if towardsOtherTier then
					heightMod[posIndex] = heightMod[posIndex] or {}
					if ((not heightMod[posIndex][otherTier]) or heightMod[posIndex][otherTier] < towardsOtherTier) then
						heightMod[posIndex][otherTier] = towardsOtherTier
					end
				end
				
				if waveMultMod then
					if waveMultMod > 0 then
						if ((not waveMod.up[posIndex]) or waveMod.up[posIndex] < waveMultMod) then
							waveMod.up[posIndex] = waveMultMod
						end
					else
						if ((not waveMod.down[posIndex]) or waveMod.down[posIndex] > waveMultMod) then
							waveMod.down[posIndex] = waveMultMod
						end
					end
				end
			end
		end
	end
	--SendToUnsynced("SumTimeEnd", "ApplyLineDistanceFunc")
end

local function GetLineHeightModifiers(tierFlood, cellTier, otherTier, heightMod, startPoint, endPoint, width, otherClockwise)
	ApplyLineDistanceFunc(tierFlood, cellTier, otherTier, heightMod, false, startPoint, endPoint, MakeEdgeSlope, false, width, width, 0, 1, otherClockwise, true, END_FLATTENING)
end

local function GetCurveHeightModifiers(tierFlood, cellTier, otherTier, heightMod, curve, startWidth, endWidth, otherClockwise)
	local curveDist = {}
	local totalLength = 0
	for i = 1, #curve do
		curveDist[i] = totalLength
		if curve[i + 1] then
			local segmentLength = Dist(curve[i], curve[i + 1])
			totalLength = totalLength + segmentLength
		end
	end
	for i = 1, #curve - 1 do
		local startDist = curveDist[i]/totalLength
		local endDist = curveDist[i+1]/totalLength
		ApplyLineDistanceFunc(tierFlood, cellTier, otherTier, heightMod, false, curve[i], curve[i + 1], MakeEdgeSlope, heightParams, startWidth, endWidth, startDist, endDist, otherClockwise, false, END_FLATTENING)
	end
end

local function MakeMapBorderEdgeHit(tierFlood, cellTier, otherTier, heightMod, intPoint, edgeOut, otherOut, startWidth, endWidth, otherClockwise)
	local curve = {}
	for i = 1, #HIT_EDGE_POINTS do
		local randRad = (i - 1)*(#HIT_EDGE_POINTS - i)/(#HIT_EDGE_POINTS*2)
		local nextPoint = GetRandomPointInCircle(HIT_EDGE_POINTS[i], 0.04*randRad)
		curve[#curve + 1] = Add(intPoint, ChangeBasis(nextPoint, edgeOut[1], otherOut[1], edgeOut[2], otherOut[2]))
		--PointEcho(curve[#curve], i)
	end
	
	GetCurveHeightModifiers(tierFlood, cellTier, otherTier, heightMod, curve, startWidth, endWidth, otherClockwise)
end

local function GenerateEdgeMeetTerrain(tierFlood, heightMod, cells, cell, edge, otherEdge, edgeIncidence)
	local cellIndex = cell.index
	local intPoint = edge[edgeIncidence]
	
	local otherIncidence = edge.incidentEnd[otherEdge.index]
	local edgeOut  = Mult((-edgeIncidence  + 1.5)*edge.length,      edge.unit)
	local otherOut = Mult((-otherIncidence + 1.5)*otherEdge.length, otherEdge.unit)
	
	local otherClockwise = not (edge.anticlockwiseNeighbour[otherEdge.index])
	local cellTier = cell.tier
	
	if not (edge.otherFace[cellIndex]) then
		if not (otherEdge.otherFace[cellIndex]) then
			return
		end
		if cell.tier == otherEdge.otherFace[cellIndex].tier then
			return
		end
		if Dot(edgeOut, otherOut) < 0 then
			return
		end
		local otherTier = otherEdge.otherFace[cellIndex].tier
		otherClockwise = not otherClockwise
		MakeMapBorderEdgeHit(tierFlood, cellTier, otherTier, heightMod, intPoint, otherOut, edgeOut, otherEdge.terrainWidth, edge.terrainWidth, otherClockwise)
		return
	end
	
	if not (otherEdge.otherFace[cellIndex]) then
		if cell.tier == edge.otherFace[cellIndex].tier then
			return
		end
		if Dot(edgeOut, otherOut) < 0 then
			return
		end
		local otherTier = edge.otherFace[cellIndex].tier
		MakeMapBorderEdgeHit(tierFlood, cellTier, otherTier, heightMod, intPoint, edgeOut, otherOut, edge.terrainWidth, otherEdge.terrainWidth, otherClockwise)
		return
	end
	
	local topOfCliff = (cellTier > edge.otherFace[cellIndex].tier and cellTier > otherEdge.otherFace[cellIndex].tier)
	local bottomOfCliff = (cellTier < edge.otherFace[cellIndex].tier and cellTier < otherEdge.otherFace[cellIndex].tier)
	local doubleCliff = bottomOfCliff and edge.otherFace[cellIndex].tier ~= otherEdge.otherFace[cellIndex].tier
	
	if not (topOfCliff or bottomOfCliff) then
		return
	end
	
	local otherTier = (topOfCliff    and max(edge.otherFace[cellIndex].tier, otherEdge.otherFace[cellIndex].tier)) or
	                  (bottomOfCliff and min(edge.otherFace[cellIndex].tier, otherEdge.otherFace[cellIndex].tier))
	
	local curve = {}
	for i = 1, #CIRCLE_POINTS do
		local randRad = (i - 1)*(#CIRCLE_POINTS - i)/(#CIRCLE_POINTS*2)
		local nextPoint = GetRandomPointInCircle(CIRCLE_POINTS[i], 0.025*randRad)
		curve[#curve + 1] = Add(intPoint, ChangeBasis(nextPoint, edgeOut[1], otherOut[1], edgeOut[2], otherOut[2]))
		--PointEcho(curve[#curve], i)
	end
	
	--PointEcho(intPoint, "E: " .. edge.terrainWidth .. ", O: " .. otherEdge.terrainWidth .. "," .. MakeBoolString({otherClockwise}))
	GetCurveHeightModifiers(tierFlood, cellTier, otherTier, heightMod, curve, otherEdge.terrainWidth, edge.terrainWidth, otherClockwise)
end

local function GenerateEdgeTerrain(heightMod, waveMod, edge)
	ApplyLineDistanceFunc(false, edge.soloTerrainTier, edge.soloTerrainAimTier, heightMod, waveMod, edge[1], edge[2],
		edge.soloTerrainFunc, edge.soloTerrainParams, edge.soloTerrainStartWidth, edge.soloTerrainEndWidth, 0, 1, false, false, 1)
end

local function ProcessEdges(cells, edges)
	local heightMod = {}
	local waveMod = {up = {}, down = {}}
	local tierFlood = GetFloodfillHandler(cells[1].tier)
	for i = 1, #edges do
		local thisEdge = edges[i]
		for n = 1, #thisEdge.neighbours do
			local nbhd = thisEdge.neighbours[n]
			for j = 1, #nbhd do
				local otherEdge = nbhd[j]
				local sharedCell = thisEdge.incidentFace[otherEdge.index]
				if sharedCell and otherEdge.index < thisEdge.index then
					GenerateEdgeMeetTerrain(tierFlood, heightMod, cells, sharedCell, thisEdge, otherEdge, n)
				end
			end
		end
		
		if thisEdge.soloTerrainFunc then
			GenerateEdgeTerrain(heightMod, waveMod, thisEdge)
		end
	end
	
	return tierFlood, heightMod, waveMod
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Generate edge and cell structures

local function IsEdgeAdjacentToStart(edge)
	if #edge.faces >= 1 and edge.faces[1].isMainStartPos then
		return true
	elseif #edge.faces == 2 and edge.faces[2].isMainStartPos then
		return true
	end
end

local function SetCellTier(cell, tier, tierConst, tierHeight)
	cell.tier = tier
	cell.height = tier*tierHeight + tierConst
	if cell.mirror then
		cell.mirror.tier = cell.tier
		cell.mirror.height = cell.height
	end
end

local function ChangeCellTierIfHomogenousNeighbours(cell, tierConst, tierHeight, tierMin, tierMax)
	local myTier = cell.tier
	local nbhd = cell.neighbours
	for i = 1, #nbhd do
		if nbhd[i].tier ~= myTier then
			return tierMin, tierMax
		end
	end
	
	local newTier = myTier + ((random() > 0.5 and 1) or -1)
	tierMin = min(newTier, tierMin)
	tierMax = max(newTier, tierMax)
	
	SetCellTier(cell, newTier, tierConst, tierHeight)
	
	return tierMin, tierMax
end

local function FillInLargeBodiesOfWater(cells, tierConst, tierHeight, minLandTier, limit)
	local thingsToDo = true
	
	while thingsToDo do
		thingsToDo = false
		for i = 1, #cells do
			local cell = cells[i]
			if (not cell.adjacentToBorder) and cell.tier < minLandTier then
				local nearbyWaterCount = 0
				local nbhd = cell.neighbours
				for j = 1, #nbhd do
					local otherCell = nbhd[j]
					if (cell.mirror and cell.mirror.index ~= otherCell.index) and otherCell.tier < minLandTier then
						nearbyWaterCount = nearbyWaterCount + 1
						if nearbyWaterCount > limit then
							SetCellTier(cell, minLandTier, tierConst, tierHeight)
							thingsToDo = true
							break
						end
					end
				end
			end
		end
	end
end

local function GenerateCellTiers(params, cells, waveFunc)
	local averageheight = 0
	for i = 1, #cells do
		local height = waveFunc(cells[i].site[1], cells[i].site[2])
		averageheight = averageheight + height
	end
	averageheight = averageheight/#cells
	
	local std = 0
	for i = 1, #cells do
		local height = waveFunc(cells[i].site[1], cells[i].site[2])
		std = std + (height - averageheight)^2
	end
	std = sqrt(std/#cells)
	
	local waterFator = 0.2 + 0.8*random()
	
	local bucketWidth = params.bucketBase + std*params.bucketStdMult
	local tierHeight = params.tierHeight
	local tierConst = tierHeight + params.tierConst
	local tierMin, tierMax = 1000, -1000
	
	local heightOffset = -1*params.heightOffsetFactor*averageheight
	
	for i = 1, #cells do
		local cell = cells[i]
		local height = waveFunc(cell.site[1], cell.site[2])
		local tier = math.floor((height + heightOffset + bucketWidth*waterFator)/bucketWidth)
		
		if cell.adjacentToBorder and params.mapBorderTier then
			tier = params.mapBorderTier
		end
		
		SetCellTier(cell, tier, tierConst, tierHeight)
		
		tierMin = min(tier, tierMin)
		tierMax = max(tier, tierMax)
	end
	local minLandTier = ceil(-1 * tierConst / tierHeight)
	
	-- Randomly change tiers of flat areas
	for i = 1, #cells do
		local cell = cells[i]
		tierMin, tierMax = ChangeCellTierIfHomogenousNeighbours(cell, tierConst, tierHeight, tierMin, tierMax)
	end
	
	-- Cut down on water cells.
	if params.nonBorderSeaNeighbourLimit then
		FillInLargeBodiesOfWater(cells, tierConst, tierHeight, minLandTier, params.nonBorderSeaNeighbourLimit)
	end
	
	-- Make water more accessible.
	for i = 1, #cells do
		local cell = cells[i]
		if cell.tier == minLandTier + 1 then
			local nbhd = cell.neighbours
			local nbhdAverage = cell.tier
			local nbhdCount = 1
			local hasSea = false
			for j = 1, #nbhd do
				nbhdAverage = nbhdAverage + nbhd[j].tier
				nbhdCount = nbhdCount + 1
				if nbhd[j].tier < minLandTier then
					hasSea = true
				end
			end
			if hasSea then
				nbhdAverage = nbhdAverage / nbhdCount
				if nbhdAverage > minLandTier + 0.5 and nbhdAverage < minLandTier + 1.5 and random() < 0.9 then
					SetCellTier(cell, minLandTier, tierConst, tierHeight)
				end
			end
		end
	end
	
	return tierConst, tierHeight, tierMin, tierMax, minLandTier
end

local function SetEdgePassability(params, edge, minLandTier)
	edge.tierDiff = (edge.faces and (#edge.faces == 2) and abs(edge.faces[1].tier - edge.faces[2].tier)) or 0
	edge.highTier = edge.faces and (#edge.faces == 2) and max(edge.faces[1].tier, edge.faces[2].tier)
	edge.lowTier = edge.faces and (#edge.faces == 2) and min(edge.faces[1].tier, edge.faces[2].tier)
	if not edge.highTier then
		edge.highTier = edge.faces[1].tier
		edge.lowTier = edge.faces[1].tier
	end
	edge.landPass = (edge.lowTier >= minLandTier)
	edge.underwater = (edge.highTier < minLandTier)
	
	if edge.tierDiff == 0 then
		edge.vehPass = true
		edge.botPass = true
		edge.terrainWidth = 20
		return
	end
	
	local impassCount = 0
	local matchCount  = 0
	for n = 1, 2 do
		local nbhd = edge.neighbours[n]
		for i = 1, #nbhd do
			local otherEdge = nbhd[i]
			if otherEdge.tierDiff ~= 0 and otherEdge.highTier == edge.highTier then
				matchCount = matchCount + 1
				if otherEdge.terrainWidth < 100 then
					impassCount = impassCount + 1
				end
			end
		end
	end
	
	local pointAtBorder = (edge.faces[1].adjacentToBorder and edge.faces[2] and edge.faces[2].adjacentToBorder)
	
	if edge.underwater or (edge.lowTier < minLandTier and edge.tierDiff <= 1) then
		-- Always make a ramp.
		edge.terrainWidth = params.rampWidth
	elseif edge.lowTier < minLandTier and edge.tierDiff >= 2 then
		-- Make a ramp 95% of the time
		edge.terrainWidth = ((0.95 < random()) and params.rampWidth) or params.cliffWidth
	elseif edge.length < 600 and ((impassCount == 0) or (matchCount*0.7 - impassCount >= 0)) and not IsEdgeAdjacentToStart(edge) and random() < ((pointAtBorder and 0.3) or 0.75) then
		-- Make a cliff on short high tier difference edges
		edge.terrainWidth = ((impassCount == 0) and params.rampWidth) or params.cliffWidth
	elseif edge.tierDiff <= 1 then
		if IsEdgeAdjacentToStart(edge) then
			edge.terrainWidth = params.rampWidth
		elseif pointAtBorder then
			edge.terrainWidth = ((0.85 < random()) and params.rampWidth) or params.cliffWidth
		else
			edge.terrainWidth = ((0.65 < random()) and params.rampWidth) or params.cliffWidth
		end
	else
		-- Make a ramp 40% of the time.
		edge.terrainWidth = ((0.4 < random()) and params.rampWidth) or params.cliffWidth
	end
	
	-- Make a veh-pathable mega ramp.
	if edge.terrainWidth >= params.rampWidth and edge.tierDiff <= 3 then
		if edge.tierDiff == 2 and edge.lowTier < minLandTier and random() < 0.95 then
			edge.terrainWidth = edge.terrainWidth*edge.tierDiff*1.4
		else
			if edge.tierDiff == 2 and (random() < 0.65 + ((pointAtBorder and 0.25) or 0)) then
				edge.terrainWidth = edge.terrainWidth*edge.tierDiff*1.4
			end
			if edge.tierDiff == 3 and (random() < 0.4) then
				edge.terrainWidth = edge.terrainWidth*edge.tierDiff*1.4
			end
		end
	end
	
	if edge.terrainWidth <= params.cliffWidth and not IsEdgeAdjacentToStart(edge) then
		edge.cliffEdge = true
		edge.terrainWidth = edge.terrainWidth*edge.tierDiff
	end
	
	if (edge.terrainWidth/edge.tierDiff <= params.cliffWidth) or (edge.tierDiff > 3) then
		edge.vehPass = false
		edge.botPass = false
	elseif (edge.terrainWidth/edge.tierDiff >= params.rampWidth) then
		edge.vehPass = true
		edge.botPass = true
	else
		edge.vehPass = false
		edge.botPass = true
	end
end

local function SetEdgeSoloTerrain(params, edge)
	if edge.tierDiff > 1 or edge.underwater then
		return
	end
	
	if IsEdgeAdjacentToStart(edge) then
		return
	end
	
	if not params.borderIgloos then
		if #edge.faces == 1 then
			return
		end
		if edge.faces[1].adjacentToBorder and edge.faces[2].adjacentToBorder then
			return
		end
	end
	
	local nonFlatNeighbours = 0
	local lowNeighbourTier = edge.lowTier
	local highNeighbourTier = edge.highTier
	local thresholdLength = params.flatNeighbourIgloo
	local nearCliff = false
	local endpointOnStart = {}
	for n = 1, 2 do
		local nbhd = edge.neighbours[n]
		for i = 1, #nbhd do
			local otherEdge = nbhd[i]
			if otherEdge.tierDiff > 1 then
				thresholdLength = params.highDiffNeighbourIgloo
				nonFlatNeighbours = nonFlatNeighbours + 1
			elseif otherEdge.tierDiff > 0 then
				thresholdLength = params.lowDiffNeighbourIgloo
				nonFlatNeighbours = nonFlatNeighbours + 1
			end
			lowNeighbourTier = min(lowNeighbourTier, otherEdge.lowTier)
			highNeighbourTier = max(highNeighbourTier, otherEdge.highTier)
			
			endpointOnStart[n] = endpointOnStart[n] or IsEdgeAdjacentToStart(otherEdge)
			
			if otherEdge.cliffEdge then
				nearCliff = true
			end
		end
	end
	
	if nearCliff and #edge.faces == 1 then
		return
	end
	
	-- Do not block off a gap.
	if nonFlatNeighbours > 2 and edge.tierDiff == 0 then
		return
	end
	
	local fullyFlat = (nonFlatNeighbours == 0 and edge.tierDiff == 0)
	if edge.tierDiff > 0 then
		thresholdLength = thresholdLength*0.5
	end
	
	local effectMult = 1
	if edge.length > thresholdLength then
		if edge.length > 2*thresholdLength then
			return
		end
		local effectMultOffset = (fullyFlat and 0.5) or 0
		effectMult = effectMultOffset + (1 - effectMultOffset)*(edge.length - thresholdLength)/thresholdLength
	end
	
	effectMult = effectMult * (0.8 + 0.5*random())
	
	-- TODO detect this.
	--edge.vehPass = false
	--edge.botPass = false
	
	local midDist = Dist(GetMidpoint(edge[1], edge[2]), {MAP_X*0.5, MAP_Z*0.5})
	
	local otherTier = edge.lowTier + 1
	local width = 0.21*edge.length + 60 + 160*random()
	
	local startScale = (random()*0.8 - 0.35)*params.iglooMult
	local endScaleChange = 0.42*random() - 0.21
	if edge.tierDiff == 0 and (
			(nonFlatNeighbours == 0 and random() < 0.4*params.iglooMult) or 
			(nonFlatNeighbours == 1 and random() < 0.28*params.iglooMult) or 
			(random() < 0.04*params.iglooMult)) then
		local sign = ((startScale > 0) and 1) or -1
		width = width*0.9 + 40
		startScale = 0.3*sign + 0.8*startScale
		startScale = startScale*(0.9 + math.min(0.5, width*0.0004))
	end
	
	if random() < 0.15*params.iglooMult and startScale < 0.6 then
		startScale = startScale*1.2
	end
	
	local iglooTier = edge.lowTier
	-- Add a big igloo to flatish areas, especially the middle.
	if highNeighbourTier - lowNeighbourTier <= 1 and (midDist < 80 or random() < 0.02 + 0.4*max(0, min(1, 1 - midDist*0.0005))) then
		local sign = ((startScale > 0) and 1) or -1
		if abs(startScale) < 0.4 + 0.15*random() then
			startScale = 0.5*sign + 1.1*startScale
		end
		width = width + 20
		effectMult = effectMult + 0.4
	elseif abs(startScale*effectMult) < 0.08 then
		-- Small scales don't do much, ignore for speed
		return
	end
	
	edge.soloTerrainFunc       = MakeWaveFuncIgloo
	edge.soloTerrainTier       = edge.lowTier
	edge.soloTerrainAimTier    = otherTier
	edge.soloTerrainStartWidth = width
	edge.soloTerrainEndWidth   = math.max(100, width*(0.5 + random()) + (1.8*random() - 1)*(6 + 0.2*edge.length))
	
	if endpointOnStart[1] and edge.soloTerrainStartWidth > 200 then
		edge.soloTerrainStartWidth = 200
	end
	if endpointOnStart[2] and edge.soloTerrainEndWidth > 200 then
		edge.soloTerrainEndWidth = 200
	end
	
	if edge.length < 50 + 50*random() then
		endScaleChange = endScaleChange*0.2
	end
	
	-- Prevent long large and high igloos.
	if edge.length > 220 and abs(1.15*startScale*effectMult) > width/edge.length then
		effectMult = effectMult*(width/edge.length)/abs(1.15*startScale*effectMult)
	end
	
	effectMult = effectMult*params.iglooHeightMult
	edge.soloTerrainParams = {
		startScale = startScale*effectMult,
		endScale = (startScale + endScaleChange)*effectMult,
	}
	
	if edge.selfMirror then
		edge.soloTerrainStartWidth = edge.soloTerrainEndWidth
		edge.soloTerrainParams.startScale = edge.soloTerrainParams.endScale
		edge.soloTerrainTier = edge.soloTerrainAimTier
	end
	--LineEcho(edge, "Make Igloo " .. 
	--	edge.soloTerrainTier .. ", " ..
	--	edge.soloTerrainAimTier .. ", " ..
	--	edge.soloTerrainStartWidth .. ", " ..
	--	edge.soloTerrainEndWidth .. ", " ..
	--	edge.soloTerrainParams.startScale .. ", " ..
	--	edge.soloTerrainParams.endScale .. ", " ..
	--	"."
	--)
	
	return otherTier
end

local function MirrorEdgePassability(edge)
	local mirror = edge.mirror
	if not mirror then
		return
	end

	mirror.terrainWidth = edge.terrainWidth
	mirror.tierDiff     = edge.tierDiff
	mirror.cliffEdge    = edge.cliffEdge
	mirror.lowTier      = edge.lowTier
	mirror.highTier     = edge.highTier
	mirror.vehPass      = edge.vehPass
	mirror.botPass      = edge.botPass
	mirror.landPass     = edge.landPass
	
	mirror.soloTerrainStartWidth = edge.soloTerrainStartWidth
	mirror.soloTerrainEndWidth   = edge.soloTerrainEndWidth
	mirror.soloTerrainTier       = edge.soloTerrainTier
	mirror.soloTerrainAimTier    = edge.soloTerrainAimTier
	mirror.soloTerrainFunc       = edge.soloTerrainFunc
	mirror.soloTerrainParams     = edge.soloTerrainParams
end

local function GenerateEdgePassability(params, edgesSorted, tierMin, tierMax, minLandTier)
	-- Set boundaries between cells of distinct tiers
	-- Smallest to largest
	for i = #edgesSorted, 1, -1 do
		local thisEdge = edgesSorted[i]
		if thisEdge.firstMirror then
			SetEdgePassability(params, thisEdge, minLandTier)
			MirrorEdgePassability(thisEdge)
		end
	end
	
	-- Set boundaries for short edges that exist in flat areas.
	-- Smallest to largest
	for i = #edgesSorted, 1, -1 do
		local thisEdge = edgesSorted[i]
		if thisEdge.firstMirror then
			local tierExtent = SetEdgeSoloTerrain(params, thisEdge, minLandTier)
			MirrorEdgePassability(thisEdge)
			
			if tierExtent then
				tierMin = min(tierExtent, tierMin)
				tierMax = max(tierExtent, tierMax)
			end
		end
	end
	
	return tierMin, tierMax
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Heightmap application

local function GetHeightMod(tierMin, tierMax, posTier, posChange, x, z)
	if not posChange then
		return 0
	end
	
	local tierChange = 0
	local recentChange = false
	for tier = tierMax, posTier + 1, -1 do
		if posChange[tier] then
			recentChange = (recentChange and max(recentChange, posChange[tier])) or posChange[tier]
			tierChange = tierChange + recentChange
		elseif recentChange then
			tierChange = tierChange + recentChange
		end
	end
	
	recentChange = false
	for tier = tierMin, posTier - 1 do
		if posChange[tier] then
			recentChange = (recentChange and min(recentChange, -posChange[tier])) or -posChange[tier]
			tierChange = tierChange + recentChange
		elseif recentChange then
			tierChange = tierChange + recentChange
		end
	end
	
	return tierChange
end

local function ApplyHeightModifiers(tierConst, tierHeight, tierMin, tierMax, tiers, heightMod, waveMod, waveFunc, waveMult)
	local heights = {}
	
	for x = 0, MAP_X, SQUARE_SIZE do
		heights[x] = {}
		for z = 0, MAP_Z, SQUARE_SIZE do
			local posIndex = GetPosIndex(x, z)
			local baseHeight = tierConst + tierHeight*tiers[x][z]
			local change = GetHeightMod(tierMin, tierMax, tiers[x][z], heightMod[posIndex], x, z)
			local waveHeight = 0
			if waveFunc then
				local upmod = (waveMod and waveMod.up[posIndex]) or 0
				local downmod = (waveMod and waveMod.down[posIndex]) or 0
				waveHeight = waveFunc(x, z)*(waveMult + upmod + downmod)
			end
			
			heights[x][z] = baseHeight + waveHeight + tierHeight*change
		end
	end
	
	return heights
end

local function ApplyHeightSmooth(rawHeights, filter)
	local heights = {}
	local filterSum = 0
	for i = 1, #filter do
		filterSum = filterSum + filter[i][3]
	end
	local filterMult = 1/filterSum
	
	for x = 0, MAP_X, SQUARE_SIZE do
		heights[x] = {}
		for z = 0, MAP_Z, SQUARE_SIZE do
			local thisHeight = rawHeights[x][z]
			local heightSum = 0
			for i = 1, #filter do
				local sx, sz = x + filter[i][1], z + filter[i][2]
				heightSum = heightSum + ((rawHeights[sx] and rawHeights[sx][sz]) or thisHeight)*filter[i][3]
			end
			heights[x][z] = heightSum*filterMult
		end
	end
	
	return heights
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Start positions

local function EstimateHeightDiff(mid, checkRadius, waveFunc, waveMult)
	local sampleCount = 25
	local heightSum = 0
	local maxHeight, minHeight
	for i = 1, sampleCount do
		local pos = GetRandomPointInCircle(mid, checkRadius, 50)
		local x, z = floor((pos[1] + 4)/8)*8, floor((pos[2] + 4)/8)*8
		
		local posHeight = waveFunc(x, z)*waveMult
		heightSum = heightSum + posHeight
		if (not minHeight) or (posHeight < minHeight) then
			minHeight = posHeight
		end
		if (not maxHeight) or (posHeight > maxHeight) then
			maxHeight = posHeight
		end
	end
	
	local heightAverage = heightSum/sampleCount
	local cheapDeviation = min(maxHeight - heightAverage, heightAverage - minHeight)/(0.001 + maxHeight - minHeight)
	return (maxHeight - minHeight), cheapDeviation
end

local function SetStartboxDataFromPolygon(poly)
	local mirrorBox = {}
	for i = 1, #poly do
		mirrorBox[#mirrorBox + 1] = ApplyRotSymmetry(poly[i])
	end
	
	GG.mapgen_startBoxes = {}
	GG.mapgen_startBoxes[1] = Spring.Utilities.CopyTable(poly)
	GG.mapgen_startBoxes[2] = Spring.Utilities.CopyTable(mirrorBox)
end

local STARTBOX_WIDTH = 600

local function SetStartAndModifyCellTiers_SetPoint(cells, edgesSorted, waveFunc, waveMult, minLandTier, params)
	local startCell = GetClosestCell(params.startPoint, cells)
	SetStartboxDataFromPolygon(GetCellVertices(startCell))
	
	-- Set start cell parameters
	startCell.isMainStartPos = true
	startCell.isStartPos = true
	startCell.mirror.isMainStartPos = startCell.isMainStartPos
	startCell.mirror.isStartPos = startCell.isStartPos
	
	startCell.mexMidpoint = GetMidpoint(startCell.averageMid, params.startPoint)
	startCell.mirror.mexMidpoint = startCell.mexMidpoint
	
	local averageTier = math.max(minLandTier, startCell.tier)
	local averageCount = 1
	for i = 1, #startCell.neighbours do
		averageTier = averageTier + startCell.neighbours[i].tier
		averageCount = averageCount + 1
	end
	startCell.tier = floor(averageTier / averageCount + 0.25 + random()*0.5)
	
	if startCell.tier < minLandTier then
		startCell.tier = minLandTier
	end
	startCell.mirror.tier = startCell.tier
	
	return startCell
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Metal Spots

local function EdgePassable(edge, needVeh, needBot, needLand)
	if needVeh and not edge.vehPass then
		return false
	end
	if needBot and not edge.botPass then
		return false
	end
	if needLand and not edge.landPass then
		return false
	end
	return true
end

local function GetPathDistances(cells, startCell, distName, needVeh, needBot, needLand)
	local seenCells = {}
	local checkCells = {}
	
	local checkIndex = 1
	local endIndex = 1
	
	seenCells[startCell.index] = true
	checkCells[checkIndex] = startCell
	startCell[distName] = 0
	
	while checkCells[checkIndex] do
		local thisCell = checkCells[checkIndex]
		local cellIndex = thisCell.index
		local edges = thisCell.edges
		for i = 1, #edges do
			local thisEdge = edges[i]
			local otherCell = thisEdge.otherFace[cellIndex]
			if otherCell and EdgePassable(thisEdge, needVeh, needBot, needLand) and not seenCells[otherCell.index] then
				otherCell[distName] = thisCell[distName] + 1
				endIndex = endIndex + 1
				checkCells[endIndex] = otherCell
				seenCells[otherCell.index] = true
			end
		end
		
		checkIndex = checkIndex + 1
	end
end

local function GetStraightDistances(cells, startCell, distName)
	local startSite = startCell.site
	for i = 1, #cells do
		local thisCell = cells[i]
		thisCell[distName] = Dist(thisCell.site, startSite)
	end
end

local function HasTierDiff(edge)
	return (edge.tierDiff ~= 0)
end

local function ReduceMexAllocation(cell, totalMexAlloc, allocFactor)
	cell = (cell.firstMirror and cell) or cell.mirror
	if not cell.mexAlloc then
		return totalMexAlloc
	end
	local allocChange = cell.mexAlloc*(1 - allocFactor)
	cell.mexAlloc = cell.mexAlloc - allocChange
	return totalMexAlloc - allocChange
end

local function AllocateMetalSpots(cells, edges, minLandTier, startCell, params)
	GetPathDistances(cells, startCell, "landBotDist", false, true, true)
	GetStraightDistances(cells, startCell, "straightDist")
	
	local isTeamGame = Spring.Utilities.Gametype and Spring.Utilities.Gametype.isTeams and Spring.Utilities.Gametype.isTeams()
	local isBigTeamGame = Spring.Utilities.Gametype and Spring.Utilities.Gametype.isTeams and Spring.Utilities.Gametype.isBigTeams()
	local wantedMexes = params.baseMexesPerSide + floor(random()*2) + ((isTeamGame and 1) or 0) + ((isBigTeamGame and 2) or 0)
	
	local minPathDiff, maxPathDiff
	local minDistSum, maxDistSum
	local maxCellDist
	for i = 1, #cells do
		local thisCell = cells[i]
		local mirror = thisCell.mirror
		if mirror then
			if thisCell.landBotDist and mirror.landBotDist then
				local pathDiff = abs(thisCell.landBotDist - mirror.landBotDist)
				if (not minPathDiff) or (pathDiff < minPathDiff) then
					minPathDiff = pathDiff
				end
				if (not maxPathDiff) or (pathDiff > maxPathDiff) then
					maxPathDiff = pathDiff
				end
			end
			
			local smallerStartDist = max(thisCell.straightDist, mirror.straightDist)
			local distSum = thisCell.straightDist + mirror.straightDist
			if (not minDistSum) or (distSum < minDistSum) then
				minDistSum = distSum
			end
			if (not maxDistSum) or (distSum > maxDistSum) then
				maxDistSum = distSum
			end
			if (not maxCellDist) or (smallerStartDist > maxCellDist) then
				maxCellDist = smallerStartDist
			end
		end
	end
	
	if not minPathDiff then
		minPathDiff = 0
	end
	if (not maxPathDiff) or (maxPathDiff == minPathDiff) then
		maxPathDiff = minPathDiff + 1
	end
	if not minDistSum then
		minDistSum = 3000
	end
	if not maxDistSum then
		maxDistSum = 6000
	end
	if not maxCellDist then
		maxCellDist = 6000
	end
	
	-- Force some mid mexes.
	for i = 1, params.forcedMidMexes do
		local pos = GetRandomPointInCircle({MAP_X/2, MAP_Z/2}, params.forcedMinMexRadius)
		local closeCell = GetClosestCell(pos, cells)
		closeCell.metalSpots = (closeCell.metalSpots or 0) + 1
		closeCell.metalDist = ((random() > 0.6 and 600) or 180)
		closeCell.mirror.metalSpots = closeCell.metalSpots
		closeCell.mirror.metalDist = closeCell.metalDist
		wantedMexes = wantedMexes - 1
	end
	
	local totalMexAlloc = 0
	for i = 1, #cells do
		local thisCell = cells[i]
		if thisCell.firstMirror and (thisCell.metalSpots or 0) == 0 then
			local mirror = thisCell.mirror
			local diffDist = false
			local minBotDist = false
			
			if thisCell.landBotDist and mirror and mirror.landBotDist then
				thisCell.startPathFactor = (abs(thisCell.landBotDist - mirror.landBotDist) - minPathDiff)/(maxPathDiff - minPathDiff)
				minBotDist = min(thisCell.landBotDist, (mirror and mirror.landBotDist) or mirror.landBotDist)
				diffDist = abs(thisCell.landBotDist - mirror.landBotDist)
			else
				thisCell.startPathFactor = 0
				thisCell.unreachable = true
			end
			
			thisCell.startDistFactor = (thisCell.straightDist + mirror.straightDist - minDistSum)/(maxDistSum - minDistSum)
			thisCell.closeDistFactor = min(thisCell.straightDist, mirror.straightDist)/maxCellDist
			
			if thisCell.tier < minLandTier then
				thisCell.mexAlloc = 0
			elseif thisCell.isMainStartPos then
				thisCell.metalSpots = 3
				thisCell.metalDist = 220
				wantedMexes = wantedMexes - thisCell.metalSpots
			else
				thisCell.mexAlloc = thisCell.startPathFactor*0.6 + thisCell.startDistFactor*0.4 + thisCell.closeDistFactor*0.95 - 0.1
				if diffDist and diffDist <= 1 then
					thisCell.mexAlloc = thisCell.mexAlloc + 0.5
				end
				if minBotDist == 1 then
					thisCell.mexAlloc = thisCell.mexAlloc + 0.2
					thisCell.adjacentToStart = true
				end
				if thisCell.adjacentToBorder then
					thisCell.mexAlloc = thisCell.mexAlloc + 0.5
				end
				if thisCell.adjacentToCorner then
					thisCell.mexAlloc = thisCell.mexAlloc - 0.1
				end
				if thisCell.unreachable then
					thisCell.mexAlloc = thisCell.mexAlloc*0.02
				end
				
				thisCell.mexAlloc = max(0, thisCell.mexAlloc or 0)
				totalMexAlloc = totalMexAlloc + thisCell.mexAlloc
			end
			
			if isTeamGame and thisCell.isAuxStartPos then
				thisCell.metalSpots = ((isBigTeamGame and 2) or 1)
				wantedMexes = wantedMexes - thisCell.metalSpots
			end
		end
	end
	
	while wantedMexes > 0 do
		local mexCell = cells[random(1, #cells)]
		local randAllocateSum = random()*totalMexAlloc
		for i = 1, #cells do
			local thisCell = cells[i]
			if thisCell.firstMirror then
				if thisCell.mexAlloc and (randAllocateSum < thisCell.mexAlloc) then
					mexCell = thisCell
					--PointEcho(thisCell.site, "Cell picked: " .. thisCell.mexAlloc)
					break
				else
					randAllocateSum = randAllocateSum - (thisCell.mexAlloc or 0)
				end
			end
		end
		
		local allocChange = mexCell.mexAlloc or 0
		local mexAssignment = 1
		local distBetweenMirror = mexCell.mirror and Dist(mexCell.averageMid, mexCell.mirror.averageMid)
		if (not mexCell.adjacentToStart) and (mexCell.mirror and distBetweenMirror > 2000) then
			local doubleChance = max(0.02, min(0.3, mexCell.mexAlloc*0.2))
			if mexCell.mexAlloc and (random() < doubleChance) and (not mexCell.unreachable) then
				mexAssignment = 2
			end
		end
		
		totalMexAlloc = ReduceMexAllocation(mexCell, totalMexAlloc, 0)
		local neighbourFactor = 0.45
		for i = 1, #mexCell.neighbours do
			totalMexAlloc = ReduceMexAllocation(mexCell.neighbours[i], totalMexAlloc, neighbourFactor)
		end
		mexCell.metalSpots = (mexCell.metalSpots or 0) + mexAssignment
		if mexAssignment == 2 then
			mexCell.metalDist = 180
		elseif (mexCell.mirror and distBetweenMirror > 2000) then
			mexCell.metalDist = ((random() > 0.1 and 680) or 180) -- Whether to allow grouped mexes.
		else
			local dist = (mexCell.mirror and distBetweenMirror)
			mexCell.metalDist = 680 + 280*(1 - dist/2000)
		end
		
		wantedMexes = wantedMexes - mexAssignment
	end
	
	--for i = 1, #cells do
	--	local thisCell = cells[i]
	--	local text = (thisCell.landBotDist or "NONE") .. ", " .. (thisCell.mirror.landBotDist or "NONE")
	--	PointEcho(thisCell.averageMid, "Dist: " .. text .. (((thisCell.unreachable or thisCell.mirror.unreachable) and ", UNREACHABLE") or ""))
	--end
end

local function GetRandomMexPos(mexes, smoothHeights, avoidDist, pos)
	local placeRadius = 120
	local placeIncrement = 15
	
	local tries = 0
	while tries < 250 do
		local randomPoint = GetRandomPointInCircle(pos, placeRadius, 150)
		local _, pointDist = GetClosestPoint(randomPoint, mexes)
		if (not pointDist) or (avoidDist < pointDist) then
			if SufficientlyFlat(randomPoint, smoothHeights, 52, 11, 3) then
				return randomPoint
			end
		end
		placeRadius = placeRadius + placeIncrement
		tries = tries + 1
	end
	
	return false
end

local function PlaceMex(mexes, smoothHeights, avoidDist, pos)
	local mexPos = GetRandomMexPos(mexes, smoothHeights, avoidDist, pos)
	if not mexPos then
		return
	end
	local mirrorMexPos = ApplyRotSymmetry(mexPos)
	local mexValue = ((megaMex and 4) or 2)
	
	if Dist(mexPos, mirrorMexPos) > 120 then
		GG.mapgen_mexList = GG.mapgen_mexList or {}
		
		mexes[#mexes + 1] = mexPos
		mexes[#mexes + 1] = mirrorMexPos
		
		GG.mapgen_mexList[#GG.mapgen_mexList + 1] = {x = mexPos[1], z = mexPos[2], metal = mexValue}
		GG.mapgen_mexList[#GG.mapgen_mexList + 1] = {x = mirrorMexPos[1], z = mirrorMexPos[2], metal = mexValue}
	else
		mexPos = {MID_X, MID_Z}
		mexes[#mexes + 1] = mexPos
		GG.mapgen_mexList = GG.mapgen_mexList or {}
		GG.mapgen_mexList[#GG.mapgen_mexList + 1] = {x = mexPos[1], z = mexPos[2], metal = mexValue}
	end
end

local function PlaceMetalSpots(cells, smoothHeights, params)
	local mexes = {}
	-- Add predefined mexes first.
	for i = 1, #params.predefinedMexes do
		PlaceMex(mexes, smoothHeights, 280, params.predefinedMexes[i])
	end
	
	-- Add cell mexes
	for i = 1, #cells do
		local thisCell = cells[i]
		if thisCell.firstMirror then
			if thisCell.megaMex then
				PlaceMex(mexes, smoothHeights, thisCell.metalDist, thisCell.mexMidpoint or thisCell.averageMid)
			elseif thisCell.metalSpots then
				for j = 1, thisCell.metalSpots do
					PlaceMex(mexes, smoothHeights, thisCell.metalDist, thisCell.mexMidpoint or thisCell.averageMid)
				end
			end
		end
	end
	
	-- Add mexes to very empty areas of the map.
	for i = 1, params.emptyAreaMexes do
		local point = GetRandomMapCoord(params.emptyAreaMexRadius, mexes, 120, false, 1.1)
		PlaceMex(mexes, smoothHeights, params.emptyAreaMexRadius - 350, point)
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Trees

local TREE_DENSITY_SIZE = 512

local function SetTreeDensity(cells)
	for i = 1, #cells do
		local thisCell = cells[i]
		if thisCell.firstMirror then
			if thisCell.isMainStartPos then
				thisCell.treeDensity = max(0, random()*0.1 - 0.6)
			elseif thisCell.isAuxStartPos then
				thisCell.treeDensity = max(0, random()*0.1 - 0.2)
			elseif random() < 0.15 then
				thisCell.treeDensity = 0.9 + 0.8*random()
			elseif random() < 0.55 then
				thisCell.treeDensity = 0.3 + 0.6*random()
			else
				thisCell.treeDensity = 0.05 + 0.3*random()
			end
			if thisCell.mirror then
				thisCell.mirror.treeDensity = thisCell.treeDensity
			end
		end
	end
end

local function ApplyTreeDensity(cells)
	local densityMap = {}
	local point = {}
	for x = TREE_DENSITY_SIZE/2, MAP_X, TREE_DENSITY_SIZE do
		densityMap[x] = {}
		point[1] = x
		for z = TREE_DENSITY_SIZE/2, MAP_Z, TREE_DENSITY_SIZE do
			point[2] = z
			local closeCell = GetClosestCell(point, cells)
			if closeCell then
				densityMap[x][z] = (closeCell.treeDensity or 0)
			end
		end
	end
	
	GG.mapgen_treeDensityMap = densityMap
	GG.mapgen_treeDensitySize = TREE_DENSITY_SIZE
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Large logical chunks

local function GetSeed()
	local mapOpts = Spring.GetMapOptions()
	if mapOpts and mapOpts.seed and tonumber(mapOpts.seed) ~= 0 then
		return tonumber(mapOpts.seed)
	end
	
	local modOpts = Spring.GetModOptions()
	if modOpts and modOpts.mapgen_seed and tonumber(modOpts.mapgen_seed) ~= 0 then
		return tonumber(modOpts.mapgen_seed)
	end
	
	return random(1, 10000000)
end

local function GetWaveHeightMult(tierMin, tierMax, params)
	local tierDiff = (tierMax - tierMin)
	local waveMult = params.waveDirectMult/(tierDiff + 1.5)
	return waveMult
end

local function GetTerrainStructure(params)
	local waveFunc = GetTerrainWaveFunction(params)
	--TerraformByFunc(waveFunc)
	EchoProgress("Wave generation complete")
	
	local cells, edges = GetVoronoi(params)
	EchoProgress("Voronoi generation complete")
	
	local edgesSorted = Spring.Utilities.CopyTable(edges, false)
	table.sort(edgesSorted, CompareLength)
	
	local tierConst, tierHeight, tierMin, tierMax, minLandTier = GenerateCellTiers(params, cells, waveFunc)
	
	local startCell = params.StartPositionFunc(cells, edgesSorted, waveFunc, GetWaveHeightMult(tierMin, tierMax, params), minLandTier, params)
	
	--for i = 1, #cells do
	--	PointEcho(cells[i].site, "Tier " .. cells[i].tier) 
	--end
	
	tierMin, tierMax = GenerateEdgePassability(params, edgesSorted, tierMin, tierMax, minLandTier)
	AllocateMetalSpots(cells, edges, minLandTier, startCell, params)
	SetTreeDensity(cells)
	
	EchoProgress("Terrain structure complete")

	return cells, edges, edgesSorted, heightMod, waveFunc, tiers, tierConst, tierHeight, tierMin, tierMax, startCell
end

local function MakeHeightmap(cells, edges, heightMod, waveFunc, tiers, tierConst, tierHeight, tierMin, tierMax, params)
	local tierFlood, heightMod, waveMod = ProcessEdges(cells, edges)
	EchoProgress("Edge processing complete")
	EchoProgress("ApplyLineDistanceFunc")
	
	local tiers = tierFlood.RunFloodfillAndGetValues()
	EchoProgress("Tier propagation complete")

	local heights = ApplyHeightModifiers(tierConst, tierHeight, tierMin, tierMax, tiers, heightMod, waveMod, waveFunc, GetWaveHeightMult(tierMin, tierMax, params))
	EchoProgress("Height application complete")
	
	local smoothHeights = ApplyHeightSmooth(heights, smoothFilter)
	EchoProgress("Smoothing complete")

	TerraformByHeights(smoothHeights)
	GG.mapgen_origHeight = smoothHeights
	EchoProgress("Map terrain complete")
	
	return smoothHeights
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Callins

-- Gameframe draw debug
local toDrawEdges = nil
local waitCount = 0

local newParams = {
	startPoint = {550, 550},
	startPointSize = 750,
	points = 21,
	midPoints = 3,
	midPointRadius = 900,
	midPointSpace = 180,
	minSpace = 150,
	maxSpace = 350,
	pointSplitRadius = 510,
	edgeBias = 1.35,
	flatNeighbourIgloo = 680,
	lowDiffNeighbourIgloo = 540,
	highDiffNeighbourIgloo = 320,
	cliffWidth = 36,
	rampWidth  = 230,
	tierHeight = 100,
	tierConst = 32,
	generalWaveMod = 0.8,
	iglooMult = 0.92,
	iglooHeightMult = 0.9,
	waveDirectMult = 0.3,
	bucketBase = 52,
	bucketStdMult = 0.55,
	heightOffsetFactor = 0.9,
	mapBorderTier = false,
	nonBorderSeaNeighbourLimit = 0, -- Only allow lone lakes.
	StartPositionFunc = SetStartAndModifyCellTiers_SetPoint,
	borderIgloos = true,
	--forceFord = true, -- To implement
	baseMexesPerSide = 11,
	forcedMidMexes = 1,
	forcedMinMexRadius = 1000,
	emptyAreaMexes = 2,
	emptyAreaMexRadius = 1150,
	predefinedMexes = {
		{1500, 550},
		{550, 1500},
	},
}

local function MakeMap()
	local params = newParams
	local randomSeed = GetSeed()
	--randomSeed = 31548
	math.randomseed(randomSeed)

	Spring.SetGameRulesParam("typemap", "temperate2")
	Spring.SetGameRulesParam("mapgen_enabled", 1)
	
	if DISABLE_TERRAIN_GENERATOR then
		GG.mapgen_mexList = {}
		GG.mapgen_startBoxes = {}
		return
	end
	
	EchoProgress("Map Terrain Generation")
	Spring.Echo("Random Seed", randomSeed)
	
	local cells, edges, edgesSorted, heightMod, waveFunc, tiers, tierConst, tierHeight, tierMin, tierMax, startCell = GetTerrainStructure(params)
	toDrawEdges = DRAW_EDGES and edges
	
	local smoothHeights = MakeHeightmap(cells, edges, heightMod, waveFunc, tiers, tierConst, tierHeight, tierMin, tierMax, params)
	
	ApplyTreeDensity(cells)
	PlaceMetalSpots(cells, smoothHeights, params)
	
	EchoProgress("Metal generation complete")
end

local timeMap = TIME_MAP_GEN
function gadget:Initialize()
	if not timeMap then
		MakeMap()
	end
end

function gadget:GameFrame()
	if timeMap then
		MakeMap()
		timeMap = false
	end
	if not toDrawEdges then
		return
	end
	
	waitCount = (waitCount or 0) + 1
	if waitCount < 40 then
		return
	end
	
	--local middle = {MID_X, MID_Z}
	--for i = 1, 1000 do
	--	local point = GetRandomCoordWithEdgeBias(2)
	--	--local point = GetRandomPointInCircle(middle, 2000, 10)
	--	--PointEcho(point, "X")
	--end

	for i = 1, #toDrawEdges do
		local edge = toDrawEdges[i]
		LineDraw(edge)
		--LineEcho(edge, MakeBoolString({edge.vehPass, edge.botPass, edge.landPass}) .. ", width: " .. edge.terrainWidth .. ", tier: " .. edge.tierDiff)
	end
	
	toDrawEdges = nil
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Debug

function PointEcho(point, text)
	Spring.MarkerAddPoint(point[1], 0, point[2], text or "")
end

function LineDrawEcho(p1, p2, text)
	LineEcho(p1, p2, text)
	if not text then
		LineDraw(p1)
	end
	
end

function LineEcho(p1, p2, text)
	if text then
		PointEcho(GetMidpoint(p1, p2), text)
	else
		PointEcho(GetMidpoint(p1[1], p1[2]), p2)
	end
end

function LineDraw(p1, p2)
	if p2 then
		Spring.MarkerAddLine(p1[1], 0, p1[2], p2[1], 0, p2[2], true)
	else
		Spring.MarkerAddLine(p1[1][1], 0, p1[1][2], p1[2][1], 0, p1[2][2], true)
		Spring.MarkerAddLine(p1[2][1] + 20, 0, p1[2][2], p1[2][1] - 20, 0, p1[2][2], true)
		Spring.MarkerAddLine(p1[2][1], 0, p1[2][2] + 20, p1[2][1], 0, p1[2][2] - 20, true)
	end
end

function CellEcho(cell, text)
	PointEcho(cell.site, "Cell: " .. (cell.index or "NULL") .. (text or (", edges: " .. #cell.edges)))
	for k = 1, #cell.edges do
		LineDraw(cell.edges[k])
	end
end

function MakeBoolString(values)
	local str = " "
	for i = 1, #values do
		str = str .. ((values[i] and 1) or 0)
	end
	return str
end

function IsDebugCoord(x, z)
	return abs(x - 5464) <= 4 and abs(z - 4168) <= 4
end
