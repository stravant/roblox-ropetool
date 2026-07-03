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
	Segments: number,
	SegmentType: string, -- "Box" | "Cylinder"
	Diameter: number,
	Parent: Instance,
	Props: RopeProps?,
	-- Parts to reuse in order (the per-frame drag rebuild path); excess parts
	-- are unparented (not destroyed, for undo), missing ones are created.
	ExistingParts: { BasePart }?,
}

-- A frame at mid whose X axis runs along dir. Both segment shapes are built
-- with X as the long axis so discovery reads them back uniformly.
local function frameAlong(mid: Vector3, dir: Vector3): CFrame
	local up = if math.abs(dir:Dot(Vector3.yAxis)) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local z = dir:Cross(up).Unit
	local y = z:Cross(dir).Unit
	return CFrame.fromMatrix(mid, dir, y, z)
end

-- Build (or update in place) the chain of segment parts for a rope between two
-- points with the given sag. Returns the parts in chain order.
local function buildRope(params: BuildRopeParams): { BasePart }
	local points = ropeCurve.computePoints(params.PointA, params.PointB, params.Sag, params.Segments)
	local existingParts = params.ExistingParts
	local props = params.Props
	local shape = if params.SegmentType == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
	local diameter = params.Diameter

	local parts: { BasePart } = {}
	for i = 1, params.Segments do
		local p1 = points[i]
		local p2 = points[i + 1]
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
		part.CFrame = frameAlong((p1 + p2) / 2, span / length)
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

	return parts
end

return buildRope
