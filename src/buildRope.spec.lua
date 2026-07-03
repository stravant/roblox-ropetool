--!strict

local TestTypes = require("./TestTypes")
local buildRope = require("./buildRope")
local RopeGraph = require("./RopeGraph")

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

	t.test("adjacent segments share endpoints within tolerance", function()
		withFolder(function(folder)
			local parts = buildRope({
				PointA = kRegion,
				PointB = kRegion + Vector3.new(16, 0, 8),
				Sag = 3,
				Segments = 6,
				SegmentType = "Box",
				Diameter = 0.3,
				Parent = folder,
			})
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
				t.expect(best < 0.01).toBeTruthy()
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
