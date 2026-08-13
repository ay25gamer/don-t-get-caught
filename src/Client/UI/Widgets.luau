--!strict
--[[
	Widgets.luau

	Small Instance-building primitives shared by every client-side UI controller
	(HudController, HubController) — extracted here once a second controller needed the exact
	same newFrame/newLabel/newButton helpers HudController had already built, avoiding
	duplicating them a second time. Not a Controller itself (no Init/Start, no lifecycle) —
	just plain builder functions, required directly where needed.
]]

local Widgets = {}

function Widgets.NewFrame(name: string, parent: Instance, size: UDim2, position: UDim2?, backgroundColor: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position or UDim2.new(0, 0, 0, 0)
	frame.BackgroundColor3 = backgroundColor or Color3.fromRGB(20, 20, 24)
	frame.BackgroundTransparency = if backgroundColor then 0.25 else 1
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

function Widgets.NewLabel(name: string, parent: Instance, text: string, size: UDim2, alignment: Enum.TextXAlignment?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(240, 240, 240)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextXAlignment = alignment or Enum.TextXAlignment.Center
	label.Parent = parent
	return label
end

function Widgets.NewButton(name: string, parent: Instance, text: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
	button.TextColor3 = Color3.fromRGB(240, 240, 240)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.Text = text
	button.AutoButtonColor = true
	button.Parent = parent
	return button
end

-- A single-line editable text field — new this module (HudController never needed one).
function Widgets.NewTextBox(name: string, parent: Instance, placeholderText: string, size: UDim2): TextBox
	local textBox = Instance.new("TextBox")
	textBox.Name = name
	textBox.Size = size
	textBox.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
	textBox.TextColor3 = Color3.fromRGB(240, 240, 240)
	-- Instance.new("TextBox") defaults Text to the literal string "TextBox" — without clearing
	-- it, that default permanently hides PlaceholderText (which only shows when Text is empty).
	textBox.Text = ""
	textBox.PlaceholderText = placeholderText
	textBox.PlaceholderColor3 = Color3.fromRGB(140, 140, 145)
	textBox.Font = Enum.Font.Gotham
	textBox.TextSize = 16
	textBox.ClearTextOnFocus = false
	textBox.Parent = parent
	return textBox
end

--[[
	Adds a UIScale under `target` that shrinks target's whole subtree so it never renders
	larger than the room actually available, per `getAvailableSize()` — but never scales UP
	past 1, so on anything already big enough (every PC resolution this UI was laid out and
	tested at) the result is Scale == 1: pixel-identical to before this existed. Every
	Position/Size already inside target's subtree is left completely untouched — UIScale
	scales the whole rendered subtree uniformly, so all existing relative (scale, offset) math
	in there keeps working exactly as designed, just smaller on a small screen instead of
	spilling off it.

	`contentSize` is target's real, unscaled footprint at Scale 1 — the same fixed offsets
	already used to build it, not invented.

	`getAvailableSize`/`resizeSignal` are supplied by the caller rather than assumed, because
	what "available" means differs by target: the real screen for a free-floating panel, or a
	stable ANCESTOR's size for a row nested inside an already-responsive container. Deliberately
	never target's own AbsoluteSize — per Roblox's docs, a UIScale multiplies the AbsoluteSize of
	the object it's parented to, so using target's own (post-scale) AbsoluteSize as the
	denominator here would feed back into itself and shrink toward zero on every resize.
]]
function Widgets.FitToAvailableSpace(
	target: GuiObject,
	contentSize: Vector2,
	getAvailableSize: () -> Vector2,
	resizeSignal: RBXScriptSignal
): UIScale
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = target

	local function update()
		local available = getAvailableSize()
		if available.X <= 0 or available.Y <= 0 then
			return
		end
		uiScale.Scale = math.min(1, available.X / contentSize.X, available.Y / contentSize.Y)
	end

	update()
	resizeSignal:Connect(update)

	return uiScale
end

return Widgets
