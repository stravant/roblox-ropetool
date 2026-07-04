--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local TestTypes = require("./TestTypes")
local buildRope = require("./buildRope")
local createRopeSession = require("./createRopeSession")
local Settings = require("./Settings")

-- Fixtures live far from the origin so they can't collide with user content.
local kRegionCenter = Vector3.new(6000, 10, 200)
local kCameraEye = kRegionCenter + Vector3.new(0, 25, 60)
local kCameraTarget = kRegionCenter

local function makeSettings(): Settings.RopeToolSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = "Add",
		Segments = 10,
		SegmentType = "Cylinder",
		Sag = 2,
		Sway = 0,
		Diameter = 0.3,
		HaveEndcaps = false,
		RopeColor = { 0.412, 0.251, 0.157 },
		RopeMaterial = "Fabric",
		RopeMaterialVariant = "",
		RopeEyedropper = "None",
		SnapRopeEnds = true,
		SnapGeometry = true,
		SelectAfterAdd = false,
		RecentMaterials = { "Fabric", "Plastic", "Metal" },
		RecentColors = { { 0.412, 0.251, 0.157 } },
	}
end

return function(t: TestTypes.TestContext)
	local function nearV(a: Vector3, b: Vector3, tolerance: number): boolean
		return (a - b).Magnitude <= tolerance
	end
	local function near(a: number, b: number, tolerance: number): boolean
		return math.abs(a - b) <= tolerance
	end

	-- Let deferred ChangeHistoryService.OnUndo/OnRedo handlers run before asserting.
	local function settle()
		task.wait()
		task.wait()
	end

	local function sweepRegion()
		local params = OverlapParams.new()
		params.MaxParts = 10000
		for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 200, params) do
			if p:IsA("BasePart") then
				p:Destroy()
			end
		end
		for _, c in workspace:GetChildren() do
			if c:IsA("Folder") and c.Name == "Rope" and #c:GetChildren() == 0 then
				c:Destroy()
			end
		end
	end

	-- All still-parented rope segment parts in the test region.
	local function findRopeParts(): { BasePart }
		local params = OverlapParams.new()
		params.MaxParts = 10000
		local found: { BasePart } = {}
		for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 200, params) do
			if p:IsA("BasePart") and p.Name == "RopeSegment" then
				table.insert(found, p)
			end
		end
		return found
	end

	-- All still-parented rope endcap parts in the test region.
	local function findCapParts(): { BasePart }
		local params = OverlapParams.new()
		params.MaxParts = 10000
		local found: { BasePart } = {}
		for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 200, params) do
			if p:IsA("BasePart") and p.Name == "RopeEndcap" then
				table.insert(found, p)
			end
		end
		return found
	end

	-- Run fn against a fresh session with the camera pinned and the work region
	-- cleaned before and after, so tests are isolated.
	local function withSession(fn: (any, Settings.RopeToolSettings) -> ())
		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		if cam then
			cam.CFrame = CFrame.lookAt(kCameraEye, kCameraTarget)
		end
		sweepRegion()
		ChangeHistoryService:ResetWaypoints()

		local settings = makeSettings()
		local session = createRopeSession(t.plugin, settings)
		local ok, err = pcall(fn, session, settings)

		session.Destroy()
		ChangeHistoryService:ResetWaypoints()
		sweepRegion()
		if cam and savedCF then
			cam.CFrame = savedCF
		end
		if not ok then
			error(err)
		end
	end

	local kPointA = kRegionCenter + Vector3.new(-10, 10, 0)
	local kPointB = kRegionCenter + Vector3.new(10, 10, 0)

	-- Add a rope between the standard test points and return its parts.
	local function addStandardRope(session: any, settings: Settings.RopeToolSettings): { BasePart }
		settings.Mode = "Add"
		session.AddClickAt(kPointA)
		session.AddClickAt(kPointB)
		return findRopeParts()
	end

	-- Whether the selection spans the two given endpoints (in either order).
	local function selectionSpans(session: any, a: Vector3, b: Vector3, tolerance: number): boolean
		local info = session.GetSelectedInfo()
		if not info then
			return false
		end
		return (nearV(info.PointA, a, tolerance) and nearV(info.PointB, b, tolerance))
			or (nearV(info.PointA, b, tolerance) and nearV(info.PointB, a, tolerance))
	end

	t.test("workflow: add a rope with two clicks", function()
		withSession(function(session, settings)
			settings.Mode = "Add"
			session.AddClickAt(kPointA)
			t.expect(nearV(session.GetAddFirstPoint(), kPointA, 0.001)).toBeTruthy()
			session.AddClickAt(kPointB)
			t.expect(session.GetAddFirstPoint()).toBe(nil)

			local parts = findRopeParts()
			t.expect(#parts).toBe(10)
			-- All segments joined into one folder named Rope.
			local folder = parts[1].Parent
			assert(folder)
			t.expect(folder.Name).toBe("Rope")
			for _, p in parts do
				t.expect(p.Parent).toBe(folder)
			end

			-- The built rope is discoverable as one chain spanning A..B.
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[1])).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
			local info = session.GetSelectedInfo()
			t.expect(info.Segments).toBe(10)
			t.expect(near(info.Sag, 2, 0.05)).toBeTruthy()
			t.expect(info.SegmentType).toBe("Cylinder")
		end)
	end)

	t.test("select-after-add hands the new rope to the Move tool", function()
		withSession(function(session, settings)
			settings.Mode = "Add"
			settings.SelectAfterAdd = true
			session.AddClickAt(kPointA)
			session.AddClickAt(kPointB)
			-- The tool switched to Move with the fresh rope selected.
			t.expect(settings.Mode).toBe("Move")
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeTruthy()

			-- Off: Add stays active with no selection, for batch adds.
			settings.SelectAfterAdd = false
			settings.Mode = "Add"
			task.wait() -- let the hover loop drop the selection on entering Add
			session.AddClickAt(kPointA + Vector3.new(0, 6, 0))
			session.AddClickAt(kPointB + Vector3.new(0, 6, 0))
			t.expect(settings.Mode).toBe("Add")
			t.expect(session.HasSelection()).toBeFalsy()
			t.expect(#findRopeParts()).toBe(20)
		end)
	end)

	t.test("workflow: undo and redo of an added rope", function()
		withSession(function(session, settings)
			addStandardRope(session, settings)
			t.expect(#findRopeParts()).toBe(10)

			ChangeHistoryService:Undo()
			settle()
			t.expect(#findRopeParts()).toBe(0)

			ChangeHistoryService:Redo()
			settle()
			t.expect(#findRopeParts()).toBe(10)
		end)
	end)

	t.test("workflow: select and drag an endpoint, then undo", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[3])).toBeTruthy()

			-- Find which handle corresponds to the A end of the rope.
			local info = session.GetSelectedInfo()
			local target = if nearV(info.PointA, kPointA, 0.05) then "A" else "B"

			local delta = Vector3.new(0, 6, -4)
			session.StartHandleDrag(target)
			t.expect(session.IsHandleDragging()).toBeTruthy()
			session.ApplyHandleDrag(delta / 2) -- intermediate drag frame
			session.ApplyHandleDrag(delta)
			session.EndHandleDrag()
			t.expect(session.IsHandleDragging()).toBeFalsy()

			-- The selection tracked the drag, and the parts really moved: a fresh
			-- discovery from scratch sees the new endpoints.
			t.expect(selectionSpans(session, kPointA + delta, kPointB, 0.05)).toBeTruthy()
			session.Deselect()
			t.expect(session.SelectRopeFromPart(parts[3])).toBeTruthy()
			t.expect(selectionSpans(session, kPointA + delta, kPointB, 0.05)).toBeTruthy()

			-- Undo restores the geometry and the selection re-resolves onto it.
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
		end)
	end)

	t.test("workflow: adjust sag with the middle handle, then undo", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[5])).toBeTruthy()
			local startSag = session.GetSelectedInfo().Sag
			t.expect(near(startSag, 2, 0.05)).toBeTruthy()

			-- Dragging the sag handle down increases sag.
			session.StartHandleDrag("Sag")
			session.ApplyHandleDrag(Vector3.new(0, -1.5, 0))
			session.EndHandleDrag()
			t.expect(near(session.GetSelectedInfo().Sag, startSag + 1.5, 0.05)).toBeTruthy()

			-- The middle of the rope actually dropped.
			session.Deselect()
			t.expect(session.SelectRopeFromPart(parts[5])).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sag, startSag + 1.5, 0.05)).toBeTruthy()

			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sag, startSag, 0.05)).toBeTruthy()
		end)
	end)

	t.test("workflow: adjust sway with the middle handle, then undo", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[5])).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sway, 0, 0.05)).toBeTruthy()

			-- The chord runs along X, so the sway axis is Z (sign depends on
			-- the discovered endpoint order); a pure sideways drag on the
			-- middle handle bows the rope without touching the sag.
			session.StartHandleDrag("Mid")
			session.ApplyHandleDrag(Vector3.new(0, 0, 2))
			session.EndHandleDrag()
			t.expect(near(math.abs(session.GetSelectedInfo().Sway), 2, 0.05)).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sag, 2, 0.05)).toBeTruthy()

			-- The rope's middle actually bowed sideways.
			local bowed = false
			for _, p in findRopeParts() do
				if math.abs(p.Position.Z - kPointA.Z) > 1.5 then
					bowed = true
				end
			end
			t.expect(bowed).toBeTruthy()

			-- Rediscovery from scratch agrees.
			session.Deselect()
			t.expect(session.SelectRopeFromPart(parts[5])).toBeTruthy()
			t.expect(near(math.abs(session.GetSelectedInfo().Sway), 2, 0.05)).toBeTruthy()

			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sway, 0, 0.05)).toBeTruthy()
		end)
	end)

	t.test("workflow: a rope with sag far exceeding its span selects from ends and middle", function()
		withSession(function(session, settings)
			-- Sag triple the distance between the endpoints: the bottom joint
			-- bends ~100 degrees, which must read as the curve continuing.
			settings.Mode = "Add"
			settings.Segments = 10
			settings.Sag = 18
			local a = kRegionCenter + Vector3.new(-3, 14, -8)
			local b = a + Vector3.new(6, 0, 0)
			session.AddClickAt(a)
			session.AddClickAt(b)
			local parts = findRopeParts()
			t.expect(#parts).toBe(10)

			local function partNearest(target: Vector3): BasePart
				local best: BasePart? = nil
				local bestDistance = math.huge
				for _, p in parts do
					local distance = (p.Position - target).Magnitude
					if distance < bestDistance then
						best = p
						bestDistance = distance
					end
				end
				return best :: BasePart
			end

			settings.Mode = "Move"
			local bottom = a:Lerp(b, 0.5) - Vector3.new(0, 18, 0)
			for _, seed in { partNearest(a), partNearest(b), partNearest(bottom) } do
				session.Deselect()
				t.expect(session.SelectRopeFromPart(seed)).toBeTruthy()
				local info = session.GetSelectedInfo()
				t.expect(info.Segments).toBe(10)
				t.expect(selectionSpans(session, a, b, 0.05)).toBeTruthy()
				t.expect(near(info.Sag, 18, 0.5)).toBeTruthy()
			end
		end)
	end)

	t.test("workflow: panel edits apply to the selected rope, then undo", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[1])).toBeTruthy()

			-- Edit the segment count, type and color through the settings, as the
			-- panel does, then notify the session.
			settings.Segments = 14
			settings.SegmentType = "Box"
			settings.RopeColor = { 1, 0, 0 }
			session.Update()

			local info = session.GetSelectedInfo()
			t.expect(info.Segments).toBe(14)
			t.expect(info.SegmentType).toBe("Box")
			local newParts = findRopeParts()
			t.expect(#newParts).toBe(14)
			for _, p in newParts do
				t.expect((p :: Part).Shape).toBe(Enum.PartType.Block)
				t.expect(near(p.Color.R, 1, 0.01)).toBeTruthy()
			end

			-- One undo reverts the whole edit.
			ChangeHistoryService:Undo()
			settle()
			t.expect(#findRopeParts()).toBe(10)
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(10)
			t.expect(session.GetSelectedInfo().SegmentType).toBe("Cylinder")
		end)
	end)

	t.test("the Color tool shares the selection with Move and hides the handles", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[3])).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeTruthy()

			-- Switching to Color keeps the selection but hides the handles.
			settings.Mode = "Color"
			session.Update()
			task.wait() -- let the live hover loop process the mode change
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeFalsy()

			-- Appearance edits apply to the shared selection from Color mode.
			settings.RopeColor = { 0, 1, 0 }
			session.Update()
			for _, p in findRopeParts() do
				t.expect(near(p.Color.G, 1, 0.01)).toBeTruthy()
			end

			-- Selecting works in Color mode too, and survives going back to
			-- Move, where the handles reappear.
			session.Deselect()
			t.expect(session.SelectRopeFromPart(parts[5])).toBeTruthy()
			settings.Mode = "Move"
			session.Update()
			task.wait()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeTruthy()

			-- One undo reverts the recolor.
			ChangeHistoryService:Undo()
			settle()
			t.expect(near(findRopeParts()[1].Color.G, 1, 0.01)).toBeFalsy()
		end)
	end)

	t.test("endcaps: cylinder ropes get sphere caps, discoverable and toggleable", function()
		withSession(function(session, settings)
			settings.HaveEndcaps = true
			local parts = addStandardRope(session, settings)
			t.expect(#parts).toBe(10)
			local caps = findCapParts()
			t.expect(#caps).toBe(2)
			-- One cap sits exactly on each rope end.
			local capOnA = nearV(caps[1].Position, kPointA, 0.001) or nearV(caps[2].Position, kPointA, 0.001)
			local capOnB = nearV(caps[1].Position, kPointB, 0.001) or nearV(caps[2].Position, kPointB, 0.001)
			t.expect(capOnA and capOnB).toBeTruthy()

			-- Discovery picks the caps up -- selecting even FROM a cap works.
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(caps[1])).toBeTruthy()
			local info = session.GetSelectedInfo()
			t.expect(info.Segments).toBe(10)
			t.expect(info.HaveEndcaps).toBeTruthy()
			t.expect(#info.Caps).toBe(2)

			-- Dragging an endpoint carries its cap along.
			local target = if nearV(info.PointA, kPointA, 0.05) then "A" else "B"
			session.StartHandleDrag(target)
			session.ApplyHandleDrag(Vector3.new(0, 4, 0))
			session.EndHandleDrag()
			local movedCapFound = false
			for _, cap in findCapParts() do
				if nearV(cap.Position, kPointA + Vector3.new(0, 4, 0), 0.01) then
					movedCapFound = true
				end
			end
			t.expect(movedCapFound).toBeTruthy()

			-- Toggling the setting off removes the caps as one undoable edit.
			settings.HaveEndcaps = false
			session.Update()
			t.expect(#findCapParts()).toBe(0)
			t.expect(session.GetSelectedInfo().HaveEndcaps).toBeFalsy()
			ChangeHistoryService:Undo()
			settle()
			t.expect(#findCapParts()).toBe(2)
			t.expect(session.GetSelectedInfo().HaveEndcaps).toBeTruthy()
		end)
	end)

	t.test("grab-dragging an endpoint snaps to part corners like Add", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			-- A post whose corner the endpoint gets dropped onto.
			local post = Instance.new("Part")
			post.Size = Vector3.new(2, 12, 2)
			post.CFrame = CFrame.new(kRegionCenter + Vector3.new(14, 6, 0))
			post.Anchored = true
			post.Parent = workspace
			-- Checkpoint the setup so the undo below reverts only the drag.
			ChangeHistoryService:SetWaypoint("RopeToolTestSetup")
			local corner = post.Position + Vector3.new(1, 6, 1)

			t.expect(session.SelectRopeFromPart(parts[3])).toBeTruthy()
			local info = session.GetSelectedInfo()
			local target = if nearV(info.PointB, kPointB, 0.05) then "B" else "A"

			-- Drop the endpoint slightly off the post corner: the grab drag
			-- snaps it exactly onto the corner.
			session.StartHandleDrag(target)
			session.ApplyHandleDragTo(corner + Vector3.new(-0.1, -0.15, -0.1), post)
			session.EndHandleDrag()
			t.expect(selectionSpans(session, kPointA, corner, 0.001)).toBeTruthy()

			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
		end)
	end)

	t.test("a single part splits into 4 segments only once it gets nonzero sag", function()
		withSession(function(session, settings)
			settings.Mode = "Move"
			-- A lone elongated part: a 1-segment "rope".
			local part = Instance.new("Part")
			part.Size = Vector3.new(8, 0.5, 0.5)
			part.CFrame = CFrame.new(kRegionCenter + Vector3.new(0, 10, 0))
			part.Anchored = true
			part.Parent = workspace
			-- Checkpoint the setup so the undos below revert only the edits, not
			-- the part's creation.
			ChangeHistoryService:SetWaypoint("RopeToolTestSetup")

			t.expect(session.SelectRopeFromPart(part)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)

			-- An endpoint drag on a straight single part just moves/resizes it.
			local info = session.GetSelectedInfo()
			session.StartHandleDrag("A")
			session.ApplyHandleDrag(Vector3.new(0, 2, 0))
			session.EndHandleDrag()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)
			t.expect(selectionSpans(session, info.PointA + Vector3.new(0, 2, 0), info.PointB, 0.01)).toBeTruthy()

			-- The sag drag splits it, but only once the sag is actually nonzero.
			session.StartHandleDrag("Sag")
			t.expect(session.GetSelectedInfo().Segments).toBe(1)
			session.ApplyHandleDrag(Vector3.new(0, -1.5, 0))
			t.expect(session.GetSelectedInfo().Segments).toBe(4)
			session.EndHandleDrag()

			t.expect(near(session.GetSelectedInfo().Sag, 1.5, 0.05)).toBeTruthy()

			-- Rediscovery from scratch agrees with the tracked selection.
			session.Deselect()
			t.expect(session.SelectRopeFromPart(part)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(4)
			t.expect(near(session.GetSelectedInfo().Sag, 1.5, 0.05)).toBeTruthy()

			-- One undo reverts the whole sag drag, including the split.
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)

			-- Setting a nonzero sag from the panel splits it the same way.
			settings.Sag = 1
			session.Update()
			t.expect(session.GetSelectedInfo().Segments).toBe(4)
			t.expect(settings.Segments).toBe(4)
		end)
	end)

	t.test("hovering the selected rope shows no hover highlight", function()
		withSession(function(session, settings)
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			local camera = workspace.CurrentCamera
			assert(camera)
			-- Aim straight at the rope's lowest point so the ray hits a segment.
			local ropeMid = kRegionCenter + Vector3.new(0, 8, 0)
			local screen = camera:WorldToViewportPoint(ropeMid)
			local screenPos = Vector2.new(screen.X, screen.Y)

			-- Unselected: hover highlights the rope.
			session.DebugHoverAt(screenPos)
			t.expect(session.GetHoverPolyline()).toBeTruthy()

			-- Selected: the hover highlight is suppressed (the selection's own
			-- highlight covers it -- the blue polyline was drawing over the
			-- yellow one).
			t.expect(session.SelectRopeFromPart(parts[1])).toBeTruthy()
			t.expect(session.GetHoverPolyline()).toBe(nil)
			session.DebugHoverAt(screenPos)
			t.expect(session.GetHoverPolyline()).toBe(nil)

			-- Deselected: hover comes back without leaving the rope first.
			session.Deselect()
			session.DebugHoverAt(screenPos)
			t.expect(session.GetHoverPolyline()).toBeTruthy()
		end)
	end)

	t.test("clicking near a rope selects it through selection leniency", function()
		withSession(function(session, settings)
			addStandardRope(session, settings)
			settings.Mode = "Move"
			-- A wall behind the rope, so a near-miss click lands on the wall.
			local wall = Instance.new("Part")
			wall.Size = Vector3.new(40, 30, 1)
			wall.CFrame = CFrame.new(kRegionCenter + Vector3.new(0, 10, -6))
			wall.Anchored = true
			wall.Parent = workspace

			-- Aim just above the rope's midpoint: the ray misses the thin rope,
			-- hits the wall (itself an elongated part, i.e. an insignificant
			-- 1-segment "rope"), and the spherecast retry finds the real rope.
			local camera = workspace.CurrentCamera
			assert(camera)
			local ropeMid = kRegionCenter + Vector3.new(0, 8, 0)
			local aimAt = ropeMid + Vector3.new(0, 1.2, 0)
			local screen = camera:WorldToViewportPoint(aimAt)
			t.expect(screen.Z > 0).toBeTruthy()

			t.expect(session.DebugSelectAt(Vector2.new(screen.X, screen.Y))).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(10)
		end)
	end)

	t.test("the pick drills past nearer ropes to select the one closest to the cursor", function()
		withSession(function(session, settings)
			-- Two parallel ropes 1.6 studs apart in depth (Z, toward the
			-- camera at +Z). Aim between them but clearly nearer rope 1: the
			-- sphere sweep meets rope 2 first (closer to the camera), so a
			-- first-hit pick would wrongly take it.
			addStandardRope(session, settings) -- rope 1 at Z = 0
			-- Rope 2 built directly (an Add click this close would endpoint-
			-- snap onto rope 1).
			buildRope({
				PointA = kPointA + Vector3.new(0, 0, 1.6),
				PointB = kPointB + Vector3.new(0, 0, 1.6),
				Sag = 2,
				Segments = 10,
				SegmentType = "Cylinder",
				Diameter = 0.3,
				Parent = workspace,
			})
			t.expect(#findRopeParts()).toBe(20)

			settings.Mode = "Move"
			local camera = workspace.CurrentCamera
			assert(camera)
			-- Rope midpoints sit at (0, 8, 0) and (0, 8, 1.6) relative to the
			-- region; this aim point is 0.67 from rope 1 and 1.43 from rope 2,
			-- and its ray hits neither directly.
			local aim = kRegionCenter + Vector3.new(0, 8.6, 0.3)
			local screen = camera:WorldToViewportPoint(aim)
			t.expect(screen.Z > 0).toBeTruthy()
			t.expect(session.DebugSelectAt(Vector2.new(screen.X, screen.Y))).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
		end)
	end)

	t.test("a direct hit on an oblong part beats nearby bigger ropes", function()
		withSession(function(session, settings)
			addStandardRope(session, settings) -- significant rope at Z = 0
			-- A clearly rope-like stick right in front of the rope (toward the
			-- camera), well inside the leniency sphere radius.
			local stick = Instance.new("Part")
			stick.Size = Vector3.new(6, 0.4, 0.4)
			stick.CFrame = CFrame.new(kRegionCenter + Vector3.new(0, 8, 1.5))
			stick.Anchored = true
			stick.Parent = workspace

			settings.Mode = "Move"
			local camera = workspace.CurrentCamera
			assert(camera)
			-- Aim dead-on at the stick: pointing directly at a convincingly
			-- oblong part selects it, even though a significant rope is nearby.
			local screen = camera:WorldToViewportPoint(stick.Position)
			t.expect(session.DebugSelectAt(Vector2.new(screen.X, screen.Y))).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)
			t.expect(selectionSpans(
				session,
				stick.Position - Vector3.new(3, 0, 0),
				stick.Position + Vector3.new(3, 0, 0),
				0.05
			)).toBeTruthy()
		end)
	end)

	t.test("hover re-picks when the cursor moves onto a nearer rope", function()
		withSession(function(session, settings)
			addStandardRope(session, settings) -- rope 1 at Z = 0
			buildRope({
				PointA = kPointA + Vector3.new(0, 0, 1.6),
				PointB = kPointB + Vector3.new(0, 0, 1.6),
				Sag = 2,
				Segments = 10,
				SegmentType = "Cylinder",
				Diameter = 0.3,
				Parent = workspace,
			})
			settings.Mode = "Move"
			local camera = workspace.CurrentCamera
			assert(camera)
			local function hoverAt(worldPos: Vector3)
				local screen = camera:WorldToViewportPoint(worldPos)
				session.DebugHoverAt(Vector2.new(screen.X, screen.Y))
			end

			-- Between the ropes, nearer rope 1 (the farther one from the
			-- camera): rope 1 highlights.
			hoverAt(kRegionCenter + Vector3.new(0, 8.6, 0.3))
			local hp = session.GetHoverPolyline()
			t.expect(hp).toBeTruthy()
			t.expect(math.abs(hp[1].Z - kPointA.Z) < 0.5).toBeTruthy()

			-- Directly over rope 2 (nearer the camera): the hover must follow,
			-- even though the pick key (rope 2's part) can be unchanged from
			-- the previous position's sphere sweep.
			hoverAt(kRegionCenter + Vector3.new(0, 8, 1.6))
			hp = session.GetHoverPolyline()
			t.expect(hp).toBeTruthy()
			t.expect(math.abs(hp[1].Z - (kPointA.Z + 1.6)) < 0.5).toBeTruthy()
		end)
	end)

	t.test("add points and grab drags snap to the endpoints of other ropes", function()
		withSession(function(session, settings)
			-- First rope, A..B.
			addStandardRope(session, settings)

			-- A second rope in a different color AND material, so the two stay
			-- separate ropes (enough property mismatches to not chain).
			settings.RopeColor = { 1, 0, 0 }
			settings.RopeMaterial = "Metal"

			-- Add: clicking near the first rope's endpoint snaps onto it
			-- exactly, even over empty space (no hit part).
			settings.Mode = "Add"
			session.AddClickAt(kPointB + Vector3.new(0.3, 0.2, 0))
			t.expect(nearV(session.GetAddFirstPoint(), kPointB, 0.001)).toBeTruthy()
			local pointC = kRegionCenter + Vector3.new(18, 4, 6)
			session.AddClickAt(pointC)
			t.expect(#findRopeParts()).toBe(20)

			-- Grab drag: dragging the second rope's far end near the first
			-- rope's A endpoint snaps onto it exactly (the dragged rope itself
			-- is excluded from the snap candidates).
			settings.Mode = "Move"
			local rope2Part: BasePart? = nil
			for _, p in findRopeParts() do
				if (p.Position - pointC).Magnitude < 3 then
					rope2Part = p
					break
				end
			end
			assert(rope2Part)
			t.expect(session.SelectRopeFromPart(rope2Part)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(10)
			local info = session.GetSelectedInfo()
			local target = if nearV(info.PointA, pointC, 0.05) then "A" else "B"
			session.StartHandleDrag(target)
			session.ApplyHandleDragTo(kPointA + Vector3.new(0.2, 0.25, 0), nil)
			session.EndHandleDrag()
			t.expect(selectionSpans(session, kPointB, kPointA, 0.001)).toBeTruthy()
		end)
	end)

	t.test("snapping settings disable rope-end and geometry snapping", function()
		withSession(function(session, settings)
			addStandardRope(session, settings)
			settings.Mode = "Add"

			-- Rope-end snapping off: a click near the rope's endpoint stays put.
			local aim = kPointB + Vector3.new(0.3, 0.2, 0)
			settings.SnapRopeEnds = false
			session.AddClickAt(aim)
			t.expect(nearV(session.GetAddFirstPoint(), aim, 0.001)).toBeTruthy()
			session.DebugEscape()
			settings.SnapRopeEnds = true
			session.AddClickAt(aim)
			t.expect(nearV(session.GetAddFirstPoint(), kPointB, 0.001)).toBeTruthy()
			session.DebugEscape()

			-- Geometry snapping off: a click near a block corner stays put.
			local post = Instance.new("Part")
			post.Size = Vector3.new(2, 12, 2)
			post.CFrame = CFrame.new(kRegionCenter + Vector3.new(-14, 6, 0))
			post.Anchored = true
			post.Parent = workspace
			local corner = post.Position + Vector3.new(1, 6, 1)
			local aim2 = corner + Vector3.new(-0.15, -0.1, -0.1)
			-- Rope-end snapping off too, so the nearby rope's endpoint can't
			-- catch the click and muddy which tier is being tested.
			settings.SnapRopeEnds = false
			settings.SnapGeometry = false
			session.AddClickAt(aim2, post)
			t.expect(nearV(session.GetAddFirstPoint(), aim2, 0.001)).toBeTruthy()
			session.DebugEscape()
			settings.SnapGeometry = true
			session.AddClickAt(aim2, post)
			t.expect(nearV(session.GetAddFirstPoint(), corner, 0.001)).toBeTruthy()
			session.DebugEscape()
		end)
	end)

	t.test("nearby rope endpoints take priority over closer part corners", function()
		withSession(function(session, settings)
			addStandardRope(session, settings)
			settings.Mode = "Add"
			-- A block whose corner is nearer the aim point on screen than the
			-- rope's B endpoint; corners at kPointB + (0.5, 0, 0) and (1.5, 0, 0).
			local block = Instance.new("Part")
			block.Size = Vector3.new(1, 1, 1)
			block.CFrame = CFrame.new(kPointB + Vector3.new(1, -0.5, 0.5))
			block.Anchored = true
			block.Parent = workspace

			-- Aim 0.1 from the near corner but 0.4 from the endpoint: the
			-- endpoint is inside the priority radius (2 diameters = 0.6), so it
			-- wins over the closer corner.
			session.AddClickAt(kPointB + Vector3.new(0.4, 0, 0), block)
			t.expect(nearV(session.GetAddFirstPoint(), kPointB, 0.001)).toBeTruthy()
			session.DebugEscape()

			-- Beyond the priority radius (1.4 from the endpoint) the flat
			-- screen-distance competition applies: the far corner wins.
			session.AddClickAt(kPointB + Vector3.new(1.4, 0, 0), block)
			t.expect(nearV(session.GetAddFirstPoint(), kPointB + Vector3.new(1.5, 0, 0), 0.001)).toBeTruthy()
		end)
	end)

	t.test("add points snap to the corners of clicked parts", function()
		withSession(function(session, settings)
			settings.Mode = "Add"
			-- A post to attach to, with a known top corner.
			local post = Instance.new("Part")
			post.Size = Vector3.new(2, 12, 2)
			post.CFrame = CFrame.new(kRegionCenter + Vector3.new(-12, 6, 0))
			post.Anchored = true
			post.Parent = workspace
			local corner = post.Position + Vector3.new(1, 6, 1)

			-- Click slightly off the corner: the point snaps onto it exactly.
			session.AddClickAt(corner + Vector3.new(-0.15, -0.1, -0.1), post)
			local firstPoint = session.GetAddFirstPoint()
			t.expect(nearV(firstPoint, corner, 0.001)).toBeTruthy()
		end)
	end)

	t.test("the sag handle is hidden for exactly vertical ropes", function()
		withSession(function(session, settings)
			-- A normal horizontal-ish rope shows the sag handle.
			local parts = addStandardRope(session, settings)
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[1])).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeTruthy()
			session.Deselect()

			-- A straight vertical rope has no sag direction: handle hidden.
			settings.Mode = "Add"
			settings.Sag = 0
			local base = kRegionCenter + Vector3.new(0, 2, 10)
			session.AddClickAt(base)
			session.AddClickAt(base + Vector3.new(0, 12, 0))
			settings.Mode = "Move"
			local verticalPart: BasePart? = nil
			for _, p in findRopeParts() do
				if math.abs(p.Position.X - base.X) < 0.2 and math.abs(p.Position.Z - base.Z) < 0.2 then
					verticalPart = p
					break
				end
			end
			assert(verticalPart)
			t.expect(session.SelectRopeFromPart(verticalPart)).toBeTruthy()
			t.expect(session.IsSagHandleShown()).toBeFalsy()
		end)
	end)

	t.test("the add snap preview hides while an eyedropper is active", function()
		withSession(function(session, settings)
			settings.Mode = "Add"
			local camera = workspace.CurrentCamera
			assert(camera)
			local screen = camera:WorldToViewportPoint(kRegionCenter)
			local screenPos = Vector2.new(screen.X, screen.Y)

			session.DebugHoverAt(screenPos)
			t.expect(session.GetAddHoverPoint()).toBeTruthy()

			settings.RopeEyedropper = "Color"
			session.DebugHoverAt(screenPos)
			t.expect(session.GetAddHoverPoint()).toBe(nil)

			settings.RopeEyedropper = "None"
			session.DebugHoverAt(screenPos)
			t.expect(session.GetAddHoverPoint()).toBeTruthy()
		end)
	end)

	t.test("escape cancels a half-placed rope", function()
		withSession(function(session, settings)
			settings.Mode = "Add"
			session.AddClickAt(kPointA)
			t.expect(session.GetAddFirstPoint()).toBeTruthy()
			session.DebugEscape()
			t.expect(session.GetAddFirstPoint()).toBe(nil)
			t.expect(#findRopeParts()).toBe(0)
		end)
	end)

	t.test("workflow: full add, modify, undo round trip", function()
		withSession(function(session, settings)
			-- Add
			local parts = addStandardRope(session, settings)
			t.expect(#parts).toBe(10)

			-- Modify: endpoint, sag, and a panel edit
			settings.Mode = "Move"
			t.expect(session.SelectRopeFromPart(parts[2])).toBeTruthy()
			local info = session.GetSelectedInfo()
			local target = if nearV(info.PointA, kPointA, 0.05) then "A" else "B"
			session.StartHandleDrag(target)
			session.ApplyHandleDrag(Vector3.new(0, 3, 0))
			session.EndHandleDrag()

			session.StartHandleDrag("Sag")
			session.ApplyHandleDrag(Vector3.new(0, -1, 0))
			session.EndHandleDrag()

			settings.Segments = 12
			session.Update()
			t.expect(#findRopeParts()).toBe(12)

			-- Undo everything back to an empty region.
			ChangeHistoryService:Undo() -- panel edit
			settle()
			t.expect(#findRopeParts()).toBe(10)
			ChangeHistoryService:Undo() -- sag
			settle()
			ChangeHistoryService:Undo() -- endpoint
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(selectionSpans(session, kPointA, kPointB, 0.05)).toBeTruthy()
			t.expect(near(session.GetSelectedInfo().Sag, 2, 0.05)).toBeTruthy()
			ChangeHistoryService:Undo() -- the add itself
			settle()
			t.expect(#findRopeParts()).toBe(0)
			t.expect(session.HasSelection()).toBeFalsy()
		end)
	end)
end
