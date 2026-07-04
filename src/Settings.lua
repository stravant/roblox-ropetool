--!strict

local InitialPosition = Vector2.new(24, 24)
local kSettingsKey = "ropeToolState"

local PluginGuiTypes = require("./PluginGui/Types")

export type RopeToolSettings = PluginGuiTypes.PluginGuiSettings & {
	Mode: string, -- "Move" | "Add" | "Color" | "Settings"
	SnapRopeEnds: boolean,
	SnapGeometry: boolean,
	Segments: number,
	SegmentType: string, -- "Box" | "Cylinder"
	Sag: number,
	Sway: number,
	Diameter: number,
	HaveEndcaps: boolean,
	RopeColor: { number },
	RopeMaterial: string,
	RopeMaterialVariant: string,
	RopeEyedropper: string, -- "None" | "Color" | "Material"
	RecentMaterials: { string },
	RecentColors: { { number } },
}

local function loadSettings(plugin: Plugin): RopeToolSettings
	local raw = plugin:GetSetting(kSettingsKey) or {}
	return {
		WindowPosition = Vector2.new(
			raw.WindowPositionX or InitialPosition.X,
			raw.WindowPositionY or InitialPosition.Y
		),
		WindowAnchor = Vector2.new(
			raw.WindowAnchorX or 0,
			raw.WindowAnchorY or 0
		),
		WindowHeightDelta = if raw.WindowHeightDelta ~= nil then raw.WindowHeightDelta else 0,
		HaveHelp = if raw.HaveHelp ~= nil then raw.HaveHelp else true,
		DoneTutorial = if raw.DoneTutorial ~= nil then raw.DoneTutorial else false,

		Mode = raw.Mode or "Add",
		SnapRopeEnds = if raw.SnapRopeEnds ~= nil then raw.SnapRopeEnds else true,
		SnapGeometry = if raw.SnapGeometry ~= nil then raw.SnapGeometry else true,
		Segments = raw.Segments or 10,
		SegmentType = raw.SegmentType or "Cylinder",
		Sag = raw.Sag or 2,
		Sway = raw.Sway or 0,
		Diameter = raw.Diameter or 0.3,
		HaveEndcaps = if raw.HaveEndcaps ~= nil then raw.HaveEndcaps else true,
		RopeColor = raw.RopeColor or { 0.412, 0.251, 0.157 },
		RopeMaterial = raw.RopeMaterial or "Fabric",
		RopeMaterialVariant = raw.RopeMaterialVariant or "",
		RopeEyedropper = "None",
		RecentMaterials = raw.RecentMaterials or { "Fabric", "Plastic", "Metal" },
		RecentColors = raw.RecentColors or { { 0.412, 0.251, 0.157 } },
	}
end

local function saveSettings(plugin: Plugin, settings: RopeToolSettings)
	plugin:SetSetting(kSettingsKey, {
		WindowPositionX = settings.WindowPosition.X,
		WindowPositionY = settings.WindowPosition.Y,
		WindowAnchorX = settings.WindowAnchor.X,
		WindowAnchorY = settings.WindowAnchor.Y,
		WindowHeightDelta = settings.WindowHeightDelta,
		HaveHelp = settings.HaveHelp,
		DoneTutorial = settings.DoneTutorial,

		Mode = settings.Mode,
		SnapRopeEnds = settings.SnapRopeEnds,
		SnapGeometry = settings.SnapGeometry,
		Segments = settings.Segments,
		SegmentType = settings.SegmentType,
		Sag = settings.Sag,
		Sway = settings.Sway,
		Diameter = settings.Diameter,
		HaveEndcaps = settings.HaveEndcaps,
		RopeColor = settings.RopeColor,
		RopeMaterial = settings.RopeMaterial,
		RopeMaterialVariant = settings.RopeMaterialVariant,
		RecentMaterials = settings.RecentMaterials,
		RecentColors = settings.RecentColors,
	})
end

-- Recent materials are stored as opaque keys so a (base material, variant) pair can
-- be a single history entry. A plain material name (no variant) is stored as-is, so
-- older saved histories of bare names still decode correctly.
local kRecentSeparator = "\31"
local function encodeRecentMaterial(material: string, variant: string): string
	return if variant ~= "" then material .. kRecentSeparator .. variant else material
end
local function decodeRecentMaterial(key: string): (string, string)
	local i = string.find(key, kRecentSeparator, 1, true)
	if i then
		return string.sub(key, 1, i - 1), string.sub(key, i + 1)
	end
	return key, ""
end

return {
	Load = loadSettings,
	Save = saveSettings,
	EncodeRecentMaterial = encodeRecentMaterial,
	DecodeRecentMaterial = decodeRecentMaterial,
}
