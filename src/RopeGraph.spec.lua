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

	t.test("dense ropes with segments shorter than their width discover fully", function()
		withFolder(function(folder)
			-- 24 segments over 6 studs at 0.5 diameter: each segment is
			-- stubbier than it is wide, so the rope axis is the dissimilar
			-- (shorter) axis, and joint vertices sit closer together than the
			-- join tolerance.
			for kindIndex, segmentType in { "Cylinder", "Box" } do
				local a = kRegion + Vector3.new(0, 0, 60 + kindIndex * 30)
				local b = a + Vector3.new(6, 0, 0)
				local parts = buildRope({
					PointA = a,
					PointB = b,
					Sag = 1,
					Segments = 24,
					SegmentType = segmentType,
					Diameter = 0.5,
					Parent = folder,
				})
				t.expect(#parts).toBe(24)
				for _, seed in { parts[1], parts[12], parts[24] } do
					local rope = RopeGraph.discoverRope(seed)
					assert(rope)
					t.expect(#rope.chainEdges).toBe(24)
				end
			end
		end)
	end)

	t.test("plates and discs are not segments along their thin axis", function()
		withFolder(function(folder)
			local plate = Instance.new("Part")
			plate.Size = Vector3.new(4, 0.2, 4)
			plate.CFrame = CFrame.new(kRegion + Vector3.new(0, 0, -60))
			plate.Anchored = true
			plate.Parent = folder
			t.expect(RopeGraph.getSegmentInfo(plate)).toBe(nil)

			local disc = Instance.new("Part")
			disc.Shape = Enum.PartType.Cylinder
			disc.Size = Vector3.new(0.2, 4, 4)
			disc.CFrame = CFrame.new(kRegion + Vector3.new(8, 0, -60))
			disc.Anchored = true
			disc.Parent = folder
			t.expect(RopeGraph.getSegmentInfo(disc)).toBe(nil)
		end)
	end)

	t.test("a very droopy rope stays one chain through its steep bottom joint", function()
		withFolder(function(folder)
			-- Sag comparable to the chord with few segments: the bottom joint
			-- bends ~74 degrees -- far past any tight absolute cap, but
			-- consistent with its neighbours (~29 degrees, under the spike
			-- factor), so the chain must hold together.
			local a = kRegion + Vector3.new(0, 10, 60)
			local b = a + Vector3.new(8, 0, 0)
			local parts = buildRope({
				PointA = a,
				PointB = b,
				Sag = 6,
				Segments = 4,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
			})
			local rope = RopeGraph.discoverRope(parts[2])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(4)
		end)
	end)

	t.test("rope endpoints at a steep attachment stay snappable", function()
		withFolder(function(folder)
			local a = kRegion
			local b = kRegion + Vector3.new(20, 0, 0)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			buildRope({
				PointA = a,
				PointB = b,
				Sag = 4,
				Segments = 8,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				Parent = folder,
				Props = props,
			})
			-- A property-matched post standing up from the rope's endpoint b.
			-- Even though post and rope match and meet there, the steep joint
			-- is an attachment, not a chain continuation: b must still be
			-- reported as a rope endpoint (for snapping another rope onto it).
			local post = Instance.new("Part")
			post.Shape = Enum.PartType.Cylinder
			post.Size = Vector3.new(8, 0.4, 0.4)
			post.Color = Color3.new(1, 0, 0)
			post.Material = Enum.Material.Fabric
			post.Anchored = true
			post.CFrame = CFrame.new(b + Vector3.new(0, 4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			post.Parent = folder

			local foundB = false
			for _, endpoint in RopeGraph.findRopeSnapPointsNear(b, 3, nil) do
				if (endpoint - b).Magnitude < 0.05 then
					foundB = true
				end
			end
			t.expect(foundB).toBeTruthy()

			-- A smooth interior joint of the rope is NOT a chain end, but IS
			-- reported as a joint attach point (for mid-rope snapping).
			local mid = kRegion + Vector3.new(10, -4, 0)
			local midEndpoints, midJoints = RopeGraph.findRopeSnapPointsNear(mid, 1.5, nil)
			local foundInterior = false
			for _, endpoint in midEndpoints do
				if (endpoint - mid).Magnitude < 0.5 then
					foundInterior = true
				end
			end
			t.expect(foundInterior).toBeFalsy()
			local foundJoint = false
			for _, joint in midJoints do
				if (joint - mid).Magnitude < 0.1 then
					foundJoint = true
				end
			end
			t.expect(foundJoint).toBeTruthy()
		end)
	end)

	t.test("lone parts must be convincingly stick-like to read as 1-part ropes", function()
		withFolder(function(folder)
			local function makeLone(size: Vector3, offset: Vector3): Part
				local part = Instance.new("Part")
				part.Size = size
				part.CFrame = CFrame.new(kRegion + offset)
				part.Anchored = true
				part.Parent = folder
				return part
			end

			-- A stick (very oblong, square cross) is a 1-part rope.
			local stick = makeLone(Vector3.new(6, 0.4, 0.4), Vector3.new(0, 0, -100))
			local stickRope = RopeGraph.discoverRope(stick)
			assert(stickRope)
			t.expect(#stickRope.chainEdges).toBe(1)

			-- A plank has the length but a flat cross-section: not a rope.
			t.expect(RopeGraph.discoverRope(makeLone(Vector3.new(8, 2, 0.5), Vector3.new(15, 0, -100)))).toBe(nil)

			-- A barely-elongated slab (a wall) has neither: not a rope.
			t.expect(RopeGraph.discoverRope(makeLone(Vector3.new(10, 9, 1), Vector3.new(35, 0, -100)))).toBe(nil)

			-- A square-cross beam that isn't oblong enough: not a rope.
			t.expect(RopeGraph.discoverRope(makeLone(Vector3.new(3, 1, 1), Vector3.new(55, 0, -100)))).toBe(nil)
		end)
	end)

	t.test("endcaps vouch for a lone stubby segment", function()
		withFolder(function(folder)
			-- A 1-segment capped rope too stubby for the lone-part gate on its
			-- own (aspect 2.5): the matching sphere caps mark it as a built
			-- rope, so it stays discoverable (e.g. for reselection).
			local a = kRegion + Vector3.new(0, 0, -130)
			local parts, caps = buildRope({
				PointA = a,
				PointB = a + Vector3.new(1, 0, 0),
				Sag = 0,
				Segments = 1,
				SegmentType = "Cylinder",
				Diameter = 0.4,
				HaveEndcaps = true,
				Parent = folder,
			})
			t.expect(#parts).toBe(1)
			t.expect(#caps).toBe(2)
			local rope = RopeGraph.discoverRope(parts[1])
			assert(rope)
			t.expect(#rope.chainEdges).toBe(1)
			t.expect(#rope.caps).toBe(2)
		end)
	end)

	t.test("plank-like parts still chain into multi-part ropes", function()
		withFolder(function(folder)
			-- Two matching planks end to end: each fails the lone-part gate by
			-- itself, but as a CHAIN the adjacency is the evidence of ropehood,
			-- so the permissive segment thresholds still apply.
			local plank1 = Instance.new("Part")
			plank1.Size = Vector3.new(8, 2, 0.5)
			plank1.CFrame = CFrame.new(kRegion + Vector3.new(0, 0, -160))
			plank1.Anchored = true
			plank1.Parent = folder
			local plank2 = plank1:Clone()
			plank2.CFrame = CFrame.new(kRegion + Vector3.new(8, 0, -160))
			plank2.Parent = folder

			local rope = RopeGraph.discoverRope(plank1)
			assert(rope)
			t.expect(#rope.chainEdges).toBe(2)
		end)
	end)

	t.test("discovery continues through a junction where a matching rope attaches", function()
		withFolder(function(folder)
			local props: buildRope.RopeProps = { Color = Color3.new(1, 0, 0), Material = Enum.Material.Fabric }
			-- Rope A, with rope B (same properties) hung off A's middle joint
			-- at ~90 degrees (B runs off in Z, A in X).
			local a1 = kRegion + Vector3.new(0, 0, -120)
			local b1 = a1 + Vector3.new(20, 0, 0)
			local partsA = makeRope(folder, a1, b1, props)
			local joint = a1 + Vector3.new(10, -2, 0) -- A's mid joint (8 segments, sag 2)
			local partsB = makeRope(folder, joint, joint + Vector3.new(0, 0, 14), props)

			-- A discovers end to end THROUGH the junction from either side:
			-- the attachment must not cut it in half.
			for _, seed in { partsA[2], partsA[7] } do
				local rope = RopeGraph.discoverRope(seed)
				assert(rope)
				t.expect(#rope.chainEdges).toBe(8)
				local polyline = RopeGraph.ropePolyline(rope)
				local spans = (nearV(polyline[1], a1, 0.1) and nearV(polyline[#polyline], b1, 0.1))
					or (nearV(polyline[1], b1, 0.1) and nearV(polyline[#polyline], a1, 0.1))
				t.expect(spans).toBeTruthy()
			end

			-- B stays its own rope: from B's side the junction offers only
			-- ~90 degree turns onto A, so the walk ends there.
			local ropeB = RopeGraph.discoverRope(partsB[4])
			assert(ropeB)
			t.expect(#ropeB.chainEdges).toBe(8)
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
