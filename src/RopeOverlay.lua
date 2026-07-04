--!strict

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local VertexMarker = require("./VertexMarker")

local e = React.createElement

-- The DraggerFramework's handle scale (DraggerContext_PluginImpl), replicated
-- so the hover endpoint balls size exactly like the selection's grab-point
-- handles rather than being a fixed world size.
local kHandleScaleFactor = 0.05
local kEndBallBaseRadius = 0.22 -- GrabPointHandle's BASE_VISUAL_RADIUS
local function handleScaleAt(point: Vector3): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end
	local distance = (camera.CFrame.Position - point).Magnitude
	return math.sin(math.rad(camera.FieldOfView)) * distance * kHandleScaleFactor
end

local HOVER_COLOR = Color3.fromRGB(100, 150, 255)
local SELECTED_COLOR = Color3.fromRGB(255, 200, 50)
local ADD_PREVIEW_COLOR = Color3.fromRGB(50, 200, 50)
local SNAP_MARKER_COLOR = Color3.fromRGB(50, 255, 50)
local FREE_MARKER_COLOR = Color3.fromRGB(220, 220, 220)

local function drawPolyline(wire: WireframeHandleAdornment, points: { Vector3 })
	for i = 1, #points - 1 do
		wire:AddLine(points[i], points[i + 1])
	end
end

local function drawCross(wire: WireframeHandleAdornment, p: Vector3)
	local s = 0.4
	wire:AddLine(p - Vector3.new(s, 0, 0), p + Vector3.new(s, 0, 0))
	wire:AddLine(p - Vector3.new(0, s, 0), p + Vector3.new(0, s, 0))
	wire:AddLine(p - Vector3.new(0, 0, s), p + Vector3.new(0, 0, s))
end

local function RopeOverlay(props: {
	HoverPolyline: { Vector3 }?,
	SelectedPolyline: { Vector3 }?,
	AddFirstPoint: Vector3?,
	AddHoverPoint: Vector3?,
	AddHoverSnapped: boolean?,
	AddPreviewPoints: { Vector3 }?,
})
	local hoverRef = React.useRef(nil :: any)
	local selectedRef = React.useRef(nil :: any)
	local addPreviewRef = React.useRef(nil :: any)

	-- Depth-scaled hover end balls track camera movement via a binding (as in
	-- PolyMap's VertexMarkers): a camera move bumps the tick, which recomputes
	-- the radii directly with no re-render, synchronously in the same frame.
	local hasHoverEnds = props.HoverPolyline ~= nil and #props.HoverPolyline >= 2
	local cameraTick, setCameraTick = React.useBinding(0)
	React.useEffect(function()
		if not hasHoverEnds then
			return
		end
		local n = 0
		local lastCF: CFrame? = nil
		local conn = RunService.RenderStepped:Connect(function()
			local camera = workspace.CurrentCamera
			if camera and camera.CFrame ~= lastCF then
				lastCF = camera.CFrame
				n += 1
				setCameraTick(n)
			end
		end)
		return function()
			conn:Disconnect()
		end
	end, { hasHoverEnds } :: { any })

	local function handleMatchedRadius(position: Vector3)
		return cameraTick:map(function()
			return kEndBallBaseRadius * handleScaleAt(position)
		end)
	end

	-- Each wireframe redraws only when its polyline actually changes (the
	-- session hands out stable tables, replaced on real changes), not on
	-- every unrelated re-render.
	local hoverPolyline = props.HoverPolyline
	React.useEffect(function()
		local wire = hoverRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()
		if hoverPolyline then
			drawPolyline(wire, hoverPolyline)
		end
		return function()
			if wire then
				wire:Clear()
			end
		end
	end, { hoverPolyline or false } :: { any })

	local selectedPolyline = props.SelectedPolyline
	React.useEffect(function()
		local wire = selectedRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()
		if selectedPolyline then
			drawPolyline(wire, selectedPolyline)
		end
		return function()
			if wire then
				wire:Clear()
			end
		end
	end, { selectedPolyline or false } :: { any })

	local addPreviewPoints = props.AddPreviewPoints
	local addFirstPoint = props.AddFirstPoint
	React.useEffect(function()
		local wire = addPreviewRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()
		if addFirstPoint then
			drawCross(wire, addFirstPoint)
		end
		if addPreviewPoints then
			drawPolyline(wire, addPreviewPoints)
		end
		return function()
			if wire then
				wire:Clear()
			end
		end
	end, { addFirstPoint or false, addPreviewPoints or false } :: { any })

	local children: { [string]: any } = {}

	children.HoverWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = HOVER_COLOR,
		AlwaysOnTop = true,
		ref = hoverRef,
	})

	children.SelectedWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = SELECTED_COLOR,
		AlwaysOnTop = true,
		ref = selectedRef,
	})

	children.AddPreviewWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = ADD_PREVIEW_COLOR,
		AlwaysOnTop = true,
		ref = addPreviewRef,
	})

	-- Hovered rope endpoint balls: the thin wireframe alone gets lost, the
	-- end markers draw the eye to it. Sized to match the selection's
	-- grab-point handles at any camera distance.
	if hoverPolyline and #hoverPolyline >= 2 then
		children.HoverEndA = e(VertexMarker, {
			Position = hoverPolyline[1],
			Color = HOVER_COLOR,
			Radius = handleMatchedRadius(hoverPolyline[1]),
		})
		children.HoverEndB = e(VertexMarker, {
			Position = hoverPolyline[#hoverPolyline],
			Color = HOVER_COLOR,
			Radius = handleMatchedRadius(hoverPolyline[#hoverPolyline]),
		})
	end

	-- The selected rope's endpoint spheres are rendered by the session's
	-- GrabPointHandle draggers (they're interactive), not here.

	-- Add-mode hover marker: green when snapped onto part geometry.
	if props.AddHoverPoint then
		children.AddHoverMarker = e(VertexMarker, {
			Position = props.AddHoverPoint,
			Color = if props.AddHoverSnapped then SNAP_MARKER_COLOR else FREE_MARKER_COLOR,
			Radius = 0.25,
		})
	end

	return ReactRoblox.createPortal(e("Folder", {
		Name = "$RopeToolOverlay",
		Archivable = false,
	}, children), CoreGui)
end

return RopeOverlay
