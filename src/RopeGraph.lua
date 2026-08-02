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

-- A part with no square cross-section reads as a rope segment when its long
-- axis exceeds its cross-section by this factor (an ambiguous cube has no
-- usable axis).
local kMinAspect = 1.05

-- When a part HAS a square cross-section (two axes matching within this
-- relative tolerance), the rope axis is the DISSIMILAR axis -- even when it
-- is SHORTER than the cross: dense ropes have segments stubbier than their
-- width. The stub ratio floor keeps plates and platforms (a 4x4x0.2 tile is
-- "square" too) from reading as segments along their thin axis.
local kSquareTolerance = 0.01
local kMinStubRatio = 0.25

-- Two segments chain when their endpoints are within this fraction of the
-- (average) segment diameter of each other, floored for very thin ropes.
-- Outer-joined segments (see buildRope) end d*sin(theta/2) apart at a bend of
-- angle theta, so this covers bends up to ~106 degrees per joint (the bottom
-- of a rope whose sag far exceeds its span) while staying below the >= 1
-- diameter separation of touching parallel ropes.
local kJoinToleranceFraction = 0.8
local kJoinToleranceFloor = 0.1

-- A LONE part -- a 1-segment chain with no endcaps vouching for it -- must
-- look convincingly stick-like BY ITSELF to read as a rope: at least this
-- oblong (length over the largest cross dimension), with its two cross
-- dimensions within this ratio of each other (near-square). The permissive
-- thresholds above are for parts joining a chain, where the neighbours are
-- the evidence of ropehood; a merely-elongated part standing alone (a plank,
-- a door, a wall) is just a part, not a 1-segment "rope".
local kLonePartMinAspect = 4
local kLonePartMaxCrossRatio = 1.25

-- Segment-count cap on a single discovery walk, so a pathological scene (e.g. a
-- huge grid of matching parts) can't hang the hover update.
local kMaxChainParts = 500

-- Of the property set {shape kind, cross-section size, color, material}, how
-- many must match for two adjacent parts to count as the same rope. 3 of 4
-- allows e.g. a color-striped rope while still splitting genuinely different
-- ropes that happen to touch.
local kRequiredMatches = 3

local kCrossSectionTolerance = 0.25 -- relative

-- Chain-walk curvature limits, three rules. The recurring distinction is
-- SMOOTH CONTEXT: the bottom joint of a rope whose sag rivals or exceeds its
-- span can legitimately bend 70-100+ degrees, but its neighbour joints bend
-- substantially too (the curvature ramps up toward the bottom), while an
-- attachment joint (a rope hung on a matching post) sits against a straight
-- or missing side.
-- * Absolute cap: a joint bending past ~80 degrees breaks -- UNLESS both its
--   neighbours turn the same direction with substantial bends of their own
--   (the droopy bottom).
-- * Magnitude spike: a joint bending well past the floor whose quieter side
--   is nearly straight, and far quieter than the joint, is an attachment.
-- * Reversal: a joint whose turn DIRECTION opposes its neighbours' (by more
--   than the floor, so numerical wobble doesn't count) is the meeting point
--   of two separately-hung ropes -- e.g. the middle of a W.
local kMaxJointBendRadians = math.rad(80)
local kSpikeFloorRadians = math.rad(25)
local kSpikeFactor = 3
local kSmoothNeighborRadians = math.rad(15)
local kMinReversalRadians = math.rad(10)

-- The endpoint finder's pairwise continuation threshold (it has no chain
-- context for the spike rule): a matching segment bending off by more than
-- this is an attachment, so the shared point stays a snap target.
local kMaxContinuationBendRadians = math.rad(45)

export type SegmentInfo = {
	part: BasePart,
	kind: string, -- "Cylinder" | "Block"
	axis: Vector3, -- unit, world space, along the long axis
	length: number,
	diameter: number, -- average of the two cross-section dimensions
	-- Oblong-ness: length over the LARGEST cross dimension. A rope-like stick
	-- scores high; a barely-elongated slab scores near 1.
	aspect: number,
	-- Cross-section squareness: the larger cross dimension over the smaller.
	-- 1 for a square/round cross; large for flat ones (a plank's).
	crossRatio: number,
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
	-- Sphere endcap parts found sitting on the chain's end vertices, in path
	-- order (the cap at path[1] first, if both exist).
	caps: { BasePart },
	-- Aggregate properties of the chain, for the panel and rebuilds.
	kind: string,
	diameter: number,
	color: Color3,
	material: Enum.Material,
	materialVariant: string,
}

local function similarSizes(x: number, y: number): boolean
	return math.abs(x - y) <= math.max(x, y) * kSquareTolerance
end

-- The rope axis of a part, if it plausibly is a rope segment. Cylinders
-- extend along local X by definition. Blocks with a square cross-section run
-- along the DISSIMILAR axis (which may be shorter than the cross, for dense
-- stubby segments); blocks without one run along their longest dimension when
-- sufficiently oblong.
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
		if length < math.max(cross1, cross2) * kMinStubRatio then
			return nil -- a disc/wheel, not a segment
		end
	elseif part.Shape == Enum.PartType.Block then
		kind = "Block"
		-- Square cross-section: the dissimilar axis is the rope axis.
		if similarSizes(size.Y, size.Z) and not similarSizes(size.X, (size.Y + size.Z) / 2) then
			localAxis = Vector3.xAxis
			length, cross1, cross2 = size.X, size.Y, size.Z
		elseif similarSizes(size.X, size.Z) and not similarSizes(size.Y, (size.X + size.Z) / 2) then
			localAxis = Vector3.yAxis
			length, cross1, cross2 = size.Y, size.X, size.Z
		elseif similarSizes(size.X, size.Y) and not similarSizes(size.Z, (size.X + size.Y) / 2) then
			localAxis = Vector3.zAxis
			length, cross1, cross2 = size.Z, size.X, size.Y
		elseif size.X >= size.Y and size.X >= size.Z then
			localAxis = Vector3.xAxis
			length, cross1, cross2 = size.X, size.Y, size.Z
		elseif size.Y >= size.X and size.Y >= size.Z then
			localAxis = Vector3.yAxis
			length, cross1, cross2 = size.Y, size.X, size.Z
		else
			localAxis = Vector3.zAxis
			length, cross1, cross2 = size.Z, size.X, size.Y
		end
		local maxCross = math.max(cross1, cross2)
		if similarSizes(cross1, cross2) then
			-- Square cross (or a near-cube that fell through): stubs allowed
			-- down to the plate/platform floor, cubes are ambiguous.
			if length < maxCross * kMinStubRatio or similarSizes(length, (cross1 + cross2) / 2) then
				return nil
			end
		elseif length < maxCross * kMinAspect then
			return nil
		end
	else
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
		aspect = length / math.max(cross1, cross2, 0.001),
		crossRatio = math.max(cross1, cross2) / math.max(math.min(cross1, cross2), 0.001),
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

-- Fraction of the shorter segment's length capping the join tolerance: a
-- tolerance reaching past a stubby segment's far end would let segments pair
-- with a NEIGHBOURING joint instead of the shared one (dense ropes have
-- joints spaced closer than the diameter-based tolerance).
local kJoinToleranceLengthFraction = 0.45

local function joinTolerance(a: SegmentInfo, b: SegmentInfo): number
	local base = (a.diameter + b.diameter) / 2 * kJoinToleranceFraction
	local lengthCap = math.min(a.length, b.length) * kJoinToleranceLengthFraction
	return math.max(kJoinToleranceFloor, math.min(base, lengthCap))
end

-- Whether a part reads as a rope endcap: a sphere whose diameter roughly
-- matches the given one and which shares an appearance property with the rope.
local function isMatchingCap(instance: Instance, diameter: number, color: Color3, material: Enum.Material): boolean
	if not instance:IsA("Part") then
		return false
	end
	local part = instance :: Part
	if part.Shape ~= Enum.PartType.Ball then
		return false
	end
	local size = part.Size
	local capDiameter = (size.X + size.Y + size.Z) / 3
	local scale = math.max(capDiameter, diameter, 0.001)
	if math.abs(capDiameter - diameter) / scale > kCrossSectionTolerance then
		return false
	end
	return part.Color == color or part.Material == material
end

-- Discover the rope containing seedPart: walk endpoint-to-endpoint adjacency
-- from it, admitting only parts that read as segments and match the seed's
-- properties. Sphere endcaps sitting on the chain's end vertices are picked up
-- too, and a cap itself works as a seed (discovery re-seeds from the segment
-- it caps). Returns nil when seedPart isn't a plausible segment or cap.
local function discoverRope(seedPart: Instance): Rope?
	local seedInfo = getSegmentInfo(seedPart)
	if not seedInfo then
		-- A sphere seed: re-seed from an adjacent segment whose endpoint sits
		-- on the sphere's center (i.e. the segment it caps).
		if seedPart:IsA("Part") and (seedPart :: Part).Shape == Enum.PartType.Ball then
			local cap = seedPart :: Part
			local capDiameter = (cap.Size.X + cap.Size.Y + cap.Size.Z) / 3
			local searchRadius = math.max(kJoinToleranceFloor, capDiameter * kJoinToleranceFraction) + 0.05
			local params = OverlapParams.new()
			params.MaxParts = 1000
			for _, candidate in workspace:GetPartBoundsInRadius(cap.Position, searchRadius, params) do
				local info = getSegmentInfo(candidate)
				if info and isMatchingCap(cap, info.diameter, candidate.Color, candidate.Material) then
					local tolerance = joinTolerance(info, info)
					local d1 = (info.e1 - cap.Position).Magnitude
					local d2 = (info.e2 - cap.Position).Magnitude
					if math.min(d1, d2) <= tolerance then
						return discoverRope(candidate)
					end
				end
			end
		end
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
	-- recovers the joint itself to second order. excludeId bars a specific
	-- vertex from being merged onto (see addSegment).
	local function resolveVertex(position: Vector3, tolerance: number, excludeId: number?): number
		local bestId: number? = nil
		local bestDist = tolerance
		for id, v in vertices do
			if id ~= excludeId then
				local dist = (v.position - position).Magnitude
				if dist <= bestDist then
					bestDist = dist
					bestId = id
				end
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

	local function nearestVertexDistance(position: Vector3): number
		local best = math.huge
		for _, v in vertices do
			best = math.min(best, (v.position - position).Magnitude)
		end
		return best
	end

	local function addSegment(info: SegmentInfo): number
		local tolerance = joinTolerance(info, info)
		-- Stubby segments (dense ropes) can be SHORTER than the join
		-- tolerance, so two guards keep the topology intact: the endpoint
		-- sitting closest to an existing vertex resolves first (it is the one
		-- actually joining the chain -- the other end could otherwise
		-- greedily merge onto a NEIGHBOURING joint's vertex), and the second
		-- endpoint is barred from collapsing onto the first's vertex.
		local v1: number
		local v2: number
		if nearestVertexDistance(info.e2) < nearestVertexDistance(info.e1) then
			v2 = resolveVertex(info.e2, tolerance)
			v1 = resolveVertex(info.e1, tolerance, v2)
		else
			v1 = resolveVertex(info.e1, tolerance)
			v2 = resolveVertex(info.e2, tolerance, v1)
		end
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

	-- Curvature-continuity trim: two separately-hung ropes whose ends meet (a
	-- W shape) read as one degree-2 chain, but a genuine hanging curve turns
	-- consistently in one direction while the meeting joint turns the OTHER
	-- way. Cut the chain at such joints, keeping the run holding the seed.
	if #chainEdges >= 2 then
		local positions: { Vector3 } = {}
		for _, vid in path do
			table.insert(positions, vertices[vid].position)
		end
		-- The bend at each interior joint j (between chain edges j-1 and j),
		-- as a rotation vector (turn axis * angle) plus the bare angle.
		local bendRots: { [number]: Vector3 } = {}
		local bendAngles: { [number]: number } = {}
		for j = 2, #chainEdges do
			local d1 = positions[j] - positions[j - 1]
			local d2 = positions[j + 1] - positions[j]
			if d1.Magnitude > 0.001 and d2.Magnitude > 0.001 then
				d1, d2 = d1.Unit, d2.Unit
				local axis = d1:Cross(d2)
				-- math.atan2, NOT math.atan: Luau's atan silently ignores a
				-- second argument, which would compress every angle to <= 45.
				local angle = math.atan2(axis.Magnitude, d1:Dot(d2))
				bendAngles[j] = angle
				bendRots[j] = if axis.Magnitude > 1e-6 then axis.Unit * angle else Vector3.zero
			end
		end
		-- breakAt[j]: cut between chain edges j-1 and j. Absolute cap, or a
		-- turn that reverses against EVERY neighbouring joint's turn (a normal
		-- joint always agrees with at least its far-side neighbour, so only
		-- the meeting joint itself gets flagged).
		local breakAt: { [number]: boolean } = {}
		for j = 2, #chainEdges do
			local angle = bendAngles[j]
			if not angle then
				continue
			end
			local rot = bendRots[j]
			-- Smooth context: both neighbours turning the same direction with
			-- substantial bends of their own -- the shape of a droopy bottom.
			local prevAngle = bendAngles[j - 1]
			local nextAngle = bendAngles[j + 1]
			local prevRot = bendRots[j - 1]
			local nextRot = bendRots[j + 1]
			local smoothContext = prevAngle ~= nil
				and nextAngle ~= nil
				and prevAngle > kSmoothNeighborRadians
				and nextAngle > kSmoothNeighborRadians
				and rot:Dot(prevRot :: Vector3) > 0
				and rot:Dot(nextRot :: Vector3) > 0
			if angle > kMaxJointBendRadians and not smoothContext then
				breakAt[j] = true
				continue
			end
			-- Magnitude spike: a big bend whose quieter side is nearly
			-- straight and far quieter than the joint (an attachment).
			local minNeighborAngle = math.huge
			local haveNeighbor = false
			for _, k in { j - 1, j + 1 } do
				local otherAngle = bendAngles[k]
				if otherAngle then
					haveNeighbor = true
					minNeighborAngle = math.min(minNeighborAngle, otherAngle)
				end
			end
			if
				haveNeighbor
				and angle > kSpikeFloorRadians
				and minNeighborAngle < kSmoothNeighborRadians
				and angle > kSpikeFactor * minNeighborAngle
			then
				breakAt[j] = true
				continue
			end
			local reversesAll = false
			for _, k in { j - 1, j + 1 } do
				local otherRot = bendRots[k]
				if otherRot then
					if rot:Dot(otherRot) <= 0 and (rot - otherRot).Magnitude > kMinReversalRadians then
						reversesAll = true
					else
						reversesAll = false
						break
					end
				end
			end
			if reversesAll then
				breakAt[j] = true
			end
		end
		local seedIndex = table.find(chainEdges, seedEdgeId) or 1
		local lo = seedIndex
		while lo > 1 and not breakAt[lo] do
			lo -= 1
		end
		local hi = seedIndex
		while hi < #chainEdges and not breakAt[hi + 1] do
			hi += 1
		end
		if lo > 1 or hi < #chainEdges then
			local newEdges: { number } = {}
			for i = lo, hi do
				table.insert(newEdges, chainEdges[i])
			end
			local newPath: { number } = {}
			for i = lo, hi + 1 do
				table.insert(newPath, path[i])
			end
			chainEdges = newEdges
			path = newPath
		end
	end

	-- Aggregate chain properties (diameter averaged, appearance from the seed).
	local diameterSum = 0
	for _, eid in chainEdges do
		diameterSum += infoByPart[edges[eid].part].diameter
	end
	local seedPartTyped = seedInfo.part
	local diameter = diameterSum / #chainEdges

	-- Sphere endcaps: matching Ball parts centered on the chain's end vertices.
	local caps: { BasePart } = {}
	local capSeen: { [BasePart]: boolean } = {}
	local endVids = if path[1] ~= path[#path] then { path[1], path[#path] } else { path[1] }
	for _, vid in endVids do
		local position = vertices[vid].position
		local tolerance = math.max(kJoinToleranceFloor, diameter * kJoinToleranceFraction)
		local params = OverlapParams.new()
		params.MaxParts = 1000
		for _, candidate in workspace:GetPartBoundsInRadius(position, tolerance + 0.05, params) do
			if
				not capSeen[candidate]
				and isMatchingCap(candidate, diameter, seedPartTyped.Color, seedPartTyped.Material)
				and (candidate.Position - position).Magnitude <= tolerance
			then
				capSeen[candidate] = true
				table.insert(caps, candidate)
				break -- one cap per end
			end
		end
	end

	-- The lone-part gate (see kLonePartMinAspect): a chain of just the seed,
	-- with no endcaps vouching for it, is only a rope when the part is
	-- convincingly stick-like on its own.
	if #chainEdges == 1 and #caps == 0 then
		if seedInfo.aspect < kLonePartMinAspect or seedInfo.crossRatio > kLonePartMaxCrossRatio then
			return nil
		end
	end

	return {
		vertices = vertices,
		edges = edges,
		path = path,
		chainEdges = chainEdges,
		caps = caps,
		kind = seedInfo.kind,
		diameter = diameter,
		color = seedPartTyped.Color,
		material = seedPartTyped.Material,
		materialVariant = seedPartTyped.MaterialVariant,
	}
end

-- Rope attach points near a position, for point snapping, in two lists:
-- ENDPOINTS (chain ends -- segment endpoints that no other matching segment
-- continues) and interior JOINTS (endpoints a matching segment does continue,
-- so another rope can hang off the middle of this one). One bounds query
-- suffices: any segment sharing an endpoint that lies inside the query sphere
-- necessarily has bounds touching the sphere, so it is in the collection and
-- chain-endness can be decided in memory.
-- excludeParts (e.g. the rope being dragged) contribute neither endpoints nor
-- continuations.
--
-- This runs per hover frame in Add mode, so the continuation checks go
-- through a coarse spatial grid over the collected endpoints rather than an
-- O(n^2) all-pairs scan (a couple of dense ropes near the cursor collect
-- hundreds of segments).
type EndpointEntry = { index: number, position: Vector3, far: Vector3 }
local function findRopeSnapPointsNear(
	position: Vector3,
	radius: number,
	excludeParts: { [BasePart]: boolean }?
): ({ Vector3 }, { Vector3 })
	local params = OverlapParams.new()
	params.MaxParts = 1000
	local infos: { SegmentInfo } = {}
	for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
		if not (excludeParts and excludeParts[part]) then
			local info = getSegmentInfo(part)
			if info then
				table.insert(infos, info)
			end
		end
	end

	-- Bucket every endpoint by a grid whose cell size is the largest self
	-- tolerance present. Any PAIR tolerance is bounded by the larger of the
	-- two segments' self tolerances, so a continuation partner is always in
	-- the endpoint's own or an adjacent cell.
	local cellSize = kJoinToleranceFloor
	for _, info in infos do
		cellSize = math.max(cellSize, joinTolerance(info, info))
	end
	local grid: { [Vector3]: { EndpointEntry } } = {}
	local function cellKey(p: Vector3): Vector3
		return Vector3.new(math.floor(p.X / cellSize), math.floor(p.Y / cellSize), math.floor(p.Z / cellSize))
	end
	for index, info in infos do
		for endIndex, endpoint in { info.e1, info.e2 } do
			local key = cellKey(endpoint)
			local bucket = grid[key]
			if not bucket then
				bucket = {}
				grid[key] = bucket
			end
			table.insert(bucket, {
				index = index,
				position = endpoint,
				far = if endIndex == 1 then info.e2 else info.e1,
			})
		end
	end

	-- The position of a matching segment endpoint smoothly continuing the
	-- chain at `endpoint`, or nil (same rule as the chain walk's absolute
	-- cap: a steep joint is an ATTACHMENT, e.g. a rope hung off a matching
	-- post, and the endpoint stays a chain end).
	local function findContinuation(index: number, endpoint: Vector3, infoFar: Vector3): Vector3?
		local info = infos[index]
		local base = cellKey(endpoint)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local bucket = grid[base + Vector3.new(dx, dy, dz)]
					if bucket then
						for _, entry in bucket do
							if entry.index ~= index then
								local other = infos[entry.index]
								if
									(entry.position - endpoint).Magnitude <= joinTolerance(info, other)
									and segmentsMatch(info, other)
								then
									local incoming = endpoint - infoFar
									local outgoing = entry.far - endpoint
									if incoming.Magnitude > 0.001 and outgoing.Magnitude > 0.001 then
										local du = incoming.Unit
										local dv = outgoing.Unit
										local angle = math.atan2(du:Cross(dv).Magnitude, du:Dot(dv))
										if angle <= kMaxContinuationBendRadians then
											return entry.position
										end
									end
								end
							end
						end
					end
				end
			end
		end
		return nil
	end

	local endpoints: { Vector3 } = {}
	local joints: { Vector3 } = {}
	-- A joint is contributed once per adjoining segment (twice normally, more
	-- at junctions), each pair averaging to the same point: dedupe nearby.
	local function noteJoint(jointPosition: Vector3)
		for _, existing in joints do
			if (existing - jointPosition).Magnitude <= kJoinToleranceFloor then
				return
			end
		end
		table.insert(joints, jointPosition)
	end
	for index, info in infos do
		for endIndex, endpoint in { info.e1, info.e2 } do
			if (endpoint - position).Magnitude <= radius then
				local infoFar = if endIndex == 1 then info.e2 else info.e1
				local partner = findContinuation(index, endpoint, infoFar)
				if partner then
					-- An interior joint. The two straddling endpoints extend
					-- PAST the joint symmetrically (buildRope's outer join),
					-- so their average recovers the joint itself.
					noteJoint((endpoint + partner) / 2)
				else
					table.insert(endpoints, endpoint)
				end
			end
		end
	end
	return endpoints, joints
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
	findRopeSnapPointsNear = findRopeSnapPointsNear,
	ropePolyline = ropePolyline,
	ropeParts = ropeParts,
}
