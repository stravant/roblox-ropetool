local Workspace = game:GetService("Workspace")

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)

local ALWAYS_ON_TOP = true

-- The sphere drawn at a grabbable point, and how far around it hitTests reach.
-- Sized against the arrow handles (MoveHandleView): their shafts begin at
-- 0.6 * scale from the center, so the hit radius stays inside that.
local BASE_VISUAL_RADIUS = 0.22
local BASE_HOVER_RADIUS = 0.3
local BASE_HITTEST_RADIUS = 0.45

local kHandleId = "GrabPoint"

-- A single freely-draggable point handle (the sphere at a rope endpoint).
-- Unlike MoveHandles' axis arrows, a drag is not constrained to an axis: each
-- mouseDrag asks the owner to resolve the mouse ray to a new world position
-- (raycast + snapping), so the point follows the cursor onto scene geometry.
--
-- props:
--   GetPosition: () -> Vector3?         -- nil hides the handle
--   ResolveTarget: (mouseRay: Ray) -> Vector3?  -- cursor ray -> new position (with snapping)
--   StartTransform: () -> ()
--   ApplyTarget: (position: Vector3) -> ()
--   EndTransform: () -> ()
--   Visible: (() -> boolean)?
--   Color: Color3?
local GrabPointHandle = {}
GrabPointHandle.__index = GrabPointHandle

function GrabPointHandle.new(draggerContext, props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._position = nil
	self._scale = 1
	self._dragging = false
	return setmetatable(self, GrabPointHandle)
end

function GrabPointHandle:update(draggerToolModel, selectionInfo)
	if self._dragging then
		return
	end
	local visible = not selectionInfo:isEmpty()
		and (self._props.Visible == nil or self._props.Visible())
	local position = if visible then self._props.GetPosition() else nil
	self._position = position
	if position then
		self._scale = self._draggerContext:getHandleScale(position)
	end
end

function GrabPointHandle:shouldBiasTowardsObjects()
	return false
end

function GrabPointHandle:hitTest(mouseRay, _ignoreExtraThreshold)
	local position = self._position
	if not position then
		return nil
	end
	local radius = self._scale * BASE_HITTEST_RADIUS
	local direction = mouseRay.Direction.Unit
	local toCenter = position - mouseRay.Origin
	local along = toCenter:Dot(direction)
	if along <= 0 then
		return nil
	end
	local perpendicular = (toCenter - direction * along).Magnitude
	if perpendicular <= radius then
		return kHandleId, along, ALWAYS_ON_TOP
	end
	return nil
end

function GrabPointHandle:render(hoveredHandleId)
	local position = self._position
	if not position then
		return nil
	end
	local hovered = self._dragging or hoveredHandleId == kHandleId
	local radius = self._scale * (if hovered then BASE_HOVER_RADIUS else BASE_VISUAL_RADIUS)
	return Roact.createElement("SphereHandleAdornment", {
		Adornee = Workspace.Terrain,
		CFrame = CFrame.new(position),
		ZIndex = 0,
		Radius = radius,
		Color3 = self._props.Color or Color3.fromRGB(255, 200, 50),
		Transparency = if hovered then 0 else 0.25,
		AlwaysOnTop = ALWAYS_ON_TOP,
	})
end

function GrabPointHandle:mouseDown(_mouseRay, _handleId)
	self._dragging = true
	self._props.StartTransform()
end

function GrabPointHandle:mouseDrag(mouseRay)
	local target = self._props.ResolveTarget(mouseRay)
	if target then
		self._position = target
		self._props.ApplyTarget(target)
	end
end

function GrabPointHandle:mouseUp(_mouseRay)
	self._dragging = false
	self._props.EndTransform()
end

return GrabPointHandle
