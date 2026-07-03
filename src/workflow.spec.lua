--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local TestTypes = require("./TestTypes")
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
		Diameter = 0.3,
		RopeColor = { 0.412, 0.251, 0.157 },
		RopeMaterial = "Fabric",
		RopeMaterialVariant = "",
		RopeEyedropper = "None",
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

	t.test("dragging a handle on a single part converts it to a 4-segment rope", function()
		withSession(function(session, settings)
			settings.Mode = "Move"
			-- A lone elongated part: a 1-segment "rope".
			local part = Instance.new("Part")
			part.Size = Vector3.new(8, 0.5, 0.5)
			part.CFrame = CFrame.new(kRegionCenter + Vector3.new(0, 10, 0))
			part.Anchored = true
			part.Parent = workspace
			-- Checkpoint the setup so the undo below reverts only the drag, not
			-- the part's creation.
			ChangeHistoryService:SetWaypoint("RopeToolTestSetup")

			t.expect(session.SelectRopeFromPart(part)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)

			-- Grabbing a handle splits it immediately so the drag has vertices
			-- to curve, then the sag drag takes effect on the split rope.
			session.StartHandleDrag("Sag")
			t.expect(session.GetSelectedInfo().Segments).toBe(4)
			session.ApplyHandleDrag(Vector3.new(0, -1.5, 0))
			session.EndHandleDrag()

			local info = session.GetSelectedInfo()
			t.expect(info.Segments).toBe(4)
			t.expect(near(info.Sag, 1.5, 0.05)).toBeTruthy()

			-- Rediscovery from scratch agrees with the tracked selection.
			session.Deselect()
			t.expect(session.SelectRopeFromPart(part)).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(4)
			t.expect(near(session.GetSelectedInfo().Sag, 1.5, 0.05)).toBeTruthy()

			-- One undo reverts the whole drag, including the split.
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.HasSelection()).toBeTruthy()
			t.expect(session.GetSelectedInfo().Segments).toBe(1)
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
