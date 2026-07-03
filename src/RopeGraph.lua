--!strict

-- Implicit rope discovery: the parts in the scene are treated as the segments of
-- "ropes" -- contiguous chains of elongated parts laid end to end. Nothing is
-- stored on the parts themselves; the structure is discovered on demand by
-- walking part-to-part adjacency, in the spirit of PolyMap's implicit mesh
-- discovery.
--
-- The discovered geometry is a graph of vertices (shared segment endpoints)
-- joined by edges. An edge remembers which side of it the part sits on: v1 is
-- the vertex at the part's -axis end and v2 the one at its +axis end, so a
-- consumer can orient the part relative to the chain.

-- A part reads as a rope segment when its long axis exceeds its cross-section
-- by this factor (an ambiguous cube has no usable axis).
local kMinAspect = 1.05

-- Two segments chain when their endpoints are within this fraction of the
-- (average) segment diameter of each other, floored for very thin ropes.
-- Outer-joined segments (see buildRope) end d*sin(theta/2) apart at a bend of
-- angle theta, so this covers bends up to ~80 degrees per joint while staying
-- below the >= 1 diameter separation of touching parallel ropes.
local kJoinToleranceFraction = 0.65
local kJoinToleranceFloor = 0.1

-- Segment-count cap on a single discovery walk, so a pathological scene (e.g. a
-- huge grid of matching parts) can't hang the hover update.
local kMaxChainParts = 500

-- Of the property set {shape kind, cross-section size, color, material}, how
-- many must match for two adjacent parts to count as the same rope. 3 of 4
-- allows e.g. a color-striped rope while still splitting genuinely different
-- ropes that happen to touch.
local kRequiredMatches = 3

local kCrossSectionTolerance = 0.25 -- relative

export type SegmentInfo = {
	part: BasePart,
	kind: string, -- "Cylinder" | "Block"
	axis: Vector3, -- unit, world space, along the long axis
	length: number,
	diameter: number, -- average of the two cross-section dimensions
	e1: Vector3, -- endpoint at the -axis end
	e2: Vector3, -- endpoint at the +axis end
}

export type RopeVertex = {
	position: Vector3,
	edges: { number },
}

export type RopeEdge = {
	v1: number, -- vertex at the part's -axis end
	v2: number, -- vertex at the part's +axis end
	part: BasePart,
}

export type Rope = {
	vertices: { RopeVertex },
	edges: { RopeEdge },
	-- The ordered chain through the seed part: path holds vertex ids from one
	-- end to the other, chainEdges[i] joins path[i] to path[i+1].
	path: { number },
	chainEdges: { number },
	-- Aggregate properties of the chain, for the panel and rebuilds.
	kind: string,
	diameter: number,
	color: Color3,
	material: Enum.Material,
	materialVariant: string,
}

-- The long axis of a part, if it plausibly is a rope segment. Cylinders extend
-- along local X by definition; Blocks along their longest dimension.
local function getSegmentInfo(instance: Instance): SegmentInfo?
	if not instance:IsA("Part") then
		return nil
	end
	local part = instance :: Part
	local size = part.Size
	local kind: string
	local localAxis: Vector3
	local length: number
	local cross1: number
	local cross2: number
	if part.Shape == Enum.PartType.Cylinder then
		kind = "Cylinder"
		localAxis = Vector3.xAxis
		length = size.X
		cross1, cross2 = size.Y, size.Z
	elseif part.Shape == Enum.PartType.Block then
		kind = "Block"
		if size.X >= size.Y and size.X >= size.Z then
			localAxis = Vector3.xAxis
			length, cross1, cross2 = size.X, size.Y, size.Z
		elseif size.Y >= size.X and size.Y >= size.Z then
			localAxis = Vector3.yAxis
			length, cross1, cross2 = size.Y, size.X, size.Z
		else
			localAxis = Vector3.zAxis
			length, cross1, cross2 = size.Z, size.X, size.Y
		end
	else
		return nil
	end
	if length < math.max(cross1, cross2) * kMinAspect then
		return nil
	end
	local axis = part.CFrame:VectorToWorldSpace(localAxis)
	local center = part.Position
	local halfSpan = axis * (length / 2)
	return {
		part = part,
		kind = kind,
		axis = axis,
		length = length,
		diameter = (cross1 + cross2) / 2,
		e1 = center - halfSpan,
		e2 = center + halfSpan,
	}
end

-- Property-overlap heuristic: adjacent parts belong to the same rope when
-- enough of {kind, cross-section, color, material} agree.
local function segmentsMatch(a: SegmentInfo, b: SegmentInfo): boolean
	local matches = 0
	if a.kind == b.kind then
		matches += 1
	end
	local crossScale = math.max(a.diameter, b.diameter, 0.001)
	if math.abs(a.diameter - b.diameter) / crossScale <= kCrossSectionTolerance then
		matches += 1
	end
	if a.part.Color == b.part.Color then
		matches += 1
	end
	if a.part.Material == b.part.Material and a.part.MaterialVariant == b.part.MaterialVariant then
		matches += 1
	end
	return matches >= kRequiredMatches
end

local function joinTolerance(a: SegmentInfo, b: SegmentInfo): number
	return math.max(kJoinToleranceFloor, (a.diameter + b.diameter) / 2 * kJoinToleranceFraction)
end

-- Discover the rope containing seedPart: walk endpoint-to-endpoint adjacency
-- from it, admitting only parts that read as segments and match the seed's
-- properties. Returns nil when seedPart itself isn't a plausible segment.
local function discoverRope(seedPart: Instance): Rope?
	local seedInfo = getSegmentInfo(seedPart)
	if not seedInfo then
		return nil
	end

	local vertices: { RopeVertex } = {}
	local edges: { RopeEdge } = {}
	local infoByPart: { [BasePart]: SegmentInfo } = {}
	local edgeIdByPart: { [BasePart]: number } = {}
	-- How many endpoints have merged into each vertex, for position averaging.
	local vertexCounts: { number } = {}

	-- Merge a segment endpoint onto an existing vertex within tolerance, or
	-- make a new one. Linear scan: chains are capped small. Merged positions
	-- are averaged: outer-joined segments (see buildRope) extend PAST the true
	-- joint symmetrically, so the average of the two straddling endpoints
	-- recovers the joint itself to second order.
	local function resolveVertex(position: Vector3, tolerance: number): number
		local bestId: number? = nil
		local bestDist = tolerance
		for id, v in vertices do
			local dist = (v.position - position).Magnitude
			if dist <= bestDist then
				bestDist = dist
				bestId = id
			end
		end
		if bestId then
			local count = vertexCounts[bestId]
			vertices[bestId].position = (vertices[bestId].position * count + position) / (count + 1)
			vertexCounts[bestId] = count + 1
			return bestId
		end
		table.insert(vertices, { position = position, edges = {} })
		table.insert(vertexCounts, 1)
		return #vertices
	end

	local function addSegment(info: SegmentInfo): number
		local tolerance = joinTolerance(info, info)
		local v1 = resolveVertex(info.e1, tolerance)
		local v2 = resolveVertex(info.e2, tolerance)
		table.insert(edges, { v1 = v1, v2 = v2, part = info.part })
		local edgeId = #edges
		table.insert(vertices[v1].edges, edgeId)
		if v2 ~= v1 then
			table.insert(vertices[v2].edges, edgeId)
		end
		infoByPart[info.part] = info
		edgeIdByPart[info.part] = edgeId
		return edgeId
	end

	addSegment(seedInfo)

	-- BFS over endpoints: at each frontier endpoint, look for unvisited
	-- matching segments with an endpoint within tolerance of it.
	local queue: { SegmentInfo } = { seedInfo }
	local queueHead = 1
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {}
	-- The default MaxParts is small; endpoint queries must see every candidate.
	overlapParams.MaxParts = 1000
	while queueHead <= #queue do
		local info = queue[queueHead]
		queueHead += 1
		if #edges >= kMaxChainParts then
			break
		end
		for _, endpoint in { info.e1, info.e2 } do
			-- A neighbour's endpoint coincides with ours, so its bounding box
			-- always covers a small sphere around the endpoint.
			local searchRadius = joinTolerance(info, info) + 0.05
			for _, candidate in workspace:GetPartBoundsInRadius(endpoint, searchRadius, overlapParams) do
				if infoByPart[candidate] then
					continue
				end
				local candidateInfo = getSegmentInfo(candidate)
				if not candidateInfo then
					continue
				end
				if not segmentsMatch(seedInfo, candidateInfo) then
					continue
				end
				local tolerance = joinTolerance(info, candidateInfo)
				local d1 = (candidateInfo.e1 - endpoint).Magnitude
				local d2 = (candidateInfo.e2 - endpoint).Magnitude
				if math.min(d1, d2) > tolerance then
					continue
				end
				addSegment(candidateInfo)
				table.insert(queue, candidateInfo)
				if #edges >= kMaxChainParts then
					break
				end
			end
		end
	end

	-- Extract the ordered chain through the seed edge: extend from both of its
	-- vertices, continuing only through degree-2 vertices (a junction or an end
	-- terminates that side), guarding against closed loops.
	local seedEdgeId = edgeIdByPart[seedInfo.part]

	local function walk(fromEdgeId: number, fromVertexId: number): ({ number }, { number })
		local pathOut: { number } = {}
		local edgesOut: { number } = {}
		local currentEdge = fromEdgeId
		local currentVertex = fromVertexId
		local visited: { [number]: boolean } = {}
		while true do
			if visited[currentVertex] then
				break -- closed loop
			end
			visited[currentVertex] = true
			table.insert(pathOut, currentVertex)
			local v = vertices[currentVertex]
			if #v.edges ~= 2 then
				break -- an end (1) or a junction (3+)
			end
			local nextEdge = if v.edges[1] == currentEdge then v.edges[2] else v.edges[1]
			local e = edges[nextEdge]
			table.insert(edgesOut, nextEdge)
			currentEdge = nextEdge
			currentVertex = if e.v1 == currentVertex then e.v2 else e.v1
		end
		return pathOut, edgesOut
	end

	local seedEdge = edges[seedEdgeId]
	local backPath, backEdges = walk(seedEdgeId, seedEdge.v1)
	local forwardPath, forwardEdges = walk(seedEdgeId, seedEdge.v2)

	-- Stitch: reversed back side + seed edge + forward side.
	local path: { number } = {}
	local chainEdges: { number } = {}
	for i = #backPath, 1, -1 do
		table.insert(path, backPath[i])
	end
	for i = #backEdges, 1, -1 do
		table.insert(chainEdges, backEdges[i])
	end
	table.insert(chainEdges, seedEdgeId)
	for _, vid in forwardPath do
		table.insert(path, vid)
	end
	for _, eid in forwardEdges do
		table.insert(chainEdges, eid)
	end

	-- Aggregate chain properties (diameter averaged, appearance from the seed).
	local diameterSum = 0
	for _, eid in chainEdges do
		diameterSum += infoByPart[edges[eid].part].diameter
	end
	local seedPartTyped = seedInfo.part

	return {
		vertices = vertices,
		edges = edges,
		path = path,
		chainEdges = chainEdges,
		kind = seedInfo.kind,
		diameter = diameterSum / #chainEdges,
		color = seedPartTyped.Color,
		material = seedPartTyped.Material,
		materialVariant = seedPartTyped.MaterialVariant,
	}
end

-- The chain's vertex positions in path order (the rope's polyline).
local function ropePolyline(rope: Rope): { Vector3 }
	local points: { Vector3 } = {}
	for _, vid in rope.path do
		table.insert(points, rope.vertices[vid].position)
	end
	return points
end

-- The chain's parts in path order.
local function ropeParts(rope: Rope): { BasePart }
	local parts: { BasePart } = {}
	for _, eid in rope.chainEdges do
		table.insert(parts, rope.edges[eid].part)
	end
	return parts
end

return {
	getSegmentInfo = getSegmentInfo,
	segmentsMatch = segmentsMatch,
	discoverRope = discoverRope,
	ropePolyline = ropePolyline,
	ropeParts = ropeParts,
}
