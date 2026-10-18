--!strict
-- Shared color palette for the stylized look: warm, slightly muted base colors with brighter
-- accents reserved for gameplay objects (pickups, dropoffs, police lights).

local rgb = Color3.fromRGB

local Palette = {
	Asphalt = rgb(62, 64, 72),
	AsphaltLight = rgb(84, 86, 94),
	LineWhite = rgb(236, 234, 224),
	LineYellow = rgb(240, 196, 64),
	Sidewalk = rgb(200, 194, 182),
	Curb = rgb(170, 164, 154),
	Grass = rgb(112, 164, 82),
	-- terrain grass renders darker than a part of the same color; this matches Grass on screen
	TerrainGrass = rgb(150, 208, 112),
	GrassDark = rgb(88, 138, 68),
	Dirt = rgb(156, 122, 88),
	Sand = rgb(232, 214, 162),
	Water = rgb(64, 146, 196),
	WaterDeep = rgb(40, 96, 150),
	Wood = rgb(150, 108, 74),
	Glass = rgb(54, 62, 76),
	Roof = rgb(92, 92, 100),

	Buildings = {
		rgb(232, 220, 196), -- cream
		rgb(206, 124, 94), -- terracotta
		rgb(222, 192, 142), -- sand
		rgb(116, 136, 166), -- slate blue
		rgb(152, 192, 172), -- mint
		rgb(212, 164, 162), -- dusty pink
		rgb(168, 168, 176), -- concrete
	},
	Industrial = {
		rgb(178, 100, 72), -- brick
		rgb(142, 152, 162), -- steel
		rgb(156, 96, 64), -- rust
		rgb(64, 132, 142), -- teal
	},
	Containers = {
		rgb(198, 74, 64),
		rgb(62, 112, 172),
		rgb(82, 142, 92),
		rgb(222, 172, 62),
		rgb(222, 122, 52),
	},
	Leaves = {
		rgb(86, 152, 82),
		rgb(72, 132, 72),
		rgb(112, 172, 92),
	},
	Trunk = rgb(112, 82, 60),
	Rock = rgb(140, 140, 146),

	CraneYellow = rgb(240, 180, 40),
	PoliceWhite = rgb(240, 242, 246),
	PoliceNavy = rgb(36, 56, 108),
	SirenRed = rgb(255, 60, 60),
	SirenBlue = rgb(60, 120, 255),

	Pickup = rgb(255, 196, 48),
	Dropoff = rgb(64, 200, 255),
	CarSpawn = rgb(120, 220, 120),

	CarColors = {
		rgb(214, 70, 62),
		rgb(60, 120, 200),
		rgb(240, 180, 50),
		rgb(90, 170, 110),
		rgb(170, 90, 180),
		rgb(240, 240, 236),
	},
}

return Palette
