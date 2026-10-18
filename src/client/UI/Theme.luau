--!strict
-- One look for every screen: dark glass panels with a thin outline, Gotham text, monospace numbers
-- on the phone, and a few accent colors that mean the same thing everywhere (green = money,
-- orange-to-red = heat, blue = police, amber/cyan = pickup/dropoff from the map Palette).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage.Shared.Palette)

local Theme = {}

Theme.Colors = {
	Panel = Color3.fromRGB(18, 20, 26),
	PanelRaised = Color3.fromRGB(30, 33, 42),
	Outline = Color3.fromRGB(255, 255, 255),
	Track = Color3.fromRGB(48, 51, 62),
	Text = Color3.fromRGB(240, 240, 236),
	TextDim = Color3.fromRGB(150, 156, 170),
	Cash = Color3.fromRGB(110, 220, 130),
	HeatLow = Color3.fromRGB(255, 176, 60),
	HeatHigh = Color3.fromRGB(255, 70, 70),
	Police = Color3.fromRGB(80, 140, 255),
	Wanted = Color3.fromRGB(255, 84, 84),
	Pickup = Palette.Pickup,
	Dropoff = Palette.Dropoff,
	Danger = Color3.fromRGB(255, 120, 110),
}

Theme.Fonts = {
	Body = Enum.Font.GothamMedium,
	Bold = Enum.Font.GothamBold,
	Heavy = Enum.Font.GothamBlack,
	Mono = Enum.Font.RobotoMono,
}

Theme.PanelTransparency = 0.15
Theme.Radius = 10

type Props = { [string]: any }

-- Instance.new with properties and children in one call.
function Theme.new(className: string, props: Props?, children: { Instance }?): any
	local inst = Instance.new(className)
	if props then
		for key, value in props do
			if key ~= "Parent" then
				(inst :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if props and props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

function Theme.corner(radius: number?): UICorner
	return Theme.new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.Radius) })
end

function Theme.stroke(transparency: number?, color: Color3?): UIStroke
	return Theme.new("UIStroke", {
		Color = color or Theme.Colors.Outline,
		Transparency = transparency or 0.9,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Theme.padding(x: number, y: number?): UIPadding
	return Theme.new("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y or x),
		PaddingBottom = UDim.new(0, y or x),
	})
end

-- A dark glass panel.
function Theme.panel(props: Props?): Frame
	local p: Props = {
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = Theme.PanelTransparency,
		BorderSizePixel = 0,
	}
	for key, value in props or {} do
		p[key] = value
	end
	return Theme.new("Frame", p, { Theme.corner(), Theme.stroke() })
end

function Theme.label(props: Props?): TextLabel
	local p: Props = {
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Body,
		TextColor3 = Theme.Colors.Text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}
	for key, value in props or {} do
		p[key] = value
	end
	return Theme.new("TextLabel", p)
end

-- A small uppercase caption, e.g. "DIRTY CASH".
function Theme.caption(text: string, props: Props?): TextLabel
	local p: Props = {
		Text = string.upper(text),
		Font = Theme.Fonts.Bold,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextDim,
	}
	for key, value in props or {} do
		p[key] = value
	end
	return Theme.label(p)
end

-- A rounded bar; returns (track, fill). Size the fill with UDim2.fromScale(fraction, 1).
function Theme.bar(props: Props?, fillColor: Color3?): (Frame, Frame)
	local p: Props = {
		BackgroundColor3 = Theme.Colors.Track,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}
	for key, value in props or {} do
		p[key] = value
	end
	local track = Theme.new("Frame", p, { Theme.corner(4) })
	local fill = Theme.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor or Theme.Colors.Text,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	}, { Theme.corner(4) })
	return track, fill
end

function Theme.button(props: Props?): TextButton
	local p: Props = {
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Theme.Fonts.Bold,
		TextColor3 = Theme.Colors.Text,
		TextSize = 14,
	}
	for key, value in props or {} do
		p[key] = value
	end
	return Theme.new("TextButton", p, { Theme.corner(8) })
end

-- "$1,250"
function Theme.money(amount: number): string
	local s = tostring(math.floor(math.abs(amount)))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (if amount < 0 then "-$" else "$") .. formatted
end

-- "85m" / "1.2km"
function Theme.distance(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fkm", studs / 1000)
	end
	return `{math.floor(studs)}m`
end

return Theme
