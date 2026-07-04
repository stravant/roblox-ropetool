--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local RopeOverlay = require("./RopeOverlay")
local TestTypes = require("./TestTypes")

local e = React.createElement

return function(t: TestTypes.TestContext)
	t.test("renders highlights and add preview without error", function()
		local screen = Instance.new("ScreenGui")
		screen.Name = "$RopeOverlayTest"
		screen.Parent = CoreGui

		local base = Vector3.new(7000, 10, 0)
		local root = ReactRoblox.createRoot(screen)
		local ok, err = pcall(function()
			ReactRoblox.act(function()
				root:render(e(RopeOverlay, {
					HoverPolyline = { base, base + Vector3.new(4, -1, 0), base + Vector3.new(8, 0, 0) },
					SelectedPolyline = { base + Vector3.new(0, 4, 0), base + Vector3.new(8, 4, 0) },
					AddFirstPoint = base + Vector3.new(0, 8, 0),
					AddHoverPoint = base + Vector3.new(8, 8, 0),
					AddHoverSnapped = true,
					AddPreviewPoints = { base + Vector3.new(0, 8, 0), base + Vector3.new(4, 7, 0), base + Vector3.new(8, 8, 0) },
				}))
			end)
		end)

		ReactRoblox.act(function()
			root:unmount()
		end)
		screen:Destroy()

		if not ok then
			t.fail(tostring(err))
		end
		t.expect(ok).toBe(true)
	end)

	t.test("renders with no props without error", function()
		local screen = Instance.new("ScreenGui")
		screen.Parent = CoreGui
		local root = ReactRoblox.createRoot(screen)
		local ok, err = pcall(function()
			ReactRoblox.act(function()
				root:render(e(RopeOverlay, {}))
			end)
		end)
		ReactRoblox.act(function()
			root:unmount()
		end)
		screen:Destroy()
		if not ok then
			t.fail(tostring(err))
		end
		t.expect(ok).toBe(true)
	end)
end
