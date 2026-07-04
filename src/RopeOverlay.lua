--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local VertexMarker = require("./VertexMarker")

local e = React.createElement

local HOVER_COLOR = Color3.fromRGB(100, 150, 255)
local SELECTED_COLOR = Color3.fromRGB(255, 200, 50)
local ADD_PREVIEW_COLOR = Color3.fromRGB(50, 200, 50)
local SNAP_MARKER_COLOR = Color3.fromRGB(50, 255, 50)
local FREE_MARKER_COLOR = Color3.fromRGB(220, 220, 220)

-- The hover/selected highlight radius: an opaque always-on-top core line at
-- half the rope's width, drawn along the center line -- reads clearly at any
-- rope size without swallowing the rope (a 1px wireframe got lost; a fatter-
-- than-the-rope sheath was too big).
local function highlightRadius(diameter: number?): number
	return (diameter or 0.3) * 0.25
end

-- A polyline drawn as a chain of cylinders. Each segment is lengthened by
-- one radius (half each end) so consecutive cylinders overlap at the bends
-- instead of showing wedge gaps.
local function PolylineAdornment(props: {
	Points: { Vector3 }?,
	Color: Color3,
	Radius: number,
	Transparency: number?,
})
	local points = props.Points
	if not points or #points < 2 then
		return nil
	end
	local children: { [string]: any } = {}
	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		local length = (b - a).Magnitude
		if length > 0.001 then
			children["Seg" .. i] = e("CylinderHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAt((a + b) / 2, b),
				Height = length + props.Radius,
				Radius = props.Radius,
				Color3 = props.Color,
				Transparency = props.Transparency or 0,
				AlwaysOnTop = true,
				ZIndex = 0,
			})
		end
	end
	return e("Folder", nil, children)
end

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
	HoverDiameter: number?,
	SelectedPolyline: { Vector3 }?,
	SelectedDiameter: number?,
	AddFirstPoint: Vector3?,
	AddHoverPoint: Vector3?,
	AddHoverSnapped: boolean?,
	AddPreviewPoints: { Vector3 }?,
})
	local addPreviewRef = React.useRef(nil :: any)

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
	end)

	local children: { [string]: any } = {}

	-- Hover and selection highlights: cylinder sheaths around the rope.
	children.HoverHighlight = e(PolylineAdornment, {
		Points = props.HoverPolyline,
		Color = HOVER_COLOR,
		Radius = highlightRadius(props.HoverDiameter),
	})

	children.SelectedHighlight = e(PolylineAdornment, {
		Points = props.SelectedPolyline,
		Color = SELECTED_COLOR,
		Radius = highlightRadius(props.SelectedDiameter),
	})

	-- Wireframe adornment for the Add preview curve and first-point cross.
	children.AddPreviewWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = ADD_PREVIEW_COLOR,
		AlwaysOnTop = true,
		ref = addPreviewRef,
	})

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
