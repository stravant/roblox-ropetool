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

-- A polyline drawn as a chain of cylinders. Interior joints overlap by half
-- a radius on each side so the bends show no wedge gaps; the two outer ends
-- can be inset (EndInset) to leave room for the endpoint grab dots.
local function PolylineAdornment(props: {
	Points: { Vector3 }?,
	Color: Color3,
	Radius: number,
	Transparency: number?,
	EndInset: number?,
})
	local points = props.Points
	if not points or #points < 2 then
		return nil
	end
	local n = #points
	local firstPoint = points[1]
	local lastPoint = points[n]
	local inset = props.EndInset or 0
	if inset > 0 then
		-- Pull each outer end toward its neighbour, keeping some of the
		-- outermost segment so short ropes don't lose it entirely.
		local firstSpan = points[2] - firstPoint
		if firstSpan.Magnitude > 0.001 then
			firstPoint += firstSpan.Unit * math.min(inset, firstSpan.Magnitude * 0.6)
		end
		local lastSpan = points[n - 1] - lastPoint
		if lastSpan.Magnitude > 0.001 then
			lastPoint += lastSpan.Unit * math.min(inset, lastSpan.Magnitude * 0.6)
		end
	end
	local children: { [string]: any } = {}
	for i = 1, n - 1 do
		local a = if i == 1 then firstPoint else points[i]
		local b = if i == n - 1 then lastPoint else points[i + 1]
		local length = (b - a).Magnitude
		if length > 0.001 then
			local direction = (b - a) / length
			-- Overlap into interior joints only, not past the outer ends.
			local startExtend = if i > 1 then props.Radius / 2 else 0
			local endExtend = if i < n - 1 then props.Radius / 2 else 0
			local center = (a - direction * startExtend + b + direction * endExtend) / 2
			children["Seg" .. i] = e("CylinderHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAt(center, center + direction),
				Height = length + startExtend + endExtend,
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

	-- The selection highlight stops short of the two ends: the endpoint grab
	-- dots already mark them, and the line running into the dots was noisy.
	children.SelectedHighlight = e(PolylineAdornment, {
		Points = props.SelectedPolyline,
		Color = SELECTED_COLOR,
		Radius = highlightRadius(props.SelectedDiameter),
		EndInset = math.max(0.8, (props.SelectedDiameter or 0.3) * 2),
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
