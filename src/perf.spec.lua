--!strict

local TestTypes = require("./TestTypes")
local RopeGraph = require("./RopeGraph")
local buildRope = require("./buildRope")

-- Fixtures live far from the origin so they can't collide with user content.
local kRegion = Vector3.new(6000, 20, -900)

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
	-- Budgets are deliberately generous (5-10x observed) so slow machines
	-- don't flake; they exist to catch algorithmic regressions (the endpoint
	-- scan was O(n^2) over collected segments before the spatial grid).
	t.test("discovery and endpoint scans stay fast in segment-dense scenes", function()
		sweepRegion()
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local ok, err = pcall(function()
			-- Four parallel dense ropes: 200 stubby segments in one area.
			local middleParts: { BasePart }? = nil
			for i = 1, 4 do
				local a = kRegion + Vector3.new(-10, 0, (i - 1) * 3)
				local parts = buildRope({
					PointA = a,
					PointB = a + Vector3.new(20, 0, 0),
					Sag = 2,
					Segments = 50,
					SegmentType = "Cylinder",
					Diameter = 0.5,
					Parent = folder,
				})
				if i == 2 then
					middleParts = parts
				end
			end
			assert(middleParts)

			local startTime = os.clock()
			local rope = RopeGraph.discoverRope(middleParts[25])
			local discoverMs = (os.clock() - startTime) * 1000
			assert(rope)
			t.expect(#rope.chainEdges).toBe(50)
			if discoverMs > 250 then
				t.fail(string.format("discoverRope took %.1fms (budget 250ms)", discoverMs))
			end

			-- The per-hover-frame snap-point scan, collecting all 200 segments.
			local center = kRegion + Vector3.new(0, -1, 4.5)
			startTime = os.clock()
			for _ = 1, 10 do
				RopeGraph.findRopeSnapPointsNear(center, 30, nil)
			end
			local scanMs = (os.clock() - startTime) * 100
			if scanMs > 25 then
				t.fail(string.format("findRopeSnapPointsNear took %.2fms per call (budget 25ms)", scanMs))
			end
		end)
		folder:Destroy()
		sweepRegion()
		if not ok then
			error(err)
		end
	end)
end
