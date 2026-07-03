--!strict

local TestTypes = require("./TestTypes")
local buildRope = require("./buildRope")
local RopeGraph = require("./RopeGraph")
local ropeCurve = require("./ropeCurve")

-- Fixtures live far from the origin so they can't collide with user content
-- (mirrors PolyMap's spec convention).
local kRegion = Vector3.new(6000, 20, -200)

local function sweepRegion()
	local params = OverlapParams.new()
	params.MaxParts = 10000
	for _, p in workspace:GetPartBoundsInRadius(kRegion, 200, params) do
		if p:IsA("BasePart") then
			p:Destroy()
		end
	end
end

return function(t: TestTypes.TestContext)
	local function nearV(a: Vector3, b: Vector3, tolerance: number): boolean
		return (a - b).Magnitude <= tolerance
	end

	local function withFolder(fn: (Folder) -> ())
		sweepRegion()
		local folder = Instance.new("Folder")
		folder.Name = "RopeTestFixture"
		folder.Parent = workspace
		local ok, err = pcall(fn, folder)
		folder:Destroy()
		sweepRegion()
		if not ok then
			error(err)
		end
	end

	t.test("builds the requested number of segment parts spanning A to B", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 4, 0)
			local parts = buildRope({
				PointA = a,
				PointB = b,
				Sag = 2,
				Segments = 8,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
			})
			t.expect(#parts).toBe(8)
			for _, part in parts do
				t.expect((part :: Part).Shape).toBe(Enum.PartType.Cylinder)
				t.expect(part.Parent).toBe(folder)
			end
			-- The chain's outer endpoints land on A and B.
			local firstInfo = RopeGraph.getSegmentInfo(parts[1])
			local lastInfo = RopeGraph.getSegmentInfo(parts[8])
			assert(firstInfo and lastInfo)
			local firstEnd = if nearV(firstInfo.e1, a, 0.01) then firstInfo.e1 else firstInfo.e2
			local lastEnd = if nearV(lastInfo.e1, b, 0.01) then lastInfo.e1 else lastInfo.e2
			t.expect(nearV(firstEnd, a, 0.01)).toBeTruthy()
			t.expect(nearV(lastEnd, b, 0.01)).toBeTruthy()
		end)
	end)

	t.test("adjacent segments share endpoints within the discovery join tolerance", function()
		withFolder(function(folder)
			local diameter = 0.3
			local parts = buildRope({
				PointA = kRegion,
				PointB = kRegion + Vector3.new(16, 0, 8),
				Sag = 3,
				Segments = 6,
				SegmentType = "Box",
				Diameter = diameter,
				Parent = folder,
			})
			-- Outer-joined ends straddle the shared curve point, so they aren't
			-- coincident -- but they must stay within RopeGraph's join tolerance
			-- or the chain wouldn't discover.
			for i = 1, #parts - 1 do
				local infoA = RopeGraph.getSegmentInfo(parts[i])
				local infoB = RopeGraph.getSegmentInfo(parts[i + 1])
				assert(infoA and infoB)
				local best = math.min(
					(infoA.e1 - infoB.e1).Magnitude,
					(infoA.e1 - infoB.e2).Magnitude,
					(infoA.e2 - infoB.e1).Magnitude,
					(infoA.e2 - infoB.e2).Magnitude
				)
				t.expect(best < diameter * 0.65).toBeTruthy()
			end
		end)
	end)

	t.test("outer join extends segments at bends but not at the rope ends", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local points = ropeCurve.computePoints(a, b, 3, 4)
			local parts = buildRope({
				PointA = a,
				PointB = b,
				Sag = 3,
				Segments = 4,
				SegmentType = "Box",
				Diameter = 0.4,
				Parent = folder,
			})
			-- Every joint bends, so every segment gets extended past its chord.
			for i = 1, 4 do
				local chord = (points[i + 1] - points[i]).Magnitude
				local info = RopeGraph.getSegmentInfo(parts[i])
				assert(info)
				t.expect(info.length > chord + 1e-4).toBeTruthy()
			end
			-- The rope's outer ends stay exactly on A and B (no extension there).
			local firstInfo = RopeGraph.getSegmentInfo(parts[1])
			local lastInfo = RopeGraph.getSegmentInfo(parts[4])
			assert(firstInfo and lastInfo)
			local firstDist = math.min((firstInfo.e1 - a).Magnitude, (firstInfo.e2 - a).Magnitude)
			local lastDist = math.min((lastInfo.e1 - b).Magnitude, (lastInfo.e2 - b).Magnitude)
			t.expect(firstDist < 0.001).toBeTruthy()
			t.expect(lastDist < 0.001).toBeTruthy()

			-- A straight rope has no bends: segments span their chords exactly.
			local straightParts = buildRope({
				PointA = kRegion + Vector3.new(0, 0, 30),
				PointB = kRegion + Vector3.new(20, 0, 30),
				Sag = 0,
				Segments = 4,
				SegmentType = "Box",
				Diameter = 0.4,
				Parent = folder,
			})
			for _, part in straightParts do
				local info = RopeGraph.getSegmentInfo(part)
				assert(info)
				t.expect(math.abs(info.length - 5) < 1e-4).toBeTruthy()
			end
		end)
	end)

	t.test("rebuild reuses existing parts and trims excess", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local params = {
				PointA = a,
				PointB = b,
				Sag = 2,
				Segments = 8,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
			}
			local parts = buildRope(params :: any)
			-- Same count: every part reused in place.
			local rebuilt = buildRope({
				PointA = a,
				PointB = b + Vector3.new(0, 5, 0),
				Sag = 3,
				Segments = 8,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
				ExistingParts = parts,
			})
			t.expect(#rebuilt).toBe(8)
			for i = 1, 8 do
				t.expect(rebuilt[i]).toBe(parts[i])
			end
			-- Fewer segments: the excess parts are unparented (not destroyed).
			local trimmed = buildRope({
				PointA = a,
				PointB = b,
				Sag = 2,
				Segments = 5,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
				ExistingParts = rebuilt,
			})
			t.expect(#trimmed).toBe(5)
			for i = 6, 8 do
				t.expect(rebuilt[i].Parent).toBe(nil)
			end
		end)
	end)

	t.test("endcaps are built for cylinders, reused, and dropped for boxes", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(12, 0, 0)
			local parts, caps = buildRope({
				PointA = a,
				PointB = b,
				Sag = 2,
				Segments = 6,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				HaveEndcaps = true,
				Parent = folder,
			})
			t.expect(#caps).toBe(2)
			for _, cap in caps do
				t.expect((cap :: Part).Shape).toBe(Enum.PartType.Ball)
				t.expect((cap.Size - Vector3.one * 0.4).Magnitude < 0.001).toBeTruthy()
				t.expect(cap.Parent).toBe(folder)
			end
			t.expect(nearV(caps[1].Position, a, 0.001)).toBeTruthy()
			t.expect(nearV(caps[2].Position, b, 0.001)).toBeTruthy()

			-- Rebuilds reuse the cap instances in place.
			local _, caps2 = buildRope({
				PointA = a,
				PointB = b + Vector3.new(0, 3, 0),
				Sag = 2,
				Segments = 6,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				HaveEndcaps = true,
				Parent = folder,
				ExistingParts = parts,
				ExistingCaps = caps,
			})
			t.expect(caps2[1]).toBe(caps[1])
			t.expect(caps2[2]).toBe(caps[2])
			t.expect(nearV(caps2[2].Position, b + Vector3.new(0, 3, 0), 0.001)).toBeTruthy()

			-- Box mode drops the caps even when requested (unparented, not destroyed).
			local _, caps3 = buildRope({
				PointA = a,
				PointB = b,
				Sag = 2,
				Segments = 6,
				SegmentType = "Box",
				Diameter = 0.4,
				HaveEndcaps = true,
				Parent = folder,
				ExistingParts = parts,
				ExistingCaps = caps,
			})
			t.expect(#caps3).toBe(0)
			t.expect(caps[1].Parent).toBe(nil)
			t.expect(caps[2].Parent).toBe(nil)
		end)
	end)

	t.test("applies appearance props to new and reused parts", function()
		withFolder(function(folder)
			local red = Color3.new(1, 0, 0)
			local parts = buildRope({
				PointA = kRegion,
				PointB = kRegion + Vector3.new(10, 0, 0),
				Sag = 1,
				Segments = 4,
				SegmentType = "Box",
				Diameter = 0.3,
				Parent = folder,
				Props = { Color = red, Material = Enum.Material.Metal },
			})
			for _, part in parts do
				t.expect(part.Color).toBe(red)
				t.expect(part.Material).toBe(Enum.Material.Metal)
			end
			local blue = Color3.new(0, 0, 1)
			buildRope({
				PointA = kRegion,
				PointB = kRegion + Vector3.new(10, 0, 0),
				Sag = 1,
				Segments = 4,
				SegmentType = "Box",
				Diameter = 0.3,
				Parent = folder,
				Props = { Color = blue, Material = Enum.Material.Metal },
				ExistingParts = parts,
			})
			for _, part in parts do
				t.expect(part.Color).toBe(blue)
			end
		end)
	end)
end
