--!strict

local MaterialService = game:GetService("MaterialService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local PluginGui = require("./PluginGui/PluginGui")
local OperationButton = require("./PluginGui/OperationButton")
local ChipForToggle = require("./PluginGui/ChipForToggle")
local NumberInput = require("./PluginGui/NumberInput")
local Slider = require("./PluginGui/Slider")
local HelpGui = require("./PluginGui/HelpGui")
local OverlayGui = require("./PluginGui/OverlayGui")
local MaterialDropdown = require("./PluginGui/MaterialDropdown")
local Checkbox = require("./PluginGui/Checkbox")
local Settings = require("./Settings")
local PluginGuiTypes = require("./PluginGui/Types")
local RopeOverlay = require("./RopeOverlay")
local createRopeSession = require("./createRopeSession")

local e = React.createElement

-- 60-swatch color palette: 10 grayscale + 5 rows of 10 hues
local kColorPalette: { { number } } = (function()
	local palette: { { number } } = {}
	-- Row 0: grayscale (10 swatches, black to white)
	for i = 0, 9 do
		local v = i / 9
		table.insert(palette, { v, v, v })
	end
	-- Rows 1-5: hues at varying saturation/value
	local rows = {
		{ s = 1.0, v = 1.0 },  -- vivid
		{ s = 0.5, v = 1.0 },  -- pastel
		{ s = 1.0, v = 0.6 },  -- dark
		{ s = 0.7, v = 0.8 },  -- medium
		{ s = 1.0, v = 0.35 }, -- very dark
	}
	for _, row in rows do
		for i = 0, 9 do
			local h = i / 10
			local c3 = Color3.fromHSV(h, row.s, row.v)
			table.insert(palette, { c3.R, c3.G, c3.B })
		end
	end
	return palette
end)()

-- The classic Studio BrickColor picker: BrickColor.palette(0..126) laid out as a
-- hexagonal honeycomb (row widths 7..13..7 = 127 cells), plus a bottom strip of the
-- neutral greys. Extracted cell-for-cell from the Studio picker, then driven live off
-- BrickColor.palette so the colours always match the engine's.
local kBrickHexRows: { { { idx: number, color: { number } } } } = (function()
	local widths = { 7, 8, 9, 10, 11, 12, 13, 12, 11, 10, 9, 8, 7 }
	local rows = {}
	local idx = 0
	for _, w in widths do
		local row = {}
		for _ = 1, w do
			local col = BrickColor.palette(idx).Color
			table.insert(row, { idx = idx, color = { col.R, col.G, col.B } })
			idx += 1
		end
		table.insert(rows, row)
	end
	return rows
end)()

local kBrickStrip: { { idx: number, color: { number } } } = (function()
	local indices = { 127, 122, 123, 108, 49, 97, 3, 10, 29, 50, 75, 86 }
	local strip = {}
	for _, i in indices do
		local col = BrickColor.palette(i).Color
		table.insert(strip, { idx = i, color = { col.R, col.G, col.B } })
	end
	return strip
end)()

local function createNextOrder()
	local order = 0
	return function()
		order += 1
		return order
	end
end

local function colorsMatch(a: { number }, b: { number }): boolean
	return math.abs(a[1] - b[1]) < 0.01
		and math.abs(a[2] - b[2]) < 0.01
		and math.abs(a[3] - b[3]) < 0.01
end

local function getStatusText(
	mode: string,
	_settings: Settings.RopeToolSettings,
	session: createRopeSession.RopeSession?
): string
	if mode == "Move" then
		if session and session.HasSelection() then
			return "Drag the endpoint handles to move the rope's ends, or the middle handle to adjust its sag. The panel edits apply to the selected rope."
		end
		return "Click a rope to select it. Ropes are discovered from chains of matching adjacent parts."
	elseif mode == "Color" then
		if session and session.HasSelection() then
			return "The Color and Material panels apply to the selected rope."
		end
		return "Click a rope to select it, then pick its color and material."
	elseif mode == "Add" then
		if session and session.GetAddFirstPoint() then
			return "Click the second attachment point to build the rope. Escape cancels."
		end
		return "Click the first attachment point. Points snap to nearby part corners and edges."
	elseif mode == "Settings" then
		return "Global options for the tool. Snapping applies to Add clicks and endpoint drags."
	end
	return ""
end

local function StatusText(props: {
	Settings: Settings.RopeToolSettings,
	Session: createRopeSession.RopeSession?,
	LayoutOrder: number?,
})
	if not props.Settings.HaveHelp then
		return nil
	end
	local text = getStatusText(props.Settings.Mode, props.Settings, props.Session)
	if text == "" then
		return nil
	end
	-- Inset the grey background from the container edges so it lines up with the
	-- panels' bordered boxes (SubPanel insets its box by 6px a side).
	local INSET = 6
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, INSET),
			PaddingRight = UDim.new(0, INSET),
		}),
		Label = e("TextLabel", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 0,
			BackgroundColor3 = Colors.GREY,
			BorderSizePixel = 0,
			Font = Enum.Font.SourceSans,
			TextSize = 18,
			TextColor3 = Colors.WHITE,
			RichText = true,
			Text = `<i>{text}</i>`,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}, {
			Padding = e("UIPadding", {
				PaddingTop = UDim.new(0, 2),
				PaddingBottom = UDim.new(0, 2),
				PaddingLeft = UDim.new(0, 4),
				PaddingRight = UDim.new(0, 4),
			}),
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 4),
			}),
		}),
	})
end

local function ModePanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.Mode

	local function modeChip(text: string, modeValue: string, order: number)
		return e(ChipForToggle, {
			Text = text,
			IsCurrent = current == modeValue,
			LayoutOrder = order,
			OnClick = function()
				props.Settings.Mode = modeValue
				props.UpdatedSettings()
			end,
		})
	end

	-- A blank 1/3-width slot so a row's remaining chips stay column-aligned.
	local function emptySlot(order: number)
		return e("Frame", {
			Size = UDim2.new(0, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, {
			Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
		})
	end

	local function row(order: number, children: { [string]: any })
		children.ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		})
		return e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, children)
	end

	return e(SubPanel, {
		Title = "Mode",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		Row1 = row(1, {
			Move = modeChip("Move", "Move", 1),
			Add = modeChip("Add", "Add", 2),
			Color = modeChip("Color", "Color", 3),
		}),
		Row2 = row(2, {
			SettingsChip = modeChip("Settings", "Settings", 1),
			Empty1 = emptySlot(2),
			Empty2 = emptySlot(3),
		}),
	})
end

-- Options specific to the Add tool.
local function AddOptionsPanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Add",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		SelectAfterAdd = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e(Checkbox, {
				Label = "Select After Add",
				Checked = props.Settings.SelectAfterAdd,
				Changed = function(checked: boolean)
					props.Settings.SelectAfterAdd = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "After building a rope, switch to <b>Move</b> with it selected, ready to tweak. Turn off to stay in Add and place several ropes in a row.",
			}),
		}),
	})
end

-- Where a rope's parts live: their own Model or Folder, or ungrouped. Shown
-- for Move and Add: with a rope selected it reflects the selection's guessed
-- grouping and changing it regroups that rope; in Add it configures the next
-- rope (and how a curved single part gets grouped when it splits).
local function GroupingPanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.Grouping

	local function groupChip(text: string, value: string, order: number)
		return e(ChipForToggle, {
			Text = text,
			IsCurrent = current == value,
			LayoutOrder = order,
			OnClick = function()
				props.Settings.Grouping = value
				props.UpdatedSettings()
			end,
		})
	end

	return e(SubPanel, {
		Title = "Grouping",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		Chips = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e("Frame", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Model = groupChip("Model", "Model", 1),
				Folder = groupChip("Folder", "Folder", 2),
				None = groupChip("None", "None", 3),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Group each rope's parts under their own <b>Model</b> or <b>Folder</b>, or leave them loose (<b>None</b>).<br />With a rope selected this shows its guessed grouping, and changing it regroups that rope. In Add mode it applies to the next rope built.",
			}),
		}),
	})
end

-- The global Settings tab: options that aren't tied to a single editing mode.
local function SnappingPanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Snapping",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		RopeEnds = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Rope End",
				Checked = props.Settings.SnapRopeEnds,
				Changed = function(checked: boolean)
					props.Settings.SnapRopeEnds = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Snap placed and dragged rope endpoints onto the ends of nearby ropes, so ropes chain together exactly.",
			}),
		}),
		GeometryEdges = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Geometry Edges",
				Checked = props.Settings.SnapGeometry,
				Changed = function(checked: boolean)
					props.Settings.SnapGeometry = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Snap placed and dragged rope endpoints onto the corners and edges of the part under the cursor.",
			}),
		}),
	})
end

-- The rope's structural parameters. Shown in both modes: in Add they set up the
-- next rope; in Move (with a rope selected) they edit the selection.
local function RopePanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local currentType = props.Settings.SegmentType
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Rope",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		TypeRow = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e("Frame", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Cylinder = e(ChipForToggle, {
					Text = "Cylinder",
					IsCurrent = currentType == "Cylinder",
					LayoutOrder = 1,
					OnClick = function()
						props.Settings.SegmentType = "Cylinder"
						props.UpdatedSettings()
					end,
				}),
				Box = e(ChipForToggle, {
					Text = "Box",
					IsCurrent = currentType == "Box",
					LayoutOrder = 2,
					OnClick = function()
						props.Settings.SegmentType = "Box"
						props.UpdatedSettings()
					end,
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "The part shape used for each rope segment.",
			}),
		}),
		Endcaps = currentType == "Cylinder" and e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Have Endcaps",
				Checked = props.Settings.HaveEndcaps,
				Changed = function(checked: boolean)
					props.Settings.HaveEndcaps = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Round off the rope's two ends with sphere parts (cylinder segments have flat ends).",
			}),
		}),
		Segments = e(NumberInput, {
			Label = "Segments",
			Value = props.Settings.Segments,
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue >= 1 and newValue <= 200 and newValue == math.floor(newValue) then
					props.Settings.Segments = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Diameter = e(NumberInput, {
			Label = "Diameter",
			Value = props.Settings.Diameter,
			Unit = " studs",
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue > 0 then
					props.Settings.Diameter = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Sag = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Sag",
				Value = props.Settings.Sag,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					props.Settings.Sag = newValue
					props.UpdatedSettings()
					return newValue
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How far the middle of the rope hangs below the straight line between its endpoints. Negative values arch upward.",
			}),
		}),
		Sway = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Sway",
				Value = props.Settings.Sway,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					props.Settings.Sway = newValue
					props.UpdatedSettings()
					return newValue
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How far the middle of the rope bows sideways, perpendicular to the line between its endpoints. The sign picks the side.",
			}),
		}),
	})
end

local kSelectRing = Color3.fromRGB(255, 170, 0)

local function colorToHex(c: { number }): string
	return string.format("%02X%02X%02X", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local function hexToColor(s: string): { number }?
	local clean = (s:gsub("[#%s]", ""))
	if #clean ~= 6 or clean:match("[^0-9a-fA-F]") then
		return nil
	end
	return {
		(tonumber(clean:sub(1, 2), 16) or 0) / 255,
		(tonumber(clean:sub(3, 4), 16) or 0) / 255,
		(tonumber(clean:sub(5, 6), 16) or 0) / 255,
	}
end

-- One colour cell. In a UIGridLayout the grid overrides the size; in a UIListLayout
-- (the honeycomb rows) the 15px size is kept.
local function colorCell(color: { number }, isSel: boolean, order: number, onClick: () -> ()): React.ReactElement<any, any>
	return e("TextButton", {
		Size = UDim2.fromOffset(15, 15),
		BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 12,
		[React.Event.MouseButton1Click] = onClick,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 3) }),
		Ring = isSel and e("UIStroke", {
			Color = kSelectRing,
			Thickness = 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			ZIndex = 13,
		}),
	})
end

-- A single centered honeycomb row of cells; consecutive rows differ in count, so
-- centering offsets them by half a cell into the classic honeycomb.
local function honeyRow(cells: { { idx: number, color: { number } } }, order: number, current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 1),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for c, cell in cells do
		kids["C" .. c] = colorCell(cell.color, colorsMatch(current, cell.color), c, function()
			onSelect(cell.color, true)
		end)
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 15),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 12,
	}, kids)
end

local function BrickColorTab(current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 1),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
	}
	for r, row in kBrickHexRows do
		kids["R" .. r] = honeyRow(row, r, current, onSelect)
	end
	kids["Gap"] = e("Frame", { Size = UDim2.new(1, 0, 0, 6), BackgroundTransparency = 1, LayoutOrder = 50 })
	kids["Strip"] = honeyRow(kBrickStrip, 51, current, onSelect)
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, kids)
end

local function SwatchesTab(current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		GridLayout = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(16, 16),
			CellPadding = UDim2.fromOffset(2, 2),
			FillDirectionMaxCells = 10,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, swatch in kColorPalette do
		kids["S" .. i] = colorCell(swatch, colorsMatch(current, swatch), i, function()
			onSelect(swatch, true)
		end)
	end
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, kids)
end

local function CustomTab(color: { number }, onChange: (color: { number }) -> (), onConfirm: () -> ()): React.ReactElement<any, any>
	local function setChannel(i: number, v255: number)
		local nc = { color[1], color[2], color[3] }
		nc[i] = math.clamp(v255 / 255, 0, 1)
		onChange(nc)
	end
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, {
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		Preview = e("Frame", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
			LayoutOrder = 1,
			ZIndex = 12,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) }),
		HexRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			ZIndex = 12,
		}, {
			Layout = e("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
			Label = e("TextLabel", { Size = UDim2.fromOffset(28, 22), BackgroundTransparency = 1, Text = "Hex", TextColor3 = Colors.WHITE, Font = Enum.Font.SourceSans, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, ZIndex = 12 }),
			Box = e("TextBox", {
				Size = UDim2.new(1, -32, 1, 0),
				BackgroundColor3 = Colors.GREY,
				BorderSizePixel = 0,
				Text = colorToHex(color),
				PlaceholderText = "RRGGBB",
				Font = Enum.Font.SourceSans,
				TextSize = 16,
				TextColor3 = Colors.WHITE,
				ClearTextOnFocus = false,
				LayoutOrder = 2,
				ZIndex = 12,
				[React.Event.FocusLost] = function(rbx: TextBox)
					local parsed = hexToColor(rbx.Text)
					if parsed then
						onChange(parsed)
					else
						rbx.Text = colorToHex(color)
					end
				end,
			}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }), Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) }),
		}),
		R = e(Slider, { Label = "R", Value = math.floor(color[1] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 3, ValueChanged = function(v: number) setChannel(1, v) end }),
		G = e(Slider, { Label = "G", Value = math.floor(color[2] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 4, ValueChanged = function(v: number) setChannel(2, v) end }),
		B = e(Slider, { Label = "B", Value = math.floor(color[3] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 5, ValueChanged = function(v: number) setChannel(3, v) end }),
		-- The Custom tab applies live as you drag, so there's no swatch click to record
		-- the colour. This button commits the current colour to the recents (and closes).
		Confirm = e("TextButton", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = Colors.ACTION_BLUE,
			Text = "Add to Recents",
			Font = Enum.Font.SourceSansBold,
			TextSize = 16,
			TextColor3 = Colors.WHITE,
			AutoButtonColor = true,
			LayoutOrder = 6,
			ZIndex = 12,
			[React.Event.MouseButton1Click] = onConfirm,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) }),
	})
end

-- Remembers the last-viewed picker tab for the rest of the Studio session, so reopening
-- the popup returns to where you left off.
local gColorPickerTab = "BrickColor"

local function ColorPickerPopup(props: {
	Current: { number },
	OnSelect: (color: { number }, close: boolean) -> (),
})
	local tab, setTab = React.useState(gColorPickerTab)
	local customColor, setCustomColor = React.useState(props.Current)

	local function customChange(c: { number })
		setCustomColor(c)
		props.OnSelect(c, false)
	end
	local function confirmCustom()
		props.OnSelect(customColor, true)
	end

	local body: React.ReactElement<any, any>
	if tab == "Swatches" then
		body = SwatchesTab(props.Current, props.OnSelect)
	elseif tab == "Custom" then
		body = CustomTab(customColor, customChange, confirmCustom)
	else
		body = BrickColorTab(props.Current, props.OnSelect)
	end

	local function tabBtn(name: string, order: number)
		local active = tab == name
		return e("TextButton", {
			Size = UDim2.new(1 / 3, -2, 1, 0),
			BackgroundColor3 = if active then Colors.ACTION_BLUE else Colors.GREY,
			BackgroundTransparency = if active then 0 else 0.35,
			Text = name,
			Font = if active then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = Colors.WHITE,
			AutoButtonColor = not active,
			LayoutOrder = order,
			ZIndex = 12,
			[React.Event.MouseButton1Click] = function()
				setTab(name)
				gColorPickerTab = name
			end,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) })
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.BLACK,
		BorderSizePixel = 0,
		ZIndex = 12,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
		Stroke = e("UIStroke", { Color = Colors.OFFWHITE, Thickness = 1 }),
		Padding = e("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		TabBar = e("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			ZIndex = 12,
		}, {
			Layout = e("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
			BrickColor = tabBtn("BrickColor", 1),
			Swatches = tabBtn("Swatches", 2),
			Custom = tabBtn("Custom", 3),
		}),
		Body = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			ZIndex = 12,
		}, { Content = body }),
	})
end

local kMaxRecentColors = 8

local function updateRecentColors(settings: Settings.RopeToolSettings, color: { number })
	local recent = table.clone(settings.RecentColors)
	-- Remove if already present
	for i = #recent, 1, -1 do
		if colorsMatch(recent[i], color) then
			table.remove(recent, i)
		end
	end
	table.insert(recent, 1, color)
	while #recent > kMaxRecentColors do
		table.remove(recent)
	end
	settings.RecentColors = recent
end

local function ColorPanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local c = props.Settings.RopeColor
	local currentColor = Color3.new(c[1], c[2], c[3])
	local nextOrder = createNextOrder()
	local overlayContext = OverlayGui.use()
	local colorTriggerRef = React.useRef(nil)

	local function setColor(color: { number })
		props.Settings.RopeColor = color
		props.UpdatedSettings()
	end

	local function openColorPalette()
		if colorTriggerRef.current then
			overlayContext.SetOverlay(colorTriggerRef.current, e(ColorPickerPopup, {
				Current = c,
				OnSelect = function(color: { number }, close: boolean)
					-- BrickColor/Swatches commit (close=true); the Custom tab live-updates
					-- as you drag (close=false) and stays open until you click away.
					props.Settings.RopeColor = color
					if close then
						updateRecentColors(props.Settings, color)
						overlayContext.SetOverlay(nil)
					end
					props.UpdatedSettings()
				end,
			}))
		end
	end

	-- Build recent color swatches (in stored order, highlight current)
	local shownColors: { { number } } = {}
	for _, color in props.Settings.RecentColors do
		if #shownColors >= kMaxRecentColors then
			break
		end
		table.insert(shownColors, color)
	end

	local recentChildren: { [string]: React.ReactElement<any, any> } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	}
	for i, color in shownColors do
		local isCurrent = colorsMatch(color, c)
		recentChildren[`Color{i}`] = e("TextButton", {
			Size = UDim2.fromOffset(22, 22),
			BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = i,
			[React.Event.MouseButton1Click] = function()
				setColor(color)
			end,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 3),
			}),
			Border = isCurrent and e("UIStroke", {
				Color = Colors.WHITE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		})
	end

	return e(SubPanel, {
		Title = "Color",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		HeroRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			ColorPreview = e("TextButton", {
				Size = UDim2.new(1, -84, 0, 24),
				BackgroundColor3 = currentColor,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = 1,
				[React.Event.MouseButton1Click] = openColorPalette,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Flex = e("UIFlexItem", {
					FlexMode = Enum.UIFlexMode.Fill,
				}),
				DarkBorder = (c[1] + c[2] + c[3] < 0.6) and e("UIStroke", {
					Color = Colors.OFFWHITE,
					Thickness = 1,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}) or nil,
			}),
			PickButton = e("TextButton", {
				Size = UDim2.fromOffset(48, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "Pick",
				Font = if props.Settings.RopeEyedropper == "Color" then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
				TextSize = if props.Settings.RopeEyedropper == "Color" then 20 else 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = props.Settings.RopeEyedropper ~= "Color",
				LayoutOrder = 2,
				[React.Event.MouseButton1Click] = function()
					props.Settings.RopeEyedropper = if props.Settings.RopeEyedropper == "Color" then "None" else "Color"
					props.UpdatedSettings()
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Border = (props.Settings.RopeEyedropper == "Color") and e("UIStroke", {
					Color = Colors.WHITE,
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			}),
			MoreButton = e("TextButton", {
				Size = UDim2.fromOffset(28, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "...",
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = true,
				LayoutOrder = 3,
				ref = colorTriggerRef,
				[React.Event.MouseButton1Click] = openColorPalette,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
		}),
		RecentRow = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, recentChildren),
	})
end

local function MaterialPanel(props: {
	Settings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	local overlayContext = OverlayGui.use()
	local materialTriggerRef = React.useRef(nil)

	-- Move a recent key (an encoded material+variant) to the front of the history.
	local function addRecent(key: string)
		local recent = table.clone(props.Settings.RecentMaterials)
		for i = #recent, 1, -1 do
			if recent[i] == key then
				table.remove(recent, i)
			end
		end
		table.insert(recent, 1, key)
		while #recent > 6 do -- two rows of three
			table.remove(recent)
		end
		props.Settings.RecentMaterials = recent
	end

	-- Pick a base material from the popup: clears any variant.
	local function selectMaterialFromPicker(name: string)
		props.Settings.RopeMaterial = name
		props.Settings.RopeMaterialVariant = ""
		addRecent(Settings.EncodeRecentMaterial(name, ""))
		props.UpdatedSettings()
	end

	-- Re-apply a recent (material + variant) history entry.
	local function selectRecent(key: string)
		local material, variant = Settings.DecodeRecentMaterial(key)
		props.Settings.RopeMaterial = material
		props.Settings.RopeMaterialVariant = variant
		addRecent(key)
		props.UpdatedSettings()
	end

	-- Apply a typed variant name. If a MaterialVariant by that name exists, switch the
	-- base material to its BaseMaterial so the variant actually shows; if no such
	-- variant exists, clear the field back to empty.
	local function applyVariant(typed: string)
		if typed == "" then
			props.Settings.RopeMaterialVariant = ""
			props.UpdatedSettings()
			return
		end
		local found: MaterialVariant? = nil
		for _, child in MaterialService:GetChildren() do
			if child:IsA("MaterialVariant") and child.Name == typed then
				found = child :: MaterialVariant
				break
			end
		end
		if found then
			props.Settings.RopeMaterialVariant = typed
			props.Settings.RopeMaterial = found.BaseMaterial.Name
			-- A valid, entered variant joins the history, like an eyedropped one.
			addRecent(Settings.EncodeRecentMaterial(found.BaseMaterial.Name, typed))
		else
			props.Settings.RopeMaterialVariant = ""
		end
		props.UpdatedSettings()
	end

	local function openMaterialPopup()
		if materialTriggerRef.current then
			overlayContext.SetOverlay(materialTriggerRef.current, e(MaterialDropdown.PopupContent, {
				Current = props.Settings.RopeMaterial,
				OnSelect = function(name: string)
					overlayContext.SetOverlay(nil)
					selectMaterialFromPicker(name)
				end,
			}))
		end
	end

	return e(SubPanel, {
		Title = "Material",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		HeroRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			MaterialPreview = e("TextButton", {
				Size = UDim2.new(1, -84, 0, 24),
				BackgroundTransparency = 1,
				Text = "",
				LayoutOrder = 1,
				[React.Event.MouseButton1Click] = openMaterialPopup,
			}, {
				Flex = e("UIFlexItem", {
					FlexMode = Enum.UIFlexMode.Fill,
				}),
				Viewport = e("ViewportFrame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Colors.BLACK,
				}, {
					Corner = e("UICorner", {
						CornerRadius = UDim.new(0, 4),
					}),
					PreviewPart = e("Part", {
						Size = Vector3.new(100, 100, 0.1),
						Position = Vector3.new(0, 0, 0),
						Material = (Enum.Material :: any)[props.Settings.RopeMaterial] or Enum.Material.Plastic,
						Color = Color3.new(
							props.Settings.RopeColor[1],
							props.Settings.RopeColor[2],
							props.Settings.RopeColor[3]
						),
						Anchored = true,
					}),
					PreviewCamera = e("Camera", {
						CFrame = CFrame.new(Vector3.new(0, 0, 3), Vector3.new(0, 0, 0)),
						FieldOfView = 5,
						ref = function(camera: Camera?)
							if camera then
								local vf = camera.Parent :: ViewportFrame?
								if vf then
									vf.CurrentCamera = camera
								end
							end
						end,
					}),
				}),
			}),
			PickButton = e("TextButton", {
				Size = UDim2.fromOffset(48, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "Pick",
				Font = if props.Settings.RopeEyedropper == "Material" then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
				TextSize = if props.Settings.RopeEyedropper == "Material" then 20 else 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = props.Settings.RopeEyedropper ~= "Material",
				LayoutOrder = 2,
				[React.Event.MouseButton1Click] = function()
					props.Settings.RopeEyedropper = if props.Settings.RopeEyedropper == "Material" then "None" else "Material"
					props.UpdatedSettings()
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Border = (props.Settings.RopeEyedropper == "Material") and e("UIStroke", {
					Color = Colors.WHITE,
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			}),
			MoreButton = e("TextButton", {
				Size = UDim2.fromOffset(28, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "...",
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = true,
				LayoutOrder = 3,
				ref = materialTriggerRef,
				[React.Event.MouseButton1Click] = openMaterialPopup,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
		}),
		RecentChips = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, (function()
			-- Lay the recents out three per row (two rows of three) so material names
			-- aren't cramped. The last row is padded with blank slots so its chips keep
			-- the one-third width of a full row.
			local perRow = 3
			local recents = props.Settings.RecentMaterials
			local rowCount = math.max(1, math.ceil(#recents / perRow))
			local rows: { [string]: any } = {
				ListLayout = e("UIListLayout", {
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
			}
			for r = 1, rowCount do
				local rowKids: { [string]: any } = {
					ListLayout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 4),
					}),
				}
				for c = 1, perRow do
					local key = recents[(r - 1) * perRow + c]
					if key then
						local material, variant = Settings.DecodeRecentMaterial(key)
						rowKids["Chip" .. tostring(c)] = e(ChipForToggle, {
							-- Show the variant's own name when there is one; otherwise the
							-- dropdown's abbreviated material label (e.g. "Smooth P."),
							-- falling back to the raw material name when it has no label.
							-- ChipForToggle clips a long label to its own edge.
							Text = if variant ~= "" then variant else MaterialDropdown.GetLabel(material),
							IsCurrent = material == props.Settings.RopeMaterial
								and variant == props.Settings.RopeMaterialVariant,
							LayoutOrder = c,
							OnClick = function()
								selectRecent(key)
							end,
						})
					else
						rowKids["Empty" .. tostring(c)] = e("Frame", {
							Size = UDim2.new(0, 0, 0, 24),
							BackgroundTransparency = 1,
							LayoutOrder = c,
						}, {
							Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
						})
					end
				end
				rows["Row" .. tostring(r)] = e("Frame", {
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					LayoutOrder = r,
				}, rowKids)
			end
			return rows
		end)()),
		-- The Variant field sits below the recents.
		VariantRow = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Label = e("TextLabel", {
					Text = "Variant",
					TextColor3 = Colors.WHITE,
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 0, 0, 24),
					AutomaticSize = Enum.AutomaticSize.X,
					Font = Enum.Font.SourceSans,
					TextSize = 18,
					TextXAlignment = Enum.TextXAlignment.Left,
					LayoutOrder = 1,
				}),
				Box = e("TextBox", {
					Text = props.Settings.RopeMaterialVariant,
					PlaceholderText = "(none)",
					PlaceholderColor3 = Color3.fromRGB(170, 170, 170),
					TextColor3 = Colors.WHITE,
					BackgroundColor3 = Colors.GREY,
					Size = UDim2.new(0, 0, 0, 24),
					Font = Enum.Font.SourceSans,
					TextSize = 18,
					TextXAlignment = Enum.TextXAlignment.Left,
					ClearTextOnFocus = false,
					LayoutOrder = 2,
					[React.Event.FocusLost] = function(rbx: TextBox)
						applyVariant(rbx.Text)
						-- Reflect the resolved value even when it didn't change (so no
						-- Text update was rendered) -- e.g. an invalid entry cleared to "".
						rbx.Text = props.Settings.RopeMaterialVariant
					end,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
					Padding = e("UIPadding", {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					}),
					Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Use a <b>MaterialVariant</b> on top of the base material.<br />Type its name, or eyedrop a part that already has one. A valid name also switches the base material to match it, and is saved to the recents.<br />• unknown name — clears the field<br />• empty — no variant",
			}),
		}),
	})
end

local function CloseButton(props: {
	HandleAction: (string) -> (),
	LayoutOrder: number?,
})
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		CancelButton = e(OperationButton, {
			Text = "Close <i>RopeTool</i>",
			Color = Colors.DARK_RED,
			Disabled = false,
			Height = 30,
			OnClick = function()
				props.HandleAction("cancel")
			end,
		}),
	})
end

local ROPETOOL_CONFIG: PluginGuiTypes.PluginGuiConfig = {
	PluginName = "RopeTool",
	PendingText = "Click the toolbar button to activate RopeTool.",
	TutorialElement = nil :: any,
}

local function RopeToolGui(props: {
	GuiState: PluginGuiTypes.PluginGuiMode,
	CurrentSettings: Settings.RopeToolSettings,
	UpdatedSettings: () -> (),
	HandleAction: (string) -> (),
	Panelized: boolean,
	Session: createRopeSession.RopeSession?,
})
	local currentSettings = props.CurrentSettings
	local session = props.Session
	local mode = currentSettings.Mode
	-- The rope's structural parameters show for Move/Add; the appearance
	-- panels live in the Color tool; global options in the Settings tab.
	local showRope = mode == "Move" or mode == "Add"
	local showColor = mode == "Color"
	local showSettings = mode == "Settings"
	local nextOrder = createNextOrder()

	local overlay: React.ReactNode = nil
	if session then
		local addHoverPoint, addHoverSnapped = session.GetAddHoverPoint()
		overlay = e(RopeOverlay, {
			HoverPolyline = session.GetHoverPolyline(),
			SelectedPolyline = session.GetSelectedPolyline(),
			AddFirstPoint = session.GetAddFirstPoint(),
			AddHoverPoint = addHoverPoint,
			AddHoverSnapped = addHoverSnapped,
			AddPreviewPoints = session.GetAddPreviewPoints(),
		})
	end

	return e(PluginGui, {
		Config = ROPETOOL_CONFIG,
		State = {
			Mode = props.GuiState,
			Settings = currentSettings,
			UpdatedSettings = props.UpdatedSettings,
			HandleAction = props.HandleAction,
			Panelized = props.Panelized,
		},
	}, {
		Overlay = overlay,
		Content = e(React.Fragment, nil, {
			ModePanel = e(ModePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			RopePanel = showRope and e(RopePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			GroupingPanel = showRope and e(GroupingPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			AddOptionsPanel = mode == "Add" and e(AddOptionsPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			ColorPanel = showColor and e(ColorPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			MaterialPanel = showColor and e(MaterialPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			SnappingPanel = showSettings and e(SnappingPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			StatusText = e(StatusText, {
				Settings = currentSettings,
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			CloseButton = e(CloseButton, {
				HandleAction = props.HandleAction,
				LayoutOrder = nextOrder(),
			}),
		}),
	})
end

return RopeToolGui
