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
	end)

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
	end)

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
