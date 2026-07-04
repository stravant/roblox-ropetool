--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local DraggerFramework = require(Packages.DraggerFramework)
local DraggerSchemaCore = require(Packages.DraggerSchemaCore)
local Geometry = require(Packages.Geometry)
local Roact = require(Packages.Roact)
local Signal = require(Packages.Signal)

local DraggerContext_PluginImpl = (require :: any)(DraggerFramework.Implementation.DraggerContext_PluginImpl)
local DraggerToolComponent = (require :: any)(DraggerFramework.DraggerTools.DraggerToolComponent)
local GrabPointHandle = require("./Dragger/GrabPointHandle")
local MoveHandles = require("./Dragger/MoveHandles")

local Settings = require("./Settings")
local RopeGraph = require("./RopeGraph")
local buildRope = require("./buildRope")
local ropeCurve = require("./ropeCurve")

-- Spherecast fallback radius for Move-mode targeting: rope segments are thin,
-- so a near-miss ray should still find them.
local kSpherecastRadius = 2

-- Screen-space radius within which an Add click snaps onto a corner/edge of
-- the part under the cursor.
local kSnapPixels = 24

-- A point on the ground plane ~20 studs in front of the camera, used to place
-- Add points over empty space; falls back to the world origin.
local function groundPointAhead(): Vector3
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector3.zero
	end
	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = if flatLook.Magnitude > 0.01 then flatLook.Unit else Vector3.zAxis
	local pos = camera.CFrame.Position + flatLook * 20
	return Vector3.new(pos.X, 0, pos.Z)
end

local function mouseRaycast(screenPos: Vector2?): RaycastResult?
	local mouseLocation = screenPos or UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return workspace:Raycast(ray.Origin, ray.Direction * 10000)
end

-- Spherecast along the cursor ray, optionally excluding already-tried parts,
-- for loose targeting of thin rope parts.
local function cursorSpherecast(screenPos: Vector2?, exclude: { Instance }?): RaycastResult?
	local mouseLocation = screenPos or UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude or {}
	return workspace:Spherecast(ray.Origin, kSpherecastRadius, ray.Direction * 1000, params)
end

-- Distance from a ray (unit direction, t >= 0) to a segment [a, b].
local function rayToSegmentDistance(origin: Vector3, direction: Vector3, a: Vector3, b: Vector3): number
	local seg = b - a
	local segLenSq = seg:Dot(seg)
	local w0 = origin - a
	local s: number
	if segLenSq < 1e-9 then
		s = 0
	else
		local uv = direction:Dot(seg)
		local denom = segLenSq - uv * uv
		if math.abs(denom) < 1e-9 then
			s = 0 -- parallel: any point works, clamping handles the rest
		else
			s = math.clamp((seg:Dot(w0) - direction:Dot(w0) * uv) / denom, 0, 1)
		end
	end
	local t = math.max(0, direction:Dot(a + seg * s - origin))
	-- One refinement pass after clamping t, for endpoints behind the camera.
	if segLenSq >= 1e-9 then
		s = math.clamp((origin + direction * t - a):Dot(seg) / segLenSq, 0, 1)
		t = math.max(0, direction:Dot(a + seg * s - origin))
	end
	return (origin + direction * t - (a + seg * s)).Magnitude
end

-- Minimal distance from the cursor ray to a rope's polyline: how close the
-- user is pointing to that rope as a whole.
local function rayToPolylineDistance(origin: Vector3, direction: Vector3, polyline: { Vector3 }): number
	local best = math.huge
	for i = 1, #polyline - 1 do
		best = math.min(best, rayToSegmentDistance(origin, direction, polyline[i], polyline[i + 1]))
	end
	return best
end

local function createCFrameDraggerSchema(isEmptyFunc, getBoundingBoxFunc)
	local schema = table.clone(DraggerSchemaCore)
	schema.getMouseTarget = function()
		return nil
	end
	schema.addUndoWaypoint = function()
		-- Noop: we manage undo recording ourselves
	end
	schema.SelectionInfo = {
		new = function(_context, _selection)
			return {
				isEmpty = function(_self)
					return isEmptyFunc()
				end,
				getBoundingBox = function(_self)
					return getBoundingBoxFunc()
				end,
				getAllAttachments = function(_self)
					return {}
				end,
				getObjectsToTransform = function(_self)
					return {}, {}, {}
				end,
				getBasisObject = function(_self)
					return nil
				end,
				getOriginalCFrameMap = function(_self)
					return {}
				end,
				getTransformedCopy = function(_self, _globalTransform)
					return _self
				end,
			}
		end,
	} :: any
	return schema
end

local function createFixedSelection()
	local selectionChangedSignal = Signal.new()
	return {
		Get = function()
			return { workspace.Terrain }
		end,
		Set = function(_newSelection, _hint)
			task.defer(function()
				selectionChangedSignal:Fire()
			end)
		end,
		SelectionChanged = selectionChangedSignal,
	}
end

local function createRopeSession(plugin: Plugin, currentSettings: Settings.RopeToolSettings)
	local session = {}
	local changeSignal = Signal.new()

	-- The selected rope, reduced to the canonical editing parameters the
	-- draggers and panel operate on. Derived from a discovered rope at select
	-- time; kept up to date through every rebuild.
	type SelectedRope = {
		parts: { BasePart }, -- chain order
		caps: { BasePart }, -- sphere endcaps (empty when none)
		polyline: { Vector3 }, -- chain vertex positions, A to B
		pointA: Vector3,
		pointB: Vector3,
		sag: number,
		sway: number,
		segments: number,
		segmentType: string, -- "Box" | "Cylinder"
		diameter: number,
		haveEndcaps: boolean,
		color: Color3,
		material: Enum.Material,
		materialVariant: string,
		parent: Instance,
	}

	local mSelected: SelectedRope? = nil

	-- Hover state (Move mode). The part set and pick key gate re-discovery:
	-- while the cursor stays on the same part (or another part of the same
	-- rope) no new discovery walk runs. The pick key is the first thing the
	-- cursor ray/sphere met last frame ("none" for empty space).
	local mHoverPolyline: { Vector3 }? = nil
	local mHoverParts: { [BasePart]: boolean } = {}
	local mHoverPickKey: any = nil
	-- Cursor position at the last pick: an unchanged pick key only skips
	-- re-picking while the cursor stays put, because the lenient pick depends
	-- on the cursor position too (the same background part can be the key
	-- while the cursor moves from near one rope to near another).
	local mHoverPickPos: Vector2? = nil

	-- Add tool state
	local mAddFirstPoint: Vector3? = nil
	local mAddHoverPoint: Vector3? = nil
	local mAddHoverSnapped = false

	-- Input / drag state
	local mIsOverUI = false
	local mIsDraggingHandle = false
	local mDragTarget: string? = nil -- "A" | "B" | "Sag"
	local mDragStartA: Vector3? = nil
	local mDragStartB: Vector3? = nil
	local mDragStartSag: number? = nil
	local mDragStartSway: number? = nil
	local mDragRecording: string? = nil
	local queryMouseOverHandle: (() -> boolean)? = nil

	local function getRopeProps(): buildRope.RopeProps
		local c = currentSettings.RopeColor
		return {
			Color = Color3.new(c[1], c[2], c[3]),
			Material = (Enum.Material :: any)[currentSettings.RopeMaterial] or Enum.Material.Fabric,
			MaterialVariant = currentSettings.RopeMaterialVariant,
		}
	end

	----------------------------------------------------------------------
	-- Selection
	----------------------------------------------------------------------

	-- Round noisy derived values so the panel shows clean numbers and the
	-- settings-vs-selection comparison isn't defeated by float dust.
	local function roundTo(value: number, step: number): number
		return math.round(value / step) * step
	end

	local function syncSettingsFromSelection(sel: SelectedRope)
		currentSettings.Segments = sel.segments
		currentSettings.Sag = roundTo(sel.sag, 0.01)
		currentSettings.Sway = roundTo(sel.sway, 0.01)
		currentSettings.SegmentType = sel.segmentType
		currentSettings.Diameter = roundTo(sel.diameter, 0.01)
		currentSettings.HaveEndcaps = sel.haveEndcaps
		currentSettings.RopeColor = { sel.color.R, sel.color.G, sel.color.B }
		currentSettings.RopeMaterial = sel.material.Name
		currentSettings.RopeMaterialVariant = sel.materialVariant
	end

	local function deriveSelectionFromRope(rope: RopeGraph.Rope): SelectedRope?
		local polyline = RopeGraph.ropePolyline(rope)
		local parts = RopeGraph.ropeParts(rope)
		if #polyline < 2 or #parts < 1 then
			return nil
		end
		local parent: Instance = parts[1].Parent or workspace
		return {
			parts = parts,
			caps = table.clone(rope.caps),
			polyline = polyline,
			pointA = polyline[1],
			pointB = polyline[#polyline],
			sag = ropeCurve.estimateSag(polyline),
			sway = ropeCurve.estimateSway(polyline),
			segments = #parts,
			segmentType = if rope.kind == "Cylinder" then "Cylinder" else "Box",
			diameter = rope.diameter,
			haveEndcaps = #rope.caps > 0,
			color = rope.color,
			material = rope.material,
			materialVariant = rope.materialVariant,
			parent = parent,
		}
	end

	-- Forward-declared: defined with the rest of the hover handling below.
	local clearHover: () -> boolean

	local function deselect()
		if mSelected then
			mSelected = nil
			-- Reset the hover gating so the ex-selection becomes hoverable
			-- again without the cursor having to leave it first.
			clearHover()
			changeSignal:Fire()
		end
	end

	local function selectRope(rope: RopeGraph.Rope): boolean
		local sel = deriveSelectionFromRope(rope)
		if not sel then
			return false
		end
		mSelected = sel
		-- Drop any hover highlight (it usually covers the just-selected rope,
		-- and would draw over the selection highlight).
		clearHover()
		syncSettingsFromSelection(sel)
		changeSignal:Fire()
		return true
	end

	local function selectRopeFromPart(part: Instance): boolean
		local rope = RopeGraph.discoverRope(part)
		if not rope then
			return false
		end
		return selectRope(rope)
	end

	-- Selection leniency: the rope pick shared by hover and click. A "good"
	-- direct raycast hit wins unambiguously: either a significant rope
	-- (>= kSignificantSegments) or a chain containing a convincingly OBLONG
	-- part (a stick/post is clearly what the user is pointing at, even as a
	-- 1-segment chain). Only when the direct hit is nothing, or a barely-
	-- elongated slab that merely passes the segment check, does the pick
	-- DRILL through everything in the cursor's sphere corridor -- excluding
	-- each hit and casting again -- collecting every distinct rope, then take
	-- the significant rope whose polyline passes closest to the cursor ray.
	-- With no significant candidate the direct hit keeps priority, then the
	-- nearest small candidate.
	local kSignificantSegments = 3
	local kMaxSphereDrills = 8
	-- Length at least this many times the widest cross dimension reads as
	-- genuinely rope-like rather than a generic elongated part.
	local kOblongAspect = 4
	local function ropeIsOblong(rope: RopeGraph.Rope): boolean
		for _, part in RopeGraph.ropeParts(rope) do
			local info = RopeGraph.getSegmentInfo(part)
			if info and info.aspect >= kOblongAspect then
				return true
			end
		end
		return false
	end
	local function pickRopeAt(screenPos: Vector2?): (RopeGraph.Rope?, BasePart?)
		local result = mouseRaycast(screenPos)
		local directPart = if result and result.Instance:IsA("BasePart") then result.Instance :: BasePart else nil
		local directRope = if directPart then RopeGraph.discoverRope(directPart) else nil
		if directRope and (#directRope.chainEdges >= kSignificantSegments or ropeIsOblong(directRope)) then
			return directRope, directPart
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return directRope, directPart
		end
		local mouseLocation = screenPos or UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local rayDirection = ray.Direction.Unit

		type Candidate = { rope: RopeGraph.Rope, part: BasePart, distance: number }
		local candidates: { Candidate } = {}
		-- Parts already accounted for by some candidate rope, so further hits
		-- on the same rope neither re-discover nor duplicate it.
		local knownParts: { [BasePart]: boolean } = {}
		local function noteCandidate(rope: RopeGraph.Rope, part: BasePart)
			for _, p in RopeGraph.ropeParts(rope) do
				knownParts[p] = true
			end
			for _, cap in rope.caps do
				knownParts[cap] = true
			end
			table.insert(candidates, {
				rope = rope,
				part = part,
				distance = rayToPolylineDistance(ray.Origin, rayDirection, RopeGraph.ropePolyline(rope)),
			})
		end
		if directRope and directPart then
			noteCandidate(directRope, directPart)
		end

		local exclude: { Instance } = if directPart then { directPart } else {}
		for _ = 1, kMaxSphereDrills do
			local sphereResult = cursorSpherecast(screenPos, exclude)
			if not sphereResult then
				break
			end
			if sphereResult.Instance:IsA("BasePart") then
				local spherePart = sphereResult.Instance :: BasePart
				if not knownParts[spherePart] then
					local sphereRope = RopeGraph.discoverRope(spherePart)
					if sphereRope and #sphereRope.chainEdges >= 1 then
						noteCandidate(sphereRope, spherePart)
					end
				end
			end
			table.insert(exclude, sphereResult.Instance)
		end

		local bestSignificant: Candidate? = nil
		local bestAny: Candidate? = nil
		for _, candidate in candidates do
			if not bestAny or candidate.distance < bestAny.distance then
				bestAny = candidate
			end
			if #candidate.rope.chainEdges >= kSignificantSegments then
				if not bestSignificant or candidate.distance < bestSignificant.distance then
					bestSignificant = candidate
				end
			end
		end
		if bestSignificant then
			return bestSignificant.rope, bestSignificant.part
		end
		if directRope then
			return directRope, directPart
		end
		if bestAny then
			return bestAny.rope, bestAny.part
		end
		return nil, nil
	end

	----------------------------------------------------------------------
	-- Rebuilding
	----------------------------------------------------------------------

	-- Rebuild the selected rope's parts in place from its current parameters,
	-- reusing the existing parts (repositioned, not recreated) so per-frame
	-- drag rebuilds are cheap and part identity is stable.
	local function rebuildSelected(sel: SelectedRope)
		sel.parts, sel.caps = buildRope({
			PointA = sel.pointA,
			PointB = sel.pointB,
			Sag = sel.sag,
			Sway = sel.sway,
			Segments = sel.segments,
			SegmentType = sel.segmentType,
			Diameter = sel.diameter,
			HaveEndcaps = sel.haveEndcaps,
			Parent = sel.parent,
			Props = {
				Color = sel.color,
				Material = sel.material,
				MaterialVariant = sel.materialVariant,
			},
			ExistingParts = sel.parts,
			ExistingCaps = sel.caps,
		})
		-- Box mode drops the caps even when requested; reflect what was built.
		sel.haveEndcaps = #sel.caps > 0
		sel.polyline = ropeCurve.computePoints(sel.pointA, sel.pointB, sel.sag, sel.segments, sel.sway)
	end

	-- A single-part "rope" splits into segments only once it actually needs
	-- them to show a curve: the moment its sag becomes nonzero (a straight
	-- single part is left alone -- endpoint drags just move/resize it). Called
	-- wherever the sag can change, before the rebuild; the split lands inside
	-- that edit's recording, so one undo reverts both together.
	local function applySinglePartSplit(sel: SelectedRope)
		if sel.segments == 1 and (math.abs(sel.sag) > 1e-3 or math.abs(sel.sway) > 1e-3) then
			sel.segments = 4
		end
	end

	-- Run a one-shot edit inside a ChangeHistory recording, committing only
	-- if body() reports a change.
	local function runUndoableOperation(name: string, body: () -> boolean): boolean
		local recording = ChangeHistoryService:TryBeginRecording(name)
		local changed = body()
		if changed then
			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			else
				ChangeHistoryService:SetWaypoint(name)
			end
		elseif recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		end
		return changed
	end

	-- Whether the panel settings have diverged from the selected rope's
	-- parameters (i.e. the user edited a field while a rope is selected).
	local function settingsDifferFromSelection(sel: SelectedRope): boolean
		if currentSettings.Segments ~= sel.segments then
			return true
		end
		if currentSettings.SegmentType ~= sel.segmentType then
			return true
		end
		if currentSettings.HaveEndcaps ~= sel.haveEndcaps then
			return true
		end
		if math.abs(currentSettings.Sag - sel.sag) > 0.005 then
			return true
		end
		if math.abs(currentSettings.Sway - sel.sway) > 0.005 then
			return true
		end
		if math.abs(currentSettings.Diameter - sel.diameter) > 0.005 then
			return true
		end
		local c = currentSettings.RopeColor
		if
			math.abs(c[1] - sel.color.R) > 0.002
			or math.abs(c[2] - sel.color.G) > 0.002
			or math.abs(c[3] - sel.color.B) > 0.002
		then
			return true
		end
		if currentSettings.RopeMaterial ~= sel.material.Name then
			return true
		end
		if currentSettings.RopeMaterialVariant ~= sel.materialVariant then
			return true
		end
		return false
	end

	-- Apply the panel settings to the selected rope as one undoable edit.
	local function applySettingsToSelection()
		local sel = mSelected
		if not sel or mIsDraggingHandle then
			return
		end
		if not settingsDifferFromSelection(sel) then
			return
		end
		runUndoableOperation("RopeTool Edit Rope", function(): boolean
			sel.segments = math.max(1, math.round(currentSettings.Segments))
			sel.segmentType = currentSettings.SegmentType
			sel.haveEndcaps = currentSettings.HaveEndcaps
			sel.sag = currentSettings.Sag
			sel.sway = currentSettings.Sway
			sel.diameter = math.max(0.01, currentSettings.Diameter)
			local c = currentSettings.RopeColor
			sel.color = Color3.new(c[1], c[2], c[3])
			sel.material = (Enum.Material :: any)[currentSettings.RopeMaterial] or Enum.Material.Fabric
			sel.materialVariant = currentSettings.RopeMaterialVariant
			applySinglePartSplit(sel)
			rebuildSelected(sel)
			return true
		end)
		-- The single-part split may have raised the segment count past what the
		-- panel asked for; reflect what was actually built.
		currentSettings.Segments = sel.segments
		changeSignal:Fire()
	end

	----------------------------------------------------------------------
	-- Add tool
	----------------------------------------------------------------------

	-- Screen-space distance from a reference viewport point to a world position;
	-- math.huge when unprojectable (behind the camera, or no camera).
	local function screenDistance(cursor: Vector2?, worldPos: Vector3): number
		local camera = workspace.CurrentCamera
		if not camera or not cursor then
			return math.huge
		end
		local projected = camera:WorldToViewportPoint(worldPos)
		if projected.Z <= 0 then
			return math.huge
		end
		return (Vector2.new(projected.X, projected.Y) - cursor).Magnitude
	end

	-- Snap a clicked/hovered position onto the nearest corner vertex of the
	-- part it landed on, falling back to the nearest point on the part's
	-- nearest edge -- so rope endpoints land exactly on structure corners.
	-- MeshParts/Unions have no analytic corners, so they use the blackbox
	-- closest-mesh-edge finder (borrowed from GapFill).
	-- cursorScreen is the true cursor position when known; tests that drive by
	-- world position fall back to projecting worldPos.
	-- World-space query radius that comfortably covers the screen-space snap
	-- radius at the point's depth.
	local function snapQueryRadius(worldPos: Vector3): number
		local camera = workspace.CurrentCamera
		if not camera then
			return 2
		end
		local distance = (worldPos - camera.CFrame.Position).Magnitude
		return math.clamp(distance * 0.06, 1, 30)
	end

	-- A rope endpoint within this many diameters (of the rope being placed or
	-- dragged) of the target point wins outright over any other snap
	-- candidate: at that range, attaching the ropes together is almost always
	-- the intent, even when some part corner is nearer on screen.
	local kEndpointPriorityDiameters = 2

	local function snapAddPosition(
		worldPos: Vector3,
		part: BasePart?,
		cursorScreen: Vector2?,
		ropeDiameter: number,
		excludeParts: { [BasePart]: boolean }?
	): (Vector3, boolean)
		local camera = workspace.CurrentCamera
		local cursor = cursorScreen
		if not cursor and camera then
			local projected = camera:WorldToViewportPoint(worldPos)
			if projected.Z > 0 then
				cursor = Vector2.new(projected.X, projected.Y)
			end
		end

		local endpoints = RopeGraph.findRopeEndpointsNear(worldPos, snapQueryRadius(worldPos), excludeParts)

		-- Priority pass: the nearest rope endpoint within the world-space
		-- priority radius beats everything else.
		local priorityRadius = ropeDiameter * kEndpointPriorityDiameters
		local bestPriority: Vector3? = nil
		local bestPriorityDist = priorityRadius
		for _, endpoint in endpoints do
			local dist = (endpoint - worldPos).Magnitude
			if dist <= bestPriorityDist then
				bestPriorityDist = dist
				bestPriority = endpoint
			end
		end
		if bestPriority then
			return bestPriority, true
		end

		-- Tier 1: one pool of point candidates by screen distance -- the
		-- (farther) endpoints of nearby ropes competing with the hit part's
		-- corners.
		local bestPos: Vector3? = nil
		local bestDist = kSnapPixels
		local function offerPoint(candidate: Vector3)
			local dist = screenDistance(cursor, candidate)
			if dist < bestDist then
				bestDist = dist
				bestPos = candidate
			end
		end

		for _, endpoint in endpoints do
			offerPoint(endpoint)
		end

		-- MeshParts/Unions have no analytic corners; their nearest mesh edge
		-- (found blackbox-style, borrowed from GapFill) contributes its two
		-- ends to the pool, and serves as the along-edge fallback below.
		local meshEdge: any = nil
		if part and (part:IsA("MeshPart") or part:IsA("UnionOperation")) then
			local viewDirection = if camera then camera.CFrame.LookVector else Vector3.zAxis
			-- blackboxFindClosestMeshEdge wants a RaycastResult; synthesize the
			-- two fields it reads (Instance, Position, Normal) from what we have.
			local normal = (worldPos - part.Position)
			normal = if normal.Magnitude > 0.001 then normal.Unit else Vector3.yAxis
			local fakeHit = { Instance = part, Position = worldPos, Normal = normal }
			local ok, edge = pcall(function()
				return Geometry.blackboxFindClosestMeshEdge(fakeHit :: any, viewDirection)
			end)
			if ok and edge then
				meshEdge = edge
				offerPoint(edge.a)
				offerPoint(edge.b)
			end
		end

		local geom: any = nil
		if part and not meshEdge and not (part:IsA("MeshPart") or part:IsA("UnionOperation")) then
			local ok, result = pcall(function()
				return Geometry.getGeometry(part :: BasePart, worldPos)
			end)
			if ok and result then
				geom = result
				for _, vertex in geom.vertices do
					offerPoint(vertex.position)
				end
			end
		end

		if bestPos then
			return bestPos, true
		end

		-- Tier 2: closest point along the hit part's nearest edge.
		local function offerEdge(a: Vector3, b: Vector3, bestEdgePos: Vector3?, bestEdgeDist: number): (Vector3?, number)
			local seg = b - a
			local lenSq = seg:Dot(seg)
			local t = if lenSq < 0.001 then 0 else math.clamp((worldPos - a):Dot(seg) / lenSq, 0, 1)
			local onEdge = a + seg * t
			local dist = screenDistance(cursor, onEdge)
			if dist < bestEdgeDist then
				return onEdge, dist
			end
			return bestEdgePos, bestEdgeDist
		end
		local bestEdgePos: Vector3? = nil
		local bestEdgeDist = kSnapPixels
		if meshEdge then
			bestEdgePos, bestEdgeDist = offerEdge(meshEdge.a, meshEdge.b, bestEdgePos, bestEdgeDist)
		elseif geom then
			for _, edge in geom.edges do
				bestEdgePos, bestEdgeDist = offerEdge(edge.a, edge.b, bestEdgePos, bestEdgeDist)
			end
		end
		if bestEdgePos then
			return bestEdgePos, true
		end

		return worldPos, false
	end

	-- The cursor projected onto the Add working plane, for clicks/hover over
	-- empty space: a horizontal plane through the first point once placed,
	-- else the ground ahead of the camera.
	local function addProjectedPos(screenPos: Vector2?): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouseLocation = screenPos or UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local planePoint = mAddFirstPoint or groundPointAhead()
		local denom = ray.Direction:Dot(Vector3.yAxis)
		if math.abs(denom) < 1e-4 then
			return nil
		end
		local t = (planePoint - ray.Origin):Dot(Vector3.yAxis) / denom
		if t <= 0 then
			return nil
		end
		return ray.Origin + ray.Direction * t
	end

	local function clearAddState()
		mAddFirstPoint = nil
		mAddHoverPoint = nil
		mAddHoverSnapped = false
	end

	-- Build a new rope between the two picked points using the current panel
	-- settings, as one undoable operation. Each rope gets its own folder.
	local function commitRope(a: Vector3, b: Vector3)
		if (b - a).Magnitude < 0.01 then
			return
		end
		local builtParts: { BasePart } = {}
		runUndoableOperation("RopeTool Add Rope", function(): boolean
			local folder = Instance.new("Folder")
			folder.Name = "Rope"
			folder.Parent = workspace
			builtParts = buildRope({
				PointA = a,
				PointB = b,
				Sag = currentSettings.Sag,
				Sway = currentSettings.Sway,
				Segments = math.max(1, math.round(currentSettings.Segments)),
				SegmentType = currentSettings.SegmentType,
				Diameter = math.max(0.01, currentSettings.Diameter),
				HaveEndcaps = currentSettings.HaveEndcaps,
				Parent = folder,
				Props = getRopeProps(),
			})
			if #builtParts == 0 then
				folder.Parent = nil
				return false
			end
			return true
		end)
		changeSignal:Fire()
	end

	-- One Add click at a picked (already snapped) point: the first anchors the
	-- rope, the second builds it.
	local function handleAddPoint(point: Vector3)
		if not mAddFirstPoint then
			mAddFirstPoint = point
			changeSignal:Fire()
		else
			local a = mAddFirstPoint
			clearAddState()
			commitRope(a, point)
		end
	end

	----------------------------------------------------------------------
	-- Hover
	----------------------------------------------------------------------

	function clearHover(): boolean
		mHoverPickKey = nil
		mHoverPickPos = nil
		if mHoverPolyline ~= nil then
			mHoverPolyline = nil
			mHoverParts = {}
			return true
		end
		return false
	end

	-- Whether the part belongs to the current selection (segments or caps).
	local function isSelectionPart(part: BasePart): boolean
		local sel = mSelected
		if not sel then
			return false
		end
		return table.find(sel.parts, part) ~= nil or table.find(sel.caps, part) ~= nil
	end

	-- Whether a discovered rope IS the current selection (same part set). The
	-- hover highlight is suppressed for it: the selection already shows its own
	-- (yellow) highlight, and the blue hover polyline drawn over the identical
	-- path would visually take over.
	local function ropeIsSelected(rope: RopeGraph.Rope): boolean
		local sel = mSelected
		if not sel or #rope.chainEdges ~= #sel.parts then
			return false
		end
		for _, eid in rope.chainEdges do
			if table.find(sel.parts, rope.edges[eid].part) == nil then
				return false
			end
		end
		return true
	end

	local function updateHover(screenPosOverride: Vector2?)
		-- Leaving Add mode abandons the in-progress rope.
		if currentSettings.Mode ~= "Add" and (mAddFirstPoint or mAddHoverPoint) then
			clearAddState()
			changeSignal:Fire()
		end
		-- Leaving Move mode drops the selection (the panel edits apply to the
		-- selection only in Move mode, so a hidden selection would be a trap).
		if currentSettings.Mode ~= "Move" and mSelected then
			deselect()
		end

		if mIsOverUI or mIsDraggingHandle or (queryMouseOverHandle ~= nil and queryMouseOverHandle()) then
			local changed = clearHover()
			if mAddHoverPoint ~= nil then
				mAddHoverPoint = nil
				changed = true
			end
			if changed then
				changeSignal:Fire()
			end
			return
		end

		if currentSettings.Mode == "Move" then
			-- The pick key: the first thing the cursor ray (or, over empty
			-- space, the cursor sphere) meets. Re-pick only when it changes so
			-- hover isn't re-running discovery every frame.
			local cursorScreen = screenPosOverride or UserInputService:GetMouseLocation()
			local result = mouseRaycast(screenPosOverride)
			local directPart = if result and result.Instance:IsA("BasePart") then result.Instance :: BasePart else nil
			local key: any = directPart
			if not key then
				local sphereResult = cursorSpherecast(screenPosOverride, nil)
				key = if sphereResult then sphereResult.Instance else "none"
			end
			-- An unchanged key only short-circuits while the cursor rests: the
			-- lenient pick's answer depends on the cursor position, not just
			-- what the ray/sphere met first.
			local kRepickPixels = 8
			local cursorMoved = mHoverPickPos == nil or (cursorScreen - mHoverPickPos :: Vector2).Magnitude > kRepickPixels
			if key == mHoverPickKey and not cursorMoved then
				return
			end
			-- Crossing along the already-hovered rope: keep it, no re-pick.
			if typeof(key) == "Instance" and mHoverParts[key :: any] then
				mHoverPickKey = key
				mHoverPickPos = cursorScreen
				return
			end
			-- Over the selected rope: its own highlight covers it, no hover.
			if typeof(key) == "Instance" and isSelectionPart(key :: any) then
				local cleared = clearHover()
				mHoverPickKey = key
				mHoverPickPos = cursorScreen
				if cleared then
					changeSignal:Fire()
				end
				return
			end
			local rope = pickRopeAt(screenPosOverride)
			local changed = false
			if rope and #rope.chainEdges >= 1 and not ropeIsSelected(rope) then
				mHoverPolyline = RopeGraph.ropePolyline(rope)
				mHoverParts = {}
				for _, part in RopeGraph.ropeParts(rope) do
					mHoverParts[part] = true
				end
				for _, cap in rope.caps do
					mHoverParts[cap] = true
				end
				changed = true
			else
				changed = clearHover()
			end
			-- clearHover (here or via mode changes) resets the gating; set it
			-- after so this frame's pick sticks.
			mHoverPickKey = key
			mHoverPickPos = cursorScreen
			if changed then
				changeSignal:Fire()
			end
		elseif currentSettings.Mode == "Add" then
			-- While an eyedropper is active a click samples a color/material
			-- rather than placing a point: hide the snap preview.
			if currentSettings.RopeEyedropper ~= "None" then
				if mAddHoverPoint ~= nil then
					mAddHoverPoint = nil
					mAddHoverSnapped = false
					changeSignal:Fire()
				end
				return
			end
			local result = mouseRaycast(screenPosOverride)
			local cursorScreen = screenPosOverride or UserInputService:GetMouseLocation()
			local newPoint: Vector3? = nil
			local newSnapped = false
			if result and result.Instance:IsA("BasePart") then
				newPoint, newSnapped =
					snapAddPosition(result.Position, result.Instance :: BasePart, cursorScreen, currentSettings.Diameter)
			else
				-- Even over empty space, a nearby rope endpoint can snap.
				local projected = addProjectedPos(screenPosOverride)
				if projected then
					newPoint, newSnapped = snapAddPosition(projected, nil, cursorScreen, currentSettings.Diameter)
				end
			end
			if newPoint ~= mAddHoverPoint or newSnapped ~= mAddHoverSnapped then
				mAddHoverPoint = newPoint
				mAddHoverSnapped = newSnapped
				changeSignal:Fire()
			end
		end
	end

	----------------------------------------------------------------------
	-- Click handling
	----------------------------------------------------------------------

	local function handleClick()
		if mIsOverUI or mIsDraggingHandle then
			return
		end
		local mode = currentSettings.Mode

		-- Eyedropper intercept: sample color or material from the clicked part
		-- into the settings (and through to the selection, if any).
		if currentSettings.RopeEyedropper ~= "None" then
			local result = mouseRaycast()
			local hitPart = if result and result.Instance:IsA("BasePart") then result.Instance :: BasePart else nil
			if hitPart then
				if currentSettings.RopeEyedropper == "Color" then
					local col = hitPart.Color
					local picked = { col.R, col.G, col.B }
					currentSettings.RopeColor = picked
					local found = false
					for _, rc in currentSettings.RecentColors do
						if
							math.abs(rc[1] - picked[1]) < 0.001
							and math.abs(rc[2] - picked[2]) < 0.001
							and math.abs(rc[3] - picked[3]) < 0.001
						then
							found = true
							break
						end
					end
					if not found then
						table.insert(currentSettings.RecentColors, 1, picked)
						while #currentSettings.RecentColors > 8 do
							table.remove(currentSettings.RecentColors)
						end
					end
				elseif currentSettings.RopeEyedropper == "Material" then
					local matName = hitPart.Material.Name
					local variant = hitPart.MaterialVariant
					currentSettings.RopeMaterial = matName
					currentSettings.RopeMaterialVariant = variant
					local recentKey = Settings.EncodeRecentMaterial(matName, variant)
					if not table.find(currentSettings.RecentMaterials, recentKey) then
						table.insert(currentSettings.RecentMaterials, 1, recentKey)
						while #currentSettings.RecentMaterials > 6 do
							table.remove(currentSettings.RecentMaterials)
						end
					end
				end
				currentSettings.RopeEyedropper = "None"
				-- A sampled appearance applies to the selected rope immediately.
				applySettingsToSelection()
				changeSignal:Fire()
			end
			return
		end

		if mode == "Move" then
			local rope = pickRopeAt(nil)
			if not rope or not selectRope(rope) then
				deselect()
			end
		elseif mode == "Add" then
			local result = mouseRaycast()
			local cursorScreen = UserInputService:GetMouseLocation()
			local point: Vector3? = nil
			if result and result.Instance:IsA("BasePart") then
				point = snapAddPosition(result.Position, result.Instance :: BasePart, cursorScreen, currentSettings.Diameter)
			else
				-- Even over empty space, a nearby rope endpoint can snap.
				local projected = addProjectedPos()
				if projected then
					point = snapAddPosition(projected, nil, cursorScreen, currentSettings.Diameter)
				end
			end
			if point then
				handleAddPoint(point)
			end
		end
	end

	----------------------------------------------------------------------
	-- DraggerFramework integration
	----------------------------------------------------------------------

	local fixedSelection = createFixedSelection()

	local draggerContext = DraggerContext_PluginImpl.new(plugin, game, settings(), fixedSelection)
	draggerContext.SetDraggingFunction = function(_isDragging: boolean) end
	draggerContext.DragUpdatedSignal = Signal.new()

	-- The middle handle sits on the curve's midpoint (sag and sway applied).
	local function midHandlePosition(sel: SelectedRope): Vector3
		local position = sel.pointA:Lerp(sel.pointB, 0.5) - Vector3.yAxis * sel.sag
		local swayDir = ropeCurve.swayDirection(sel.pointA, sel.pointB)
		if swayDir then
			position += swayDir * sel.sway
		end
		return position
	end

	local schema = createCFrameDraggerSchema(function(): boolean
		return mSelected == nil or currentSettings.Mode ~= "Move"
	end, function(): (CFrame, Vector3, Vector3)
		local sel = mSelected
		if sel then
			return CFrame.new(sel.pointA:Lerp(sel.pointB, 0.5)), Vector3.zero, Vector3.zero
		end
		return CFrame.identity, Vector3.zero, Vector3.zero
	end)

	local kDragNames = { A = "RopeTool Move Endpoint", B = "RopeTool Move Endpoint", Mid = "RopeTool Adjust Curve" }

	local function startDrag(target: string)
		-- "Sag" is accepted as a legacy alias for the middle handle.
		if target == "Sag" then
			target = "Mid"
		end
		local sel = mSelected
		if not sel then
			return
		end
		mIsDraggingHandle = true
		mDragTarget = target
		mDragStartA = sel.pointA
		mDragStartB = sel.pointB
		mDragStartSag = sel.sag
		mDragStartSway = sel.sway
		mDragRecording = ChangeHistoryService:TryBeginRecording(kDragNames[target] or "RopeTool Edit Rope")
	end

	local function applyDrag(globalTransform: CFrame)
		local sel = mSelected
		if not sel or not mDragTarget then
			return
		end
		local delta = globalTransform.Position
		if mDragTarget == "A" and mDragStartA then
			sel.pointA = mDragStartA + delta
		elseif mDragTarget == "B" and mDragStartB then
			sel.pointB = mDragStartB + delta
		elseif mDragTarget == "Mid" and mDragStartSag then
			-- The middle handle cluster: its vertical pair adjusts sag (down =
			-- more sag), its horizontal pair adjusts sway. MoveHandles
			-- constrains each drag to one axis, so only one actually changes.
			sel.sag = mDragStartSag - delta.Y
			local swayDir = ropeCurve.swayDirection(mDragStartA or sel.pointA, mDragStartB or sel.pointB)
			if swayDir and mDragStartSway then
				sel.sway = mDragStartSway + delta:Dot(swayDir)
			end
		end
		applySinglePartSplit(sel)
		rebuildSelected(sel)
		syncSettingsFromSelection(sel)
		changeSignal:Fire()
	end

	-- A grab drag (the endpoint sphere) moves the endpoint to an absolute
	-- position rather than by an axis delta.
	local function applyDragTargetPosition(position: Vector3)
		local sel = mSelected
		if not sel then
			return
		end
		if mDragTarget == "A" then
			sel.pointA = position
		elseif mDragTarget == "B" then
			sel.pointB = position
		else
			return
		end
		rebuildSelected(sel)
		syncSettingsFromSelection(sel)
		changeSignal:Fire()
	end

	-- The selected rope's parts (segments + caps) as a set, for excluding it
	-- from raycasts and snap candidates while it is being edited.
	local function selectionPartSet(): { [BasePart]: boolean }?
		local sel = mSelected
		if not sel then
			return nil
		end
		local set: { [BasePart]: boolean } = {}
		for _, part in sel.parts do
			set[part] = true
		end
		for _, cap in sel.caps do
			set[cap] = true
		end
		return set
	end

	-- Resolve the cursor ray to a new endpoint position during a grab drag,
	-- with the same snapping as the Add tool: raycast the scene (excluding the
	-- rope's own parts, which follow the cursor), snap to the hit part's
	-- corners/edges and nearby rope endpoints, or fall back to a horizontal
	-- plane through the endpoint's pre-drag position when over empty space
	-- (still snapping to rope endpoints there).
	local function resolveEndpointDragTarget(mouseRay: Ray): Vector3?
		local direction = mouseRay.Direction.Unit
		local excludeSet = selectionPartSet()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local exclude: { Instance } = {}
		if excludeSet then
			for part in excludeSet do
				table.insert(exclude, part)
			end
		end
		params.FilterDescendantsInstances = exclude
		local sel = mSelected
		local dragDiameter = if sel then sel.diameter else currentSettings.Diameter
		local cursorScreen = UserInputService:GetMouseLocation()
		local result = workspace:Raycast(mouseRay.Origin, direction * 10000, params)
		if result and result.Instance:IsA("BasePart") then
			local snapped =
				snapAddPosition(result.Position, result.Instance :: BasePart, cursorScreen, dragDiameter, excludeSet)
			return snapped
		end
		local planePoint = if mDragTarget == "A" then mDragStartA else mDragStartB
		if not planePoint then
			return nil
		end
		local denom = direction:Dot(Vector3.yAxis)
		if math.abs(denom) < 1e-4 then
			return nil
		end
		local t = (planePoint - mouseRay.Origin):Dot(Vector3.yAxis) / denom
		if t <= 0 then
			return nil
		end
		local planePos = mouseRay.Origin + direction * t
		local snapped = snapAddPosition(planePos, nil, cursorScreen, dragDiameter, excludeSet)
		return snapped
	end

	local function endDrag()
		if mDragRecording then
			ChangeHistoryService:FinishRecording(mDragRecording, Enum.FinishRecordingOperation.Commit)
			mDragRecording = nil
		end
		mIsDraggingHandle = false
		mDragTarget = nil
		changeSignal:Fire()
	end

	local function handlesVisible(): boolean
		return currentSettings.Mode == "Move" and mSelected ~= nil
	end

	-- The middle (sag/sway) handles are meaningless on a vertical rope: both
	-- offsets are relative to a horizontal chord direction it doesn't have.
	local function midHandleVisible(): boolean
		local sel = mSelected
		if not sel or not handlesVisible() then
			return false
		end
		return ropeCurve.swayDirection(sel.pointA, sel.pointB) ~= nil
	end

	local endpointAHandles = MoveHandles.new(draggerContext, {
		GetBoundingBox = function()
			local sel = mSelected
			return CFrame.new(if sel then sel.pointA else Vector3.zero), Vector3.zero, Vector3.zero
		end,
		StartTransform = function()
			startDrag("A")
		end,
		ApplyTransform = applyDrag,
		EndTransform = endDrag,
		Visible = handlesVisible,
	})

	local endpointBHandles = MoveHandles.new(draggerContext, {
		GetBoundingBox = function()
			local sel = mSelected
			return CFrame.new(if sel then sel.pointB else Vector3.zero), Vector3.zero, Vector3.zero
		end,
		StartTransform = function()
			startDrag("B")
		end,
		ApplyTransform = applyDrag,
		EndTransform = endDrag,
		Visible = handlesVisible,
	})

	-- The endpoint spheres: freely-draggable grab points with Add-style
	-- snapping, sitting at the center of each endpoint's arrow handles.
	local endpointAGrab = GrabPointHandle.new(draggerContext, {
		GetPosition = function(): Vector3?
			local sel = mSelected
			return if sel then sel.pointA else nil
		end,
		ResolveTarget = resolveEndpointDragTarget,
		StartTransform = function()
			startDrag("A")
		end,
		ApplyTarget = applyDragTargetPosition,
		EndTransform = endDrag,
		Visible = handlesVisible,
	})

	local endpointBGrab = GrabPointHandle.new(draggerContext, {
		GetPosition = function(): Vector3?
			local sel = mSelected
			return if sel then sel.pointB else nil
		end,
		ResolveTarget = resolveEndpointDragTarget,
		StartTransform = function()
			startDrag("B")
		end,
		ApplyTarget = applyDragTargetPosition,
		EndTransform = endDrag,
		Visible = handlesVisible,
	})

	-- The middle handle cluster: the vertical pair adjusts sag, the horizontal
	-- pair (aligned perpendicular to the chord via the oriented bounding box)
	-- adjusts sway.
	local midHandles = MoveHandles.new(draggerContext, {
		GetBoundingBox = function()
			local sel = mSelected
			if not sel then
				return CFrame.identity, Vector3.zero, Vector3.zero
			end
			local position = midHandlePosition(sel)
			local swayDir = ropeCurve.swayDirection(sel.pointA, sel.pointB)
			if not swayDir then
				return CFrame.new(position), Vector3.zero, Vector3.zero
			end
			local frame = CFrame.fromMatrix(position, swayDir, Vector3.yAxis, swayDir:Cross(Vector3.yAxis))
			return frame, Vector3.zero, Vector3.zero
		end,
		StartTransform = function()
			startDrag("Mid")
		end,
		ApplyTransform = applyDrag,
		EndTransform = endDrag,
		Visible = midHandleVisible,
		HandleIds = { "PlusY", "MinusY", "PlusX", "MinusX" },
	})

	-- Report whether the cursor is over any handle, so surface hover hides
	-- (mirrors the dragger's own HoverTracker check).
	queryMouseOverHandle = function(): boolean
		if not handlesVisible() then
			return false
		end
		local ray = draggerContext:getMouseRay()
		return (endpointAHandles:hitTest(ray, false)) ~= nil
			or (endpointBHandles:hitTest(ray, false)) ~= nil
			or (midHandles:hitTest(ray, false)) ~= nil
			or (endpointAGrab:hitTest(ray, false)) ~= nil
			or (endpointBGrab:hitTest(ray, false)) ~= nil
	end

	local rootElement = Roact.createElement(DraggerToolComponent, {
		Mouse = plugin:GetMouse(),
		DraggerContext = draggerContext,
		DraggerSchema = schema,
		DraggerSettings = {
			AllowDragSelect = false,
			AnalyticsName = "RopeTool",
			HandlesList = {
				endpointAHandles,
				endpointBHandles,
				midHandles,
				endpointAGrab,
				endpointBGrab,
			},
		},
	})

	local draggerHandle = Roact.mount(rootElement)

	-- Sync session changes to the dragger (see PolyMap: deferred + re-entrancy
	-- guarded so an undo mid-drag can't recurse).
	local mSelectionSyncScheduled = false
	changeSignal:Connect(function()
		if mIsDraggingHandle or mSelectionSyncScheduled then
			return
		end
		mSelectionSyncScheduled = true
		task.defer(function()
			pcall(function()
				fixedSelection.SelectionChanged:Fire()
			end)
			mSelectionSyncScheduled = false
		end)
	end)

	----------------------------------------------------------------------
	-- Undo/redo
	----------------------------------------------------------------------

	-- Abandon any in-progress drag or half-placed Add when an undo/redo
	-- interrupts it, so stale state can't corrupt the reverted world.
	local function cancelTransientActions()
		if mDragRecording then
			pcall(function()
				ChangeHistoryService:FinishRecording(mDragRecording, Enum.FinishRecordingOperation.Cancel)
			end)
			mDragRecording = nil
		end
		mIsDraggingHandle = false
		mDragTarget = nil
		clearAddState()
	end

	-- Re-derive the selection from the reverted world: discovery is stateless,
	-- so finding any still-parented part of the old selection and re-walking
	-- from it reflects whatever the undo/redo restored. A fully-removed rope
	-- (its Add undone) deselects.
	local function reResolveSelection()
		local sel = mSelected
		if not sel then
			return
		end
		local anchor: BasePart? = nil
		for _, part in sel.parts do
			if part.Parent then
				anchor = part
				break
			end
		end
		if not anchor then
			for _, cap in sel.caps do
				if cap.Parent then
					anchor = cap
					break
				end
			end
		end
		if not anchor then
			mSelected = nil
			return
		end
		local rope = RopeGraph.discoverRope(anchor)
		local newSel = if rope then deriveSelectionFromRope(rope) else nil
		mSelected = newSel
		if newSel then
			syncSettingsFromSelection(newSel)
		end
	end

	local function handleUndoRedo(waypointName: string)
		if not string.find(waypointName, "RopeTool") then
			return
		end
		cancelTransientActions()
		reResolveSelection()
		clearHover()
		changeSignal:Fire()
	end

	local undoCn = ChangeHistoryService.OnUndo:Connect(handleUndoRedo)
	local redoCn = ChangeHistoryService.OnRedo:Connect(handleUndoRedo)

	----------------------------------------------------------------------
	-- Input connections
	----------------------------------------------------------------------

	local inputChangedCn = UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			mIsOverUI = gameProcessed
		end
	end)

	-- Escape cancels the in-progress interaction: a half-placed Add rope, an
	-- active eyedropper, or the current selection.
	local function handleEscape()
		if currentSettings.RopeEyedropper ~= "None" then
			currentSettings.RopeEyedropper = "None"
			changeSignal:Fire()
			return
		end
		if currentSettings.Mode == "Add" and mAddFirstPoint then
			clearAddState()
			changeSignal:Fire()
			return
		end
		if currentSettings.Mode == "Move" and mSelected then
			deselect()
		end
	end

	local inputBeganCn: RBXScriptConnection? = nil
	local delayedBeginCn = task.delay(0, function()
		inputBeganCn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessed then
				handleClick()
			end
			if input.KeyCode == Enum.KeyCode.Escape and not gameProcessed then
				handleEscape()
			end
		end)
	end)

	-- Crosshair cursor while picking points (Add mode or an eyedropper).
	local kPickCursor = "rbxasset://SystemCursors/Cross"
	local kArrowCursor = "rbxasset://SystemCursors/Arrow"
	local mPickMouse = plugin:GetMouse()
	local mLastPickIcon = ""

	local cursorTask = task.spawn(function()
		while true do
			updateHover()

			local picking = currentSettings.Mode == "Add" or currentSettings.RopeEyedropper ~= "None"
			local wantIcon = if picking then kPickCursor else kArrowCursor
			if wantIcon ~= mLastPickIcon then
				mLastPickIcon = wantIcon
				mPickMouse.Icon = wantIcon
			end

			task.wait()
		end
	end)

	local function teardown()
		cancelTransientActions()
		Roact.unmount(draggerHandle)
		inputChangedCn:Disconnect()
		undoCn:Disconnect()
		redoCn:Disconnect()
		if inputBeganCn then
			inputBeganCn:Disconnect()
		end
		task.cancel(delayedBeginCn)
		task.cancel(cursorTask)
		mPickMouse.Icon = kArrowCursor -- restore the arrow cursor (not a blank icon)
	end

	----------------------------------------------------------------------
	-- Public API
	----------------------------------------------------------------------

	session.ChangeSignal = changeSignal
	session.Update = function()
		fixedSelection.SelectionChanged:Fire()
		-- A panel edit while a rope is selected applies to the rope.
		if currentSettings.Mode == "Move" then
			applySettingsToSelection()
		end
	end
	session.Destroy = function()
		teardown()
	end

	session.GetMode = function(): string
		return currentSettings.Mode
	end

	-- Accessors for the UI/overlay
	session.GetHoverPolyline = function(): { Vector3 }?
		return mHoverPolyline
	end
	session.GetSelectedPolyline = function(): { Vector3 }?
		local sel = mSelected
		return if sel then sel.polyline else nil
	end
	session.HasSelection = function(): boolean
		return mSelected ~= nil
	end
	session.GetSelectedInfo = function(): {
		PointA: Vector3,
		PointB: Vector3,
		Sag: number,
		Sway: number,
		Segments: number,
		SegmentType: string,
		Diameter: number,
		HaveEndcaps: boolean,
		Parts: { BasePart },
		Caps: { BasePart },
	}?
		local sel = mSelected
		if not sel then
			return nil
		end
		return {
			PointA = sel.pointA,
			PointB = sel.pointB,
			Sag = sel.sag,
			Sway = sel.sway,
			Segments = sel.segments,
			SegmentType = sel.segmentType,
			Diameter = sel.diameter,
			HaveEndcaps = sel.haveEndcaps,
			Parts = table.clone(sel.parts),
			Caps = table.clone(sel.caps),
		}
	end
	session.GetAddFirstPoint = function(): Vector3?
		return mAddFirstPoint
	end
	session.GetAddHoverPoint = function(): (Vector3?, boolean)
		return mAddHoverPoint, mAddHoverSnapped
	end
	-- The preview polyline for the rope being added: from the anchored first
	-- point to the hover point, with the current settings' sag/segments.
	session.GetAddPreviewPoints = function(): { Vector3 }?
		local a = mAddFirstPoint
		local b = mAddHoverPoint
		if not a or not b or (b - a).Magnitude < 0.01 then
			return nil
		end
		return ropeCurve.computePoints(
			a,
			b,
			currentSettings.Sag,
			math.max(1, math.round(currentSettings.Segments)),
			currentSettings.Sway
		)
	end

	-- Actions / programmatic drivers (used by tests and scriptability)
	session.SelectRopeFromPart = function(part: Instance): boolean
		return selectRopeFromPart(part)
	end
	session.Deselect = function()
		deselect()
	end
	-- Drive one Add click at a world position, as if the cursor were there.
	-- Pass hitPart when the click lands on geometry (enables corner snapping).
	session.AddClickAt = function(worldPos: Vector3, hitPart: BasePart?)
		local point = snapAddPosition(worldPos, hitPart, nil, currentSettings.Diameter)
		handleAddPoint(point)
	end
	session.ApplySettingsToSelection = function()
		applySettingsToSelection()
	end

	-- Drive the interactive handle drags in phases, as the 3D draggers do live.
	session.StartHandleDrag = function(target: string)
		startDrag(target)
	end
	session.ApplyHandleDrag = function(delta: Vector3)
		applyDrag(CFrame.new(delta))
	end
	-- Drive a grab drag (the endpoint sphere) to a world position, with the
	-- same snapping as Add. Pass hitPart when the position lands on geometry.
	session.ApplyHandleDragTo = function(worldPos: Vector3, hitPart: BasePart?)
		local sel = mSelected
		local dragDiameter = if sel then sel.diameter else currentSettings.Diameter
		local target = snapAddPosition(worldPos, hitPart, nil, dragDiameter, selectionPartSet())
		applyDragTargetPosition(target)
	end
	session.EndHandleDrag = function()
		endDrag()
	end
	session.IsHandleDragging = function(): boolean
		return mIsDraggingHandle
	end
	-- Whether the middle (sag/sway) handles are shown for the current
	-- selection (hidden for vertical ropes, which have no meaningful sag or
	-- sway direction).
	session.IsSagHandleShown = function(): boolean
		return midHandleVisible()
	end

	-- Test hooks
	session.DebugHoverAt = function(screenPos: Vector2)
		updateHover(screenPos)
	end
	-- Run the Move-mode click's rope pick (with leniency) at a viewport position.
	session.DebugSelectAt = function(screenPos: Vector2): boolean
		local rope = pickRopeAt(screenPos)
		if rope and selectRope(rope) then
			return true
		end
		deselect()
		return false
	end
	session.DebugEscape = function()
		handleEscape()
	end
	session.DebugClick = function()
		handleClick()
	end

	return session
end

export type RopeSession = typeof(createRopeSession(...))

return createRopeSession
