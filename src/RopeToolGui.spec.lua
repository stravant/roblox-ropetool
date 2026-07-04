--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local RopeToolGui = require("./RopeToolGui")
local Settings = require("./Settings")
local TestTypes = require("./TestTypes")

local e = React.createElement

local ALL_MODES = { "Move", "Add", "Color" }

local function makeSettings(mode: string): Settings.RopeToolSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = mode,
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
		RecentMaterials = { "Fabric", "Plastic", "Metal" },
		RecentColors = { { 0.412, 0.251, 0.157 } },
	}
end

return function(t: TestTypes.TestContext)
	for _, mode in ALL_MODES do
		t.test(`renders without error in {mode} mode`, function()
			local screen = Instance.new("ScreenGui")
			screen.Name = "$RopeToolGuiTest"
			screen.Parent = CoreGui

			local settings = makeSettings(mode)
			local root = ReactRoblox.createRoot(screen)

			-- This will throw if the element tree is malformed
			local ok, err = pcall(function()
				ReactRoblox.act(function()
					root:render(e(RopeToolGui, {
						GuiState = "active" :: any,
						CurrentSettings = settings,
						UpdatedSettings = function() end,
						HandleAction = function() end,
						Panelized = false,
						Session = nil,
					}))
				end)
			end)

			-- Clean up before asserting so we don't leak on failure
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
end
