--!strict

local TestTypes = require("./TestTypes")
local RopeGraph = require("./RopeGraph")
local buildRope = require("./buildRope")

-- Fixtures live far from the origin so they can't collide with user content.
local kRegion = Vector3.new(6000, 20, -400)

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

	local function makeRope(folder: Instance, a: Vector3, b: Vector3, props: buildRope.RopeProps?, sag: number?): { BasePart }
		return buildRope({
			PointA = a,
			PointB = b,
			Sag = sag or 2,
			Segments = 8,
			SegmentType = "Cylinder",
			Diameter = 0.4,
			Parent = folder,
			Props = props,
		})
	end

	t.test("getSegmentInfo reads a cylinder's axis and endpoints", function()
		withFolder(function(folder)
			local part = Instance.new("Part")
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(4, 0.4, 0.4)
			part.CFrame = CFrame.new(kRegion)
			part.Anchored = true
			part.Parent = folder
			local info = RopeGraph.getSegmentInfo(part)
			assert(info)
			t.expect(info.kind).toBe("Cylinder")
			t.expect(nearV(info.e1, kRegion - Vector3.new(2, 0, 0), 0.001)).toBeTruthy()
			t.expect(nearV(info.e2, kRegion + Vector3.new(2, 0, 0), 0.001)).toBeTruthy()
			t.expect(math.abs(info.diameter - 0.4) < 0.001).toBeTruthy()
		end)
	end)

	t.test("getSegmentInfo rejects non-elongated and non-Part instances", function()
		withFolder(function(folder)
			local cube = Instance.new("Part")
			cube.Size = Vector3.new(2, 2, 2)
			cube.CFrame = CFrame.new(kRegion)
			cube.Anchored = true
			cube.Parent = folder
			t.expect(RopeGraph.getSegmentInfo(cube)).toBe(nil)
			t.expect(RopeGraph.getSegmentInfo(folder)).toBe(nil)
		end)
	end)

	t.test("discoverRope walks a built chain end to end from any seed", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 4, 0)
			local parts = makeRope(folder, a, b)
			-- Seed from the middle of the chain.
			local rope = RopeGraph.discoverRope(parts[4])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(8)
			t.expect(#rope.path).toBe(9)
			local polyline = RopeGraph.ropePolyline(rope)
			-- The polyline spans A..B (order may be either way).
			local first = polyline[1]
			local last = polyline[#polyline]
			local spansAB = (nearV(first, a, 0.05) and nearV(last, b, 0.05))
				or (nearV(first, b, 0.05) and nearV(last, a, 0.05))
			t.expect(spansAB).toBeTruthy()
			-- The ordered parts are exactly the built chain (as a set).
			local ropeParts = RopeGraph.ropeParts(rope)
			t.expect(#ropeParts).toBe(8)
			local built: { [BasePart]: boolean } = {}
			for _, p in parts do
				built[p] = true
			end
			for _, p in ropeParts do
				t.expect(built[p]).toBeTruthy()
			end
		end)
	end)

	t.test("discovery does not leak onto a touching rope with different properties", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local c = kRegion + Vector3.new(40, 0, 0)
			local parts1 = makeRope(folder, a, b, { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric })
			-- Continues from b, but with a different color AND material (2 of 4
			-- properties differ, below the match threshold).
			makeRope(folder, b, c, { Color = Color3.new(0, 0, 1), Material = Enum.Material.Metal })
			local rope = RopeGraph.discoverRope(parts1[1])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(8)
		end)
	end)

	t.test("matching tangent-continuous ropes chain together through a shared endpoint", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local c = kRegion + Vector3.new(40, 0, 0)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			-- Straight (sag 0) so the joined chain is smooth at the meeting
			-- point; two sagging spans would form a W and stay separate.
			local parts1 = makeRope(folder, a, b, props, 0)
			makeRope(folder, b, c, props, 0)
			local rope = RopeGraph.discoverRope(parts1[1])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(16)
		end)
	end)

	t.test("W-shaped meeting ropes stay separate thanks to the curvature flip", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local c = kRegion + Vector3.new(40, 0, 0)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			-- Two identical sagging spans sharing endpoint b: a hanging curve
			-- turns consistently upward, but at b the turn reverses -- so the
			-- chain must break there even though every property matches.
			local parts1 = makeRope(folder, a, b, props)
			local parts2 = makeRope(folder, b, c, props)
			local rope1 = RopeGraph.discoverRope(parts1[4])
			assert(rope1)
			t.expect(#rope1.chainEdges).toBe(8)
			local polyline1 = RopeGraph.ropePolyline(rope1)
			local spansAB = (nearV(polyline1[1], a, 0.05) and nearV(polyline1[#polyline1], b, 0.05))
				or (nearV(polyline1[1], b, 0.05) and nearV(polyline1[#polyline1], a, 0.05))
			t.expect(spansAB).toBeTruthy()
			-- Seeding right next to the junction still trims correctly.
			local rope2 = RopeGraph.discoverRope(parts2[1])
			assert(rope2)
			t.expect(#rope2.chainEdges).toBe(8)
		end)
	end)

	t.test("discovery does not continue through a steep joint into a post", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			-- Deep sag: the rope leaves b climbing at ~39 degrees.
			local parts = buildRope({
				PointA = a,
				PointB = b,
				Sag = 4,
				Segments = 8,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
				Props = props,
			})
			-- A property-matched "post" standing straight up from the rope's
			-- endpoint. The joint bend (~51 degrees) continues the rope's turn
			-- direction (so the reversal check can't catch it), but it is far
			-- outside any real curve's per-joint bend: the absolute cap must
			-- keep the post out of the chain.
			local post = Instance.new("Part")
			post.Shape = Enum.PartType.Cylinder
			post.Size = Vector3.new(8, 0.4, 0.4)
			post.Color = Color3.new(1, 0, 0)
			post.Material = Enum.Material.Fabric
			post.Anchored = true
			post.CFrame = CFrame.new(b + Vector3.new(0, 4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			post.Parent = folder

			local rope = RopeGraph.discoverRope(parts[1])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(8)
			-- Seeding from the post finds just the post, not the rope.
			local postRope = RopeGraph.discoverRope(post)
			assert(postRope)
			t.expect(#postRope.chainEdges).toBe(1)
		end)
	end)

	t.test("parallel side-by-side ropes stay separate", function()
		withFolder(function(folder)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			local parts1 = makeRope(folder, kRegion, kRegion + Vector3.new(20, 0, 0), props)
			-- One diameter away sideways: touching, but endpoint distance exceeds
			-- the join tolerance.
			makeRope(folder, kRegion + Vector3.new(0, 0, 0.4), kRegion + Vector3.new(20, 0, 0.4), props)
			local rope = RopeGraph.discoverRope(parts1[1])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(8)
		end)
	end)
end
