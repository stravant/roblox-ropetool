--!strict

local ropeCurve = require("./ropeCurve")

export type RopeProps = {
	Color: Color3?,
	Material: Enum.Material?,
	MaterialVariant: string?,
}

export type BuildRopeParams = {
	PointA: Vector3,
	PointB: Vector3,
	Sag: number,
	-- Horizontal bow perpendicular to the chord at the rope's middle.
	Sway: number?,
	Segments: number,
	SegmentType: string, -- "Box" | "Cylinder"
	Diameter: number,
	-- Sphere caps on the rope's two ends (Cylinder mode only, where the flat
	-- segment ends would otherwise show).
	HaveEndcaps: boolean?,
	Parent: Instance,
	Props: RopeProps?,
	-- Parts to reuse in order (the per-frame drag rebuild path); excess parts
	-- are unparented (not destroyed, for undo), missing ones are created.
	ExistingParts: { BasePart }?,
	ExistingCaps: { BasePart }?,
}

-- A frame at mid whose X axis runs along dir. Both segment shapes are built
-- with X as the long axis so discovery reads them back uniformly. When the
-- rope's bend-plane normal is known, the cross-section aligns to it (local Z
-- = plane normal), so every segment lies flush in the plane; otherwise an
-- up-reference frame is used.
local function frameAlong(mid: Vector3, dir: Vector3, planeNormal: Vector3?): CFrame
	if planeNormal then
		local y = planeNormal:Cross(dir)
		if y.Magnitude > 0.001 then
			return CFrame.fromMatrix(mid, dir, y.Unit, planeNormal)
		end
	end
	local up = if math.abs(dir:Dot(Vector3.yAxis)) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local z = dir:Cross(up).Unit
	local y = z:Cross(dir).Unit
	return CFrame.fromMatrix(mid, dir, y, z)
end

-- The rope's bend plane. Sag and sway share the same parabolic profile, so
-- the combined offset direction (-Y * sag + swayDir * sway) is CONSTANT along
-- the rope: the whole curve is planar, in the plane spanned by the chord and
-- that offset. Aligning every segment's cross-section to this plane's normal
-- makes the segments line up exactly -- coplanar box faces, outer-join
-- corners meeting precisely -- for any mix of sag and sway, level or tilted.
-- nil for a straight rope (no bend, no preferred plane) or degenerate chords.
local function bendPlaneNormal(a: Vector3, b: Vector3, sag: number, sway: number): Vector3?
	local offset = -Vector3.yAxis * sag
	if sway ~= 0 then
		local swayDir = ropeCurve.swayDirection(a, b)
		if swayDir then
			offset += swayDir * sway
		end
	end
	if offset.Magnitude < 1e-4 then
		return nil
	end
	local normal = (b - a):Cross(offset)
	if normal.Magnitude < 1e-4 then
		return nil
	end
	return normal.Unit
end

-- Cap on the per-joint outer-join extension, in diameters, so a degenerate
-- near-reversal bend can't produce an absurdly long segment.
local kMaxJointExtensionDiameters = 2

-- Outer join (ResizeAlign's "OuterTouch"): at each interior joint the two
-- segments are extended along their axes so their OUTER corners meet, instead
-- of both ending exactly on the shared curve point -- which leaves a wedge-
-- shaped gap on the outside of every bend. For a bend of angle theta between
-- the two segment directions, extending each side by (d/2) * tan(theta/2)
-- makes the outer corners land on the same point.
local function jointExtension(dirA: Vector3, dirB: Vector3, diameter: number): number
	local cosTheta = math.clamp(dirA:Dot(dirB), -1, 1)
	-- tan(theta/2) = sin(theta) / (1 + cos(theta)), stable except near reversal.
	if cosTheta < -0.9 then
		return diameter * kMaxJointExtensionDiameters
	end
	local sinTheta = math.sqrt(math.max(0, 1 - cosTheta * cosTheta))
	local extension = (diameter / 2) * sinTheta / (1 + cosTheta)
	return math.min(extension, diameter * kMaxJointExtensionDiameters)
end

-- Build (or update in place) the chain of segment parts for a rope between two
-- points with the given sag. Returns the parts in chain order, plus the endcap
-- parts (empty unless HaveEndcaps and Cylinder mode).
local function buildRope(params: BuildRopeParams): ({ BasePart }, { BasePart })
	local points = ropeCurve.computePoints(params.PointA, params.PointB, params.Sag, params.Segments, params.Sway)
	local planeNormal = bendPlaneNormal(params.PointA, params.PointB, params.Sag, params.Sway or 0)
	local existingParts = params.ExistingParts
	local props = params.Props
	local shape = if params.SegmentType == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
	local diameter = params.Diameter

	-- Per-segment unit directions, and the outer-join extension at each interior
	-- joint (ext[j] extends both segment j-1's far end and segment j's near end).
	local dirs: { Vector3? } = {}
	for i = 1, params.Segments do
		local span = points[i + 1] - points[i]
		dirs[i] = if span.Magnitude > 0.001 then span / span.Magnitude else nil
	end
	local ext: { [number]: number } = {}
	for j = 2, params.Segments do
		local dirA = dirs[j - 1]
		local dirB = dirs[j]
		if dirA and dirB then
			ext[j] = jointExtension(dirA, dirB, diameter)
		end
	end

	local parts: { BasePart } = {}
	for i = 1, params.Segments do
		local dir = dirs[i]
		if not dir then
			continue
		end
		-- Extend the segment past its curve points by the outer-join amounts.
		local p1 = points[i] - dir * (ext[i] or 0)
		local p2 = points[i + 1] + dir * (ext[i + 1] or 0)
		local span = p2 - p1
		local length = span.Magnitude
		if length < 0.001 then
			continue
		end

		local part: Part
		local existing = if existingParts then existingParts[i] else nil
		if existing and existing:IsA("Part") then
			part = existing :: Part
		else
			local newPart = Instance.new("Part")
			newPart.Name = "RopeSegment"
			newPart.TopSurface = Enum.SurfaceType.Smooth
			newPart.BottomSurface = Enum.SurfaceType.Smooth
			newPart.Anchored = true
			newPart.CanCollide = false
			part = newPart
		end
		-- Applied to reused parts too, so a panel appearance edit takes effect
		-- through the same rebuild path as everything else.
		if props then
			part.Color = props.Color or Color3.fromRGB(105, 64, 40)
			part.Material = props.Material or Enum.Material.Fabric
			part.MaterialVariant = props.MaterialVariant or ""
		elseif not existing then
			part.Color = Color3.fromRGB(105, 64, 40)
			part.Material = Enum.Material.Fabric
		end
		part.Shape = shape
		part.Size = Vector3.new(length, diameter, diameter)
		part.CFrame = frameAlong((p1 + p2) / 2, span / length, planeNormal)
		if part.Parent ~= params.Parent then
			part.Parent = params.Parent
		end
		table.insert(parts, part)
	end

	-- Unparent excess reused parts (Parent = nil rather than Destroy so undo
	-- can still restore them).
	if existingParts then
		for i = params.Segments + 1, #existingParts do
			existingParts[i].Parent = nil
		end
	end

	-- Sphere endcaps at the two rope ends, rounding off the exposed flat ends
	-- of the outer cylinder segments.
	local caps: { BasePart } = {}
	local existingCaps = params.ExistingCaps
	if params.HaveEndcaps == true and params.SegmentType == "Cylinder" then
		for i, position in { params.PointA, params.PointB } do
			local cap: Part
			local existing = if existingCaps then existingCaps[i] else nil
			if existing and existing:IsA("Part") then
				cap = existing :: Part
			else
				local newCap = Instance.new("Part")
				newCap.Name = "RopeEndcap"
				newCap.TopSurface = Enum.SurfaceType.Smooth
				newCap.BottomSurface = Enum.SurfaceType.Smooth
				newCap.Anchored = true
				newCap.CanCollide = false
				cap = newCap
			end
			if props then
				cap.Color = props.Color or Color3.fromRGB(105, 64, 40)
				cap.Material = props.Material or Enum.Material.Fabric
				cap.MaterialVariant = props.MaterialVariant or ""
			elseif not existing then
				cap.Color = Color3.fromRGB(105, 64, 40)
				cap.Material = Enum.Material.Fabric
			end
			cap.Shape = Enum.PartType.Ball
			cap.Size = Vector3.one * diameter
			cap.CFrame = CFrame.new(position)
			if cap.Parent ~= params.Parent then
				cap.Parent = params.Parent
			end
			table.insert(caps, cap)
		end
	end
	if existingCaps then
		for i = #caps + 1, #existingCaps do
			existingCaps[i].Parent = nil
		end
	end

	return parts, caps
end

return buildRope
