--!strict
--[[
	HudController.luau

	Builds the entire HUD/menu UI tree via code into PlayerGui — the same "no hand-authored
	Studio assets" philosophy as PlaceholderMapService's 3D geometry, applied to 2D UI. This is
	not a placeholder to be thrown away like the 3D grey-box art: code-built, data-driven UI is
	a legitimate, common production pattern for Roblox games. Visual polish (real fonts, icons,
	textures) can layer on top later without restructuring anything here.

	Owns ONE ScreenGui because a UI tree is inherently one coupled structure — splitting panel
	construction across multiple independently-bootstrapped Controllers would mean fighting over
	who owns the shared Frame each panel lives in, for no real benefit.

	Settings, Shop, Inventory, and Daily Rewards are all real now (added alongside ShopService/
	MonetizationService/DailyService): Shop reads CosmeticCatalog.luau directly (same list the
	server validates purchases against, so nothing shown here can ever be un-purchasable),
	Inventory reflects InventoryUpdated, Daily Rewards reflects DailyStateChanged. Every panel
	rebuilds its row list from scratch whenever its data arrives rather than trying to patch
	individual rows — the lists are small (tens of items), so simplicity wins over the
	complexity of granular diffing.

	Every value shown here comes from a server broadcast/targeted remote — this controller never
	decides food %, noise, gold, ownership, or round state on its own, it only displays what
	the server already computed and validated.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local CosmeticCatalog = Shared.CosmeticCatalog
local DailyMissionCatalog = Shared.DailyMissionCatalog
local MonetizationIds = Shared.MonetizationIds

local Widgets = require(script.Parent.Parent.UI.Widgets)

-- Named so function boundaries (e.g. isEquipped below) can be given an explicit parameter
-- type instead of letting Luau infer one from usage — an inferred type here would be
-- structurally similar but not `--!strict`-identical to CosmeticCatalog's real element type,
-- which fails at the call site (same class of issue as ShopService's server-side CosmeticItem).
type CosmeticItem = typeof(CosmeticCatalog[1])

local SpectatorController = require(script.Parent.SpectatorController)
local EatingController = require(script.Parent.EatingController)

local RoundStateChangedEvent = Shared.Remotes.GetEvent("RoundStateChanged")
local EatingStateChangedEvent = Shared.Remotes.GetEvent("EatingStateChanged")
local GuardStateChangedEvent = Shared.Remotes.GetEvent("GuardStateChanged")
local SuspicionTierChangedEvent = Shared.Remotes.GetEvent("SuspicionTierChanged")
local ProfileSnapshotEvent = Shared.Remotes.GetEvent("ProfileSnapshot")
local UpdateSettingEvent = Shared.Remotes.GetEvent("UpdateSetting")
local RoundParticipantsEvent = Shared.Remotes.GetEvent("RoundParticipants")
local PlayerCaughtEvent = Shared.Remotes.GetEvent("PlayerCaught")
local PlayerRevivedEvent = Shared.Remotes.GetEvent("PlayerRevived")
local RequestFreeReviveEvent = Shared.Remotes.GetEvent("RequestFreeRevive")
local ReviveTierChangedEvent = Shared.Remotes.GetEvent("ReviveTierChanged")
local PartyCodeAssignedEvent = Shared.Remotes.GetEvent("PartyCodeAssigned")
local HostChangedEvent = Shared.Remotes.GetEvent("HostChanged")
local RequestStartRoundEvent = Shared.Remotes.GetEvent("RequestStartRound")
local PurchaseCosmeticEvent = Shared.Remotes.GetEvent("PurchaseCosmetic")
local EquipCosmeticEvent = Shared.Remotes.GetEvent("EquipCosmetic")
local InventoryUpdatedEvent = Shared.Remotes.GetEvent("InventoryUpdated")
local ClaimDailyLoginEvent = Shared.Remotes.GetEvent("ClaimDailyLogin")
local ClaimMissionEvent = Shared.Remotes.GetEvent("ClaimMission")
local DailyStateChangedEvent = Shared.Remotes.GetEvent("DailyStateChanged")

local LocalPlayer = Players.LocalPlayer

local GRAPHICS_OPTIONS = { "Auto", "Low", "Medium", "High" }
local CATEGORY_ORDER = { "Fork", "Plate", "Chair", "Food", "Emote", "Title", "VictoryAnimation" }
local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(190, 190, 190),
	Rare = Color3.fromRGB(90, 160, 230),
	Epic = Color3.fromRGB(170, 100, 220),
	Legendary = Color3.fromRGB(240, 180, 60),
	Mythic = Color3.fromRGB(230, 80, 80),
	Secret = Color3.fromRGB(30, 220, 180),
}
local DEV_PRODUCT_LABELS: { [string]: string } = {
	ReviveSecond = "Revive (2nd this round)",
	ReviveThird = "Revive (3rd this round)",
	ReviveFourthPlus = "Revive (4th+ this round)",
	DoubleXP = "Double XP (24h)",
	DoubleGold = "Double Gold (24h)",
}

-- No OOP/self needed here — unlike the server services, every handler this controller
-- registers is a closure created inside the single Start() call below, so they can all just
-- close over Start()'s local variables directly instead of round-tripping through `self`.
local HudController = {}
-- Match-only — the in-round HUD assumes a food/noise/round-status context that doesn't exist
-- in the Hub; HubController is the separate, Hub-only equivalent. See ServerMode.luau.
HudController.Modes = { "Match" }

--============================================================================
-- Low-level builders
--============================================================================

-- newFrame/newLabel/newButton live in Client/UI/Widgets.luau, shared with HubController.
local newFrame = Widgets.NewFrame
local newLabel = Widgets.NewLabel
local newButton = Widgets.NewButton

-- A labeled progress bar (used for Food % and the Noise Meter). Returns a setter.
local function newMeter(parent: Instance, layoutOrder: number, label: string, fillColor: Color3): (Frame, (number) -> ())
	local container = Instance.new("Frame")
	container.Name = label .. "Meter"
	container.Size = UDim2.new(0, 160, 0, 36)
	container.BackgroundTransparency = 1
	container.LayoutOrder = layoutOrder
	container.Parent = parent

	newLabel(label .. "Label", container, label, UDim2.new(1, 0, 0, 16), Enum.TextXAlignment.Left)

	local track = newFrame("Track", container, UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 0, 18), Color3.fromRGB(35, 35, 40))
	track.BackgroundTransparency = 0

	local fill = newFrame("Fill", track, UDim2.new(0, 0, 1, 0), nil, fillColor)
	fill.BackgroundTransparency = 0

	local function setValue(percent: number)
		fill.Size = UDim2.new(math.clamp(percent / 100, 0, 1), 0, 1, 0)
	end
	setValue(0)

	return container, setValue
end

-- "Looking" (existing, unchanged) always wins outright over the ambient tiers below — a vivid,
-- unmistakable red at a much lower transparency than either amber ever reaches, so the one
-- signal that means "danger right now" can never be diluted by the merely-ambient one.
local DANGER_COLOR = Color3.fromRGB(220, 90, 90) -- same red already used for the Noise meter
local DANGER_VISIBLE_TRANSPARENCY = 0.35
-- Suspicion ambient tiers (Calm/Rising/High) — a subtle amber tint on the SAME border, used only
-- while Reading (Looking always overrides). Deliberately much fainter than Looking's red at
-- every tier — this is atmosphere, not an alarm. Reuses the existing border instead of adding a
-- new HUD element, so it inherits the same PC/mobile/resolution behavior for free.
local AMBER_COLOR = Color3.fromRGB(230, 180, 60)
local RISING_TRANSPARENCY = 0.88
local HIGH_TRANSPARENCY = 0.72
local DANGER_SHOW_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DANGER_HIDE_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type DangerLevel = "Hidden" | "Rising" | "High" | "Looking"

local DANGER_LEVEL_STYLE: { [DangerLevel]: { Color: Color3, Transparency: number, TweenInfo: TweenInfo } } = {
	Hidden = { Color = AMBER_COLOR, Transparency = 1, TweenInfo = DANGER_HIDE_TWEEN },
	Rising = { Color = AMBER_COLOR, Transparency = RISING_TRANSPARENCY, TweenInfo = DANGER_SHOW_TWEEN },
	High = { Color = AMBER_COLOR, Transparency = HIGH_TRANSPARENCY, TweenInfo = DANGER_SHOW_TWEEN },
	Looking = { Color = DANGER_COLOR, Transparency = DANGER_VISIBLE_TRANSPARENCY, TweenInfo = DANGER_SHOW_TWEEN },
}

-- Four thin edge strips forming a full-screen border — a peripheral-vision cue that works no
-- matter where the player's camera happens to be pointed. This matters because nothing about a
-- seat's default facing direction guarantees the guard's Newspaper (the only other signal of
-- Reading/Looking) is actually in view — see GuardStateChanged's doc comment in Remotes.luau.
-- Returns a setter taking one of the four DangerLevel states above; invisible until first shown,
-- so it costs nothing to look at while Hidden.
local function newDangerBorder(screenGui: ScreenGui): (DangerLevel) -> ()
	local function strip(size: UDim2, position: UDim2): Frame
		local frame = Instance.new("Frame")
		frame.Name = "DangerBorder"
		frame.Size = size
		frame.Position = position
		frame.BackgroundColor3 = AMBER_COLOR
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = screenGui
		return frame
	end

	local strips = {
		strip(UDim2.new(1, 0, 0, 8), UDim2.new(0, 0, 0, 0)), -- top
		strip(UDim2.new(1, 0, 0, 8), UDim2.new(0, 0, 1, -8)), -- bottom
		strip(UDim2.new(0, 8, 1, 0), UDim2.new(0, 0, 0, 0)), -- left
		strip(UDim2.new(0, 8, 1, 0), UDim2.new(1, -8, 0, 0)), -- right
	}

	local currentLevel: DangerLevel = "Hidden"

	return function(level: DangerLevel)
		if level == currentLevel then
			return
		end
		currentLevel = level
		local style = DANGER_LEVEL_STYLE[level]
		for _, frame in ipairs(strips) do
			TweenService:Create(frame, style.TweenInfo, { BackgroundColor3 = style.Color, BackgroundTransparency = style.Transparency }):Play()
		end
	end
end

--============================================================================
-- Settings controls (slider / toggle / cycle) — the only panel with real content this step
--============================================================================

local function createSlider(parent: Instance, layoutOrder: number, label: string, initial: number, onChanged: (number) -> ())
	local container = newFrame(label .. "Row", parent, UDim2.new(1, 0, 0, 36))
	container.LayoutOrder = layoutOrder

	newLabel(label .. "Text", container, label, UDim2.new(0.45, 0, 1, 0), Enum.TextXAlignment.Left)

	local track = newFrame("Track", container, UDim2.new(0.5, 0, 0, 10), UDim2.new(0.47, 0, 0.5, -5), Color3.fromRGB(60, 60, 68))
	track.BackgroundTransparency = 0

	local fill = newFrame("Fill", track, UDim2.new(math.clamp(initial, 0, 1), 0, 1, 0), nil, Color3.fromRGB(90, 170, 255))
	fill.BackgroundTransparency = 0

	local dragging = false

	local function setFromInputPosition(inputPosition: Vector3)
		local trackPosition = track.AbsolutePosition
		local trackSize = track.AbsoluteSize
		if trackSize.X <= 0 then
			return
		end
		local relative = math.clamp((inputPosition.X - trackPosition.X) / trackSize.X, 0, 1)
		fill.Size = UDim2.new(relative, 0, 1, 0)
		onChanged(relative)
	end

	track.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromInputPosition(input.Position)
		end
	end)

	track.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			setFromInputPosition(input.Position)
		end
	end)

	return container
end

local function createToggle(parent: Instance, layoutOrder: number, label: string, initial: boolean, onChanged: (boolean) -> ())
	local container = newFrame(label .. "Row", parent, UDim2.new(1, 0, 0, 36))
	container.LayoutOrder = layoutOrder

	newLabel(label .. "Text", container, label, UDim2.new(0.6, 0, 1, 0), Enum.TextXAlignment.Left)

	local button = newButton(label .. "Toggle", container, "", UDim2.new(0, 70, 0, 28))
	button.Position = UDim2.new(1, -70, 0.5, -14)

	local state = initial
	local function refresh()
		button.Text = if state then "ON" else "OFF"
		button.BackgroundColor3 = if state then Color3.fromRGB(70, 165, 90) else Color3.fromRGB(120, 60, 60)
	end
	refresh()

	button.MouseButton1Click:Connect(function()
		state = not state
		refresh()
		onChanged(state)
	end)

	return container
end

local function createCycle(parent: Instance, layoutOrder: number, label: string, options: { string }, initial: string, onChanged: (string) -> ())
	local container = newFrame(label .. "Row", parent, UDim2.new(1, 0, 0, 36))
	container.LayoutOrder = layoutOrder

	newLabel(label .. "Text", container, label, UDim2.new(0.6, 0, 1, 0), Enum.TextXAlignment.Left)

	local button = newButton(label .. "Cycle", container, "", UDim2.new(0, 100, 0, 28))
	button.Position = UDim2.new(1, -100, 0.5, -14)

	local index = table.find(options, initial) or 1
	local function refresh()
		button.Text = options[index]
	end
	refresh()

	button.MouseButton1Click:Connect(function()
		index = (index % #options) + 1
		refresh()
		onChanged(options[index])
	end)

	return container
end

--============================================================================
-- Panels
--============================================================================

-- The size every panel below is actually laid out at (420x320, see the newFrame call in
-- createPanel) — on any screen at or above this, FitToAvailableSpace leaves it untouched. On a
-- phone screen narrower/shorter than this, it shrinks uniformly instead of spilling off-screen
-- with its Close button unreachable past the edge.
local PANEL_REFERENCE_SIZE = Vector2.new(420, 320)

local function createPanel(parent: Instance, name: string, title: string): Frame
	local panel = newFrame(name, parent, UDim2.new(0, 420, 0, 320), UDim2.new(0.5, -210, 0.5, -160), Color3.fromRGB(24, 24, 28))
	panel.BackgroundTransparency = 0.05
	panel.Visible = false
	panel.ZIndex = 10

	local camera = Workspace.CurrentCamera
	if camera then
		Widgets.FitToAvailableSpace(panel, PANEL_REFERENCE_SIZE, function()
			local currentCamera = Workspace.CurrentCamera
			return if currentCamera then currentCamera.ViewportSize else Vector2.zero
		end, camera:GetPropertyChangedSignal("ViewportSize"))
	end

	local titleBar = newFrame("TitleBar", panel, UDim2.new(1, 0, 0, 36))
	titleBar.ZIndex = 11
	newLabel("Title", titleBar, title, UDim2.new(1, -40, 1, 0), Enum.TextXAlignment.Left).Position = UDim2.new(0, 12, 0, 0)

	local closeButton = newButton("Close", titleBar, "X", UDim2.new(0, 30, 0, 30))
	closeButton.Position = UDim2.new(1, -34, 0, 3)
	closeButton.ZIndex = 12
	closeButton.Name = "CloseButton"

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -20, 1, -48)
	content.Position = UDim2.new(0, 10, 0, 40)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ZIndex = 11
	content.ScrollBarThickness = 6
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.CanvasSize = UDim2.new(0, 0, 0, 0)
	content.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = content

	return panel
end

local function getPanelContent(panel: Frame): ScrollingFrame
	return panel:FindFirstChild("Content") :: ScrollingFrame
end

--============================================================================
-- Shop / Inventory / Daily Rewards row builders
--============================================================================

local function clearChildren(parent: Instance)
	for _, child in ipairs(parent:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function newSectionHeader(parent: Instance, layoutOrder: number, text: string)
	local label = newLabel(text .. "Header", parent, text, UDim2.new(1, 0, 0, 24), Enum.TextXAlignment.Left)
	label.LayoutOrder = layoutOrder
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(255, 215, 120)
end

-- Generic "name / status text / action button" row shared by the Shop and Inventory panels.
local function newActionRow(
	parent: Instance,
	layoutOrder: number,
	rowName: string,
	displayName: string,
	rarity: string?,
	statusText: string,
	buttonText: string,
	buttonEnabled: boolean,
	onClick: (() -> ())?
)
	local row = newFrame(rowName .. "Row", parent, UDim2.new(1, 0, 0, 40))
	row.LayoutOrder = layoutOrder
	row.BackgroundTransparency = 0.5
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 40)

	local nameLabel = newLabel("Name", row, displayName, UDim2.new(0.45, 0, 1, 0), Enum.TextXAlignment.Left)
	nameLabel.Position = UDim2.new(0, 8, 0, 0)
	nameLabel.TextColor3 = if rarity then RARITY_COLORS[rarity] or Color3.new(1, 1, 1) else Color3.new(1, 1, 1)

	local statusLabel = newLabel("Status", row, statusText, UDim2.new(0.3, 0, 1, 0), Enum.TextXAlignment.Left)
	statusLabel.Position = UDim2.new(0.45, 0, 0, 0)
	statusLabel.TextColor3 = Color3.fromRGB(190, 190, 195)
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 13

	local button = newButton("Action", row, buttonText, UDim2.new(0, 90, 0, 28))
	button.Position = UDim2.new(1, -98, 0.5, -14)
	if buttonEnabled and onClick then
		button.MouseButton1Click:Connect(onClick)
	else
		button.AutoButtonColor = false
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
		button.TextColor3 = Color3.fromRGB(130, 130, 135)
	end
end

local function populateShopPanel(content: ScrollingFrame, ownedIds: { string }, gold: number)
	clearChildren(content)
	local order = 0

	order += 1
	newSectionHeader(content, order, "Gold Shop")
	for _, item in ipairs(CosmeticCatalog) do
		if item.Price and item.Price > 0 then
			local owned = table.find(ownedIds, item.Id) ~= nil
			local canBuy = not owned and gold >= item.Price
			order += 1
			newActionRow(
				content,
				order,
				item.Id,
				item.Name,
				item.Rarity,
				if owned then "Owned" else ("%d gold"):format(item.Price),
				if owned then "Owned" else "Buy",
				canBuy,
				function()
					PurchaseCosmeticEvent:FireServer(item.Id)
				end
			)
		end
	end

	order += 1
	newSectionHeader(content, order, "Robux Shop")
	for _, item in ipairs(CosmeticCatalog) do
		if item.GamePassId then
			local gamePassId = (MonetizationIds.GamePasses :: { [string]: number })[item.GamePassId]
			local owned = table.find(ownedIds, item.Id) ~= nil
			order += 1
			newActionRow(content, order, item.Id, item.Name, item.Rarity, if owned then "Owned" else "Robux item", if owned then "Owned" else "Get", not owned, function()
				if gamePassId and gamePassId ~= 0 then
					MarketplaceService:PromptGamePassPurchase(LocalPlayer, gamePassId)
				end
			end)
		end
	end

	order += 1
	newSectionHeader(content, order, "Boosts & Revive")
	for key, productId in pairs(MonetizationIds.DeveloperProducts :: { [string]: number }) do
		order += 1
		newActionRow(content, order, key, DEV_PRODUCT_LABELS[key] or key, nil, "Robux", "Buy", true, function()
			if productId ~= 0 then
				MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
			end
		end)
	end
end

local function isEquipped(equipped: { [string]: any }, item: CosmeticItem): boolean
	if item.Category == "Emote" then
		return table.find(equipped.Emotes, item.Id) ~= nil
	end
	return equipped[item.Category] == item.Id
end

local function populateInventoryPanel(content: ScrollingFrame, ownedIds: { string }, equipped: { [string]: any })
	clearChildren(content)
	local order = 0

	for _, category in ipairs(CATEGORY_ORDER) do
		local headerAdded = false
		for _, item in ipairs(CosmeticCatalog) do
			if item.Category == category and table.find(ownedIds, item.Id) then
				if not headerAdded then
					order += 1
					newSectionHeader(content, order, category)
					headerAdded = true
				end

				local equippedNow = isEquipped(equipped, item)
				local canClick = item.Category == "Emote" or not equippedNow
				local buttonText = if equippedNow then (if item.Category == "Emote" then "Unequip" else "Equipped") else "Equip"

				order += 1
				newActionRow(content, order, item.Id, item.Name, item.Rarity, if equippedNow then "Equipped" else "", buttonText, canClick, function()
					EquipCosmeticEvent:FireServer(item.Id)
				end)
			end
		end
	end

	if order == 0 then
		newLabel("EmptyMessage", content, "You don't own any cosmetics yet — visit the Shop!", UDim2.new(1, 0, 0, 40), Enum.TextXAlignment.Left)
	end
end

local function populateDailyPanel(content: ScrollingFrame, canClaimLogin: boolean, streak: number, missionProgress: { [string]: { Count: number, Claimed: boolean } })
	clearChildren(content)

	newSectionHeader(content, 1, "Daily Login")
	newActionRow(content, 2, "DailyLogin", ("Streak: %d day(s)"):format(streak), nil, "", if canClaimLogin then "Claim" else "Claimed", canClaimLogin, function()
		ClaimDailyLoginEvent:FireServer()
	end)

	newSectionHeader(content, 3, "Daily Missions")
	local order = 3
	for _, mission in ipairs(DailyMissionCatalog) do
		local progress = missionProgress[mission.Id]
		local count = if progress then progress.Count else 0
		local claimed = if progress then progress.Claimed else false
		local complete = count >= mission.Target

		order += 1
		local buttonText = if claimed then "Claimed" elseif complete then "Claim" else "In Progress"
		newActionRow(
			content,
			order,
			mission.Id,
			("%s (%d/%d)"):format(mission.Name, count, mission.Target),
			nil,
			"",
			buttonText,
			complete and not claimed,
			function()
				ClaimMissionEvent:FireServer(mission.Id)
			end
		)
	end
end

--============================================================================
-- Instance methods
--============================================================================

function HudController.Start()
	local aliveCount = 0
	local phase = "Lobby"
	local roundStartClock = 0
	local settingsBuilt = false
	local openPanelName: string? = nil
	local panels: { [string]: Frame } = {}
	local isHost = false

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HudGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	local setDangerBorderLevel = newDangerBorder(screenGui)
	local currentGuardState = "Reading"
	local currentSuspicionTier = "Calm"

	-- Single source of truth for what the border should show right now, re-evaluated whenever
	-- any of the three inputs changes: outside a round it's always Hidden; Looking always wins
	-- over the ambient tier; otherwise it reflects the current Suspicion tier. This is also what
	-- makes "Looking ends -> immediately restores the current tier" correct for free — the
	-- moment GuardStateChanged reports "Reading" again, this just falls through to whatever
	-- currentSuspicionTier already is, not whatever it was before Looking started.
	local function refreshDangerBorder()
		if phase ~= "InProgress" then
			setDangerBorderLevel("Hidden")
			return
		end
		if currentGuardState == "Looking" then
			setDangerBorderLevel("Looking")
			return
		end
		if currentSuspicionTier == "High" then
			setDangerBorderLevel("High")
		elseif currentSuspicionTier == "Rising" then
			setDangerBorderLevel("Rising")
		else
			setDangerBorderLevel("Hidden")
		end
	end

	-- Top bar: players alive + round status
	local topBar = newFrame("TopBar", screenGui, UDim2.new(1, 0, 0, 40))
	local aliveLabel = newLabel("AliveLabel", topBar, "Players Alive: -", UDim2.new(0.3, 0, 1, 0), Enum.TextXAlignment.Left)
	aliveLabel.Position = UDim2.new(0, 12, 0, 0)
	-- Only shown at all once PartyCodeAssigned fires — public rooms/quick joins never get one.
	local partyCodeLabel = newLabel("PartyCodeLabel", topBar, "", UDim2.new(0.3, 0, 1, 0), Enum.TextXAlignment.Center)
	partyCodeLabel.Position = UDim2.new(0.3, 0, 0, 0)
	partyCodeLabel.TextColor3 = Color3.fromRGB(120, 200, 255)
	local statusLabel = newLabel("StatusLabel", topBar, "", UDim2.new(0.4, -52, 1, 0), Enum.TextXAlignment.Right)
	statusLabel.Position = UDim2.new(0.6, 0, 0, 0)

	-- Fixed top-right gear icon — the one entry point into Settings (including Leave Game),
	-- deliberately pinned to the corner instead of buried in the bottom button row so it's
	-- always in the same, expected spot regardless of what else the HUD is showing. 44x44 (not
	-- the original 36x36) to clear the ~44pt minimum touch target both Apple's and Google's own
	-- mobile HIG recommend — this one button isn't part of any FitToAvailableSpace-scaled
	-- subtree (see below), so shrinking it further on a small screen was never the fix here.
	local settingsIconButton = newButton("SettingsIconButton", screenGui, "\226\154\153", UDim2.new(0, 44, 0, 44))
	settingsIconButton.Position = UDim2.new(1, -54, 0, 6)
	settingsIconButton.TextSize = 20
	settingsIconButton.ZIndex = 20

	PartyCodeAssignedEvent.OnClientEvent:Connect(function(code: string)
		partyCodeLabel.Text = ("Party Code: %s"):format(code)
	end)

	-- "Spectating: <name>" + prev/next — visible only while SpectatorController reports
	-- actively spectating (see SpectateStateChanged below). Sits just below the 40px top bar,
	-- clear of the alive-count/party-code/status labels living INSIDE that bar, the settings
	-- gear (top-right corner), and the danger border's own 8px edge strips — nothing else lives
	-- in this exact spot. SpectatorController remains the sole owner of who's being spectated;
	-- this only ever displays what it reports, never tracks its own copy of the roster.
	local SPECTATE_PANEL_REFERENCE_SIZE = Vector2.new(268, 36)
	local spectatingPanel = newFrame("SpectatingPanel", screenGui, UDim2.new(0, 268, 0, 36), UDim2.new(0.5, -134, 0, 46), Color3.fromRGB(20, 20, 24))
	spectatingPanel.BackgroundTransparency = 0.25
	spectatingPanel.Visible = false
	spectatingPanel.ZIndex = 15

	do
		local spectateCamera = Workspace.CurrentCamera
		if spectateCamera then
			Widgets.FitToAvailableSpace(spectatingPanel, SPECTATE_PANEL_REFERENCE_SIZE, function()
				local currentCamera = Workspace.CurrentCamera
				return if currentCamera then currentCamera.ViewportSize else Vector2.zero
			end, spectateCamera:GetPropertyChangedSignal("ViewportSize"))
		end
	end

	local spectatePrevButton = newButton("SpectatePrev", spectatingPanel, "<", UDim2.new(0, 36, 1, 0))
	spectatePrevButton.ZIndex = 15
	spectatePrevButton.MouseButton1Click:Connect(function()
		SpectatorController:CycleTarget(-1)
	end)

	local spectateLabel = newLabel("SpectateLabel", spectatingPanel, "Spectating...", UDim2.new(0, 188, 1, 0), Enum.TextXAlignment.Center)
	spectateLabel.Position = UDim2.new(0, 40, 0, 0)
	spectateLabel.TextSize = 14
	spectateLabel.ZIndex = 15

	local spectateNextButton = newButton("SpectateNext", spectatingPanel, ">", UDim2.new(0, 36, 1, 0))
	spectateNextButton.Position = UDim2.new(0, 232, 0, 0)
	spectateNextButton.ZIndex = 15
	spectateNextButton.MouseButton1Click:Connect(function()
		SpectatorController:CycleTarget(1)
	end)

	SpectatorController.SpectateStateChanged:Connect(function(isSpectating: boolean, target: Player?)
		spectatingPanel.Visible = isSpectating
		if isSpectating and target then
			spectateLabel.Text = ("Spectating: %s"):format(target.Name)
			spectatePrevButton.Active = true
			spectateNextButton.Active = true
		else
			spectateLabel.Text = "Spectating..."
			spectatePrevButton.Active = false
			spectateNextButton.Active = false
		end
	end)

	-- Bottom bar: stats/meters row + button row
	local bottomBar = newFrame("BottomBar", screenGui, UDim2.new(1, 0, 0, 96), UDim2.new(0, 0, 1, -96))

	-- Both rows below are sized "1, -20" of bottomBar, i.e. already-responsive containers — the
	-- overflow risk is their CHILDREN's fixed pixel widths outgrowing that container on a narrow
	-- screen, not the row itself. So "available" is measured against the screen (ViewportSize
	-- minus that same 20px margin), never the row's own AbsoluteSize — see FitToAvailableSpace's
	-- doc comment in Widgets.luau for why using a target's own AbsoluteSize as the denominator
	-- would feed back into itself.
	local camera = Workspace.CurrentCamera
	local function availableRowSize(): Vector2
		local currentCamera = Workspace.CurrentCamera
		if not currentCamera then
			return Vector2.zero
		end
		local viewport = currentCamera.ViewportSize
		return Vector2.new(viewport.X - 20, viewport.Y)
	end

	local statsRow = newFrame("StatsRow", bottomBar, UDim2.new(1, -20, 0, 44), UDim2.new(0, 10, 0, 4))
	statsRow.BackgroundTransparency = 1
	-- Real content width at Scale 1: 3 labels (110 each) + 2 meters (160 each) + 4 gaps of 18.
	if camera then
		Widgets.FitToAvailableSpace(statsRow, Vector2.new(722, 44), availableRowSize, camera:GetPropertyChangedSignal("ViewportSize"))
	end
	local statsLayout = Instance.new("UIListLayout")
	statsLayout.FillDirection = Enum.FillDirection.Horizontal
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Padding = UDim.new(0, 18)
	statsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	statsLayout.Parent = statsRow

	local goldLabel = newLabel("GoldLabel", statsRow, "Gold: -", UDim2.new(0, 110, 1, 0), Enum.TextXAlignment.Left)
	goldLabel.LayoutOrder = 1
	local levelLabel = newLabel("LevelLabel", statsRow, "Level: -", UDim2.new(0, 110, 1, 0), Enum.TextXAlignment.Left)
	levelLabel.LayoutOrder = 2
	local xpLabel = newLabel("XPLabel", statsRow, "XP: -", UDim2.new(0, 110, 1, 0), Enum.TextXAlignment.Left)
	xpLabel.LayoutOrder = 3

	local _, setFoodMeter = newMeter(statsRow, 4, "Food %", Color3.fromRGB(90, 200, 120))
	local _, setNoiseMeter = newMeter(statsRow, 5, "Noise", Color3.fromRGB(220, 90, 90))

	local buttonRow = newFrame("ButtonRow", bottomBar, UDim2.new(1, -20, 0, 40), UDim2.new(0, 10, 0, 52))
	buttonRow.BackgroundTransparency = 1
	-- Real content width at Scale 1: 4 buttons (90+90+110+90) + 3 gaps of 10.
	if camera then
		Widgets.FitToAvailableSpace(buttonRow, Vector2.new(410, 40), availableRowSize, camera:GetPropertyChangedSignal("ViewportSize"))
	end
	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Padding = UDim.new(0, 10)
	buttonLayout.Parent = buttonRow

	-- Panels
	local inventoryPanel = createPanel(screenGui, "InventoryPanel", "Inventory")
	local inventoryContent = getPanelContent(inventoryPanel)
	local shopPanel = createPanel(screenGui, "ShopPanel", "Shop")
	local shopContent = getPanelContent(shopPanel)
	local dailyPanel = createPanel(screenGui, "DailyRewardsPanel", "Daily Rewards")
	local dailyContent = getPanelContent(dailyPanel)
	local settingsPanel = createPanel(screenGui, "SettingsPanel", "Settings")
	local settingsContent = getPanelContent(settingsPanel)
	panels.Inventory = inventoryPanel
	panels.Shop = shopPanel
	panels.DailyRewards = dailyPanel
	panels.Settings = settingsPanel

	for _, panel in pairs(panels) do
		local titleBar = panel:FindFirstChild("TitleBar")
		local closeButton = titleBar and titleBar:FindFirstChild("CloseButton")
		if closeButton and closeButton:IsA("TextButton") then
			closeButton.MouseButton1Click:Connect(function()
				panel.Visible = false
				openPanelName = nil
			end)
		end
	end

	local function togglePanel(name: string)
		local panel = panels[name]
		if not panel then
			return
		end
		if openPanelName == name then
			panel.Visible = false
			openPanelName = nil
			return
		end
		if openPanelName then
			local currentlyOpen = panels[openPanelName]
			if currentlyOpen then
				currentlyOpen.Visible = false
			end
		end
		panel.Visible = true
		openPanelName = name
	end

	local inventoryButton = newButton("InventoryButton", buttonRow, "Inventory", UDim2.new(0, 90, 1, 0))
	inventoryButton.LayoutOrder = 1
	inventoryButton.MouseButton1Click:Connect(function() togglePanel("Inventory") end)

	local shopButton = newButton("ShopButton", buttonRow, "Shop", UDim2.new(0, 90, 1, 0))
	shopButton.LayoutOrder = 2
	shopButton.MouseButton1Click:Connect(function() togglePanel("Shop") end)

	settingsIconButton.MouseButton1Click:Connect(function() togglePanel("Settings") end)

	local dailyButton = newButton("DailyRewardsButton", buttonRow, "Daily Rewards", UDim2.new(0, 110, 1, 0))
	dailyButton.LayoutOrder = 4
	dailyButton.MouseButton1Click:Connect(function() togglePanel("DailyRewards") end)

	local spectateButton = newButton("SpectateButton", buttonRow, "Spectate", UDim2.new(0, 90, 1, 0))
	spectateButton.LayoutOrder = 5
	spectateButton.MouseButton1Click:Connect(function()
		SpectatorController:StartSpectating()
	end)

	-- Floating "Fast Eating" toggle — explicit and easy to flip back, per design: this button is
	-- the ONLY way the requested mode changes (never a held key, so it works identically on
	-- touch and desktop). Sits just above the bottom bar rather than inside StatsRow/ButtonRow
	-- so it doesn't disturb their FitToAvailableSpace content-size math above. Only meaningful
	-- while actually eating, so it's hidden outside InProgress the same way reviveButton/
	-- startButton are (see RoundStateChangedEvent below).
	local fastModeButton = newButton("FastModeButton", screenGui, "Fast Eating: OFF", UDim2.new(0, 150, 0, 30))
	fastModeButton.Position = UDim2.new(0, 10, 1, -132)
	fastModeButton.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	fastModeButton.TextSize = 14
	fastModeButton.Visible = false

	local fastModeEnabled = false
	local function refreshFastModeButton()
		fastModeButton.Text = if fastModeEnabled then "Fast Eating: ON" else "Fast Eating: OFF"
		fastModeButton.BackgroundColor3 = if fastModeEnabled then Color3.fromRGB(70, 165, 90) else Color3.fromRGB(120, 60, 60)
	end
	refreshFastModeButton()

	fastModeButton.MouseButton1Click:Connect(function()
		fastModeEnabled = not fastModeEnabled
		refreshFastModeButton()
		EatingController:SetFastModeEnabled(fastModeEnabled)
	end)

	-- "CAUGHT" banner — shares every show/hide trigger with reviveButton below (see each site),
	-- so the two always appear and disappear together and can never desync. Sits directly above
	-- the revive button so both read as one connected message rather than two separate ones.
	local caughtBanner = newLabel("CaughtBanner", screenGui, "CAUGHT", UDim2.new(0, 240, 0, 32), Enum.TextXAlignment.Center)
	caughtBanner.Position = UDim2.new(0.5, -120, 0.55, -38)
	caughtBanner.TextColor3 = Color3.fromRGB(220, 90, 90)
	caughtBanner.TextSize = 24
	caughtBanner.Visible = false
	caughtBanner.ZIndex = 20

	-- Floating "Revive" — hidden unless the LOCAL player is currently eliminated, so it's
	-- front-and-center the moment it's actually usable instead of buried in the Shop's generic
	-- "Boosts & Revive" list. Its text/action depend on ReviveTierChanged (below): the first
	-- revive each round is free and skips MarketplaceService entirely; every one after that
	-- prompts a real purchase. PromptProductPurchase is a normal client-initiated call —
	-- MonetizationService/RevivalService (server) are the only real authority on whether either
	-- path actually does anything, this button is just a discoverable shortcut to them.
	local reviveButton = newButton("ReviveButton", screenGui, "Revive (Free)", UDim2.new(0, 240, 0, 50))
	reviveButton.Position = UDim2.new(0.5, -120, 0.55, 0)
	reviveButton.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	reviveButton.TextSize = 18
	reviveButton.Visible = false
	reviveButton.ZIndex = 20

	-- Maps the server's tier name to the matching Developer Product key — three separate
	-- products, not one, because a single Roblox product can't have a dynamic price. "Free"
	-- has no entry here on purpose: it never touches a product at all.
	local REVIVE_TIER_PRODUCT_KEY: { [string]: string } = {
		Second = "ReviveSecond",
		Third = "ReviveThird",
		FourthPlus = "ReviveFourthPlus",
	}

	local currentReviveTier = "Free"

	local function setReviveButtonForTier(tier: string)
		currentReviveTier = tier

		if tier == "Free" then
			reviveButton.Text = "Revive (Free)"
			return
		end

		local productKey = REVIVE_TIER_PRODUCT_KEY[tier]
		local productId = productKey and (MonetizationIds.DeveloperProducts :: { [string]: number })[productKey]
		if not productId or productId == 0 then
			reviveButton.Text = "Revive (Unavailable)"
			return
		end

		-- Real Robux price comes straight from Roblox rather than being hardcoded here, so the
		-- button never goes stale if the price is changed later in the Creator Dashboard.
		reviveButton.Text = "Revive with Robux"
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if currentReviveTier ~= tier then
				return -- a newer tier (or a hide) arrived while this was in flight
			end
			if ok and typeof(info) == "table" and info.PriceInRobux then
				reviveButton.Text = ("Revive (%d Robux)"):format(info.PriceInRobux)
			end
		end)
	end

	reviveButton.MouseButton1Click:Connect(function()
		if currentReviveTier == "Free" then
			RequestFreeReviveEvent:FireServer()
			return
		end

		local productKey = REVIVE_TIER_PRODUCT_KEY[currentReviveTier]
		local productId = productKey and (MonetizationIds.DeveloperProducts :: { [string]: number })[productKey]
		if productId and productId ~= 0 then
			MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
		else
			warn("This revive tier isn't configured yet — see Shared/Constants/MonetizationIds.luau.")
		end
	end)

	ReviveTierChangedEvent.OnClientEvent:Connect(function(tier: string)
		setReviveButtonForTier(tier)
	end)

	-- Floating "Start Game" — only ever visible to whoever HostChanged says is host, and only
	-- during Lobby (see RoundStateChangedEvent below). Host is "first joiner, reassigned
	-- randomly if they leave" (HostService, server-side) — enabling/labeling here is purely a
	-- convenience for the player, the server is the only real judge of whether a click counts.
	local startButton = newButton("StartButton", screenGui, "Start Game", UDim2.new(0, 240, 0, 50))
	startButton.Position = UDim2.new(0.5, -120, 0.45, 0)
	startButton.BackgroundColor3 = Color3.fromRGB(70, 165, 90)
	startButton.TextSize = 18
	startButton.Visible = false
	startButton.ZIndex = 20

	local function refreshStartButton()
		if not isHost or phase ~= "Lobby" then
			startButton.Visible = false
			return
		end

		startButton.Visible = true
		local playerCount = #Players:GetPlayers()
		local minPlayers = Shared.Constants.Players.Min
		if playerCount < minPlayers then
			startButton.Active = false
			startButton.BackgroundColor3 = Color3.fromRGB(70, 70, 75)
			startButton.Text = ("Start Game (need %d+)"):format(minPlayers)
		else
			startButton.Active = true
			startButton.BackgroundColor3 = Color3.fromRGB(70, 165, 90)
			startButton.Text = "Start Game"
		end
	end

	startButton.MouseButton1Click:Connect(function()
		RequestStartRoundEvent:FireServer()
	end)

	HostChangedEvent.OnClientEvent:Connect(function(hostPlayer: Player?)
		isHost = hostPlayer == LocalPlayer
		refreshStartButton()
	end)

	-- Remote hookups
	RoundStateChangedEvent.OnClientEvent:Connect(function(newPhase: string, secondsRemaining: number)
		phase = newPhase
		if phase == "InProgress" then
			roundStartClock = os.clock()
			-- A fresh round means everyone still connected is freshly seated and alive again —
			-- hide any stale revive prompt from the previous round.
			reviveButton.Visible = false
			caughtBanner.Visible = false
			fastModeButton.Visible = true
		else
			fastModeButton.Visible = false
		end
		-- Outside an active round, neither "the guard is Looking" nor a Suspicion tier means
		-- anything — refreshDangerBorder already forces Hidden whenever phase ~= "InProgress",
		-- rather than trusting whatever GuardStateChanged/SuspicionTierChanged last happened to
		-- say (they only fire on a change, not once per round, so they'd otherwise sit stale
		-- between rounds).
		refreshDangerBorder()
		if phase == "Intermission" then
			statusLabel.Text = ("Starting in %ds"):format(math.max(0, math.floor(secondsRemaining)))
		elseif phase == "Lobby" then
			if isHost then
				statusLabel.Text = ""
			else
				statusLabel.Text = "Waiting for the host to start..."
			end
			reviveButton.Visible = false
			caughtBanner.Visible = false
		elseif phase == "Ended" then
			statusLabel.Text = "Round over"
		end
		refreshStartButton()
	end)

	GuardStateChangedEvent.OnClientEvent:Connect(function(guardState: string)
		currentGuardState = guardState
		refreshDangerBorder()
	end)

	SuspicionTierChangedEvent.OnClientEvent:Connect(function(tier: string)
		currentSuspicionTier = tier
		refreshDangerBorder()
	end)

	RoundParticipantsEvent.OnClientEvent:Connect(function(participants: { Player })
		aliveCount = #participants
		aliveLabel.Text = ("Players Alive: %d"):format(aliveCount)
	end)

	PlayerCaughtEvent.OnClientEvent:Connect(function(caughtPlayer: Player)
		aliveCount = math.max(0, aliveCount - 1)
		aliveLabel.Text = ("Players Alive: %d"):format(aliveCount)
		if caughtPlayer == LocalPlayer then
			reviveButton.Visible = true
			caughtBanner.Visible = true
		end
	end)

	PlayerRevivedEvent.OnClientEvent:Connect(function(revivedPlayer: Player)
		aliveCount += 1
		aliveLabel.Text = ("Players Alive: %d"):format(aliveCount)
		if revivedPlayer == LocalPlayer then
			reviveButton.Visible = false
			caughtBanner.Visible = false
		end
	end)

	EatingStateChangedEvent.OnClientEvent:Connect(function(foodPercent: number, noise: number)
		setFoodMeter(foodPercent)
		setNoiseMeter(noise)
	end)

	ProfileSnapshotEvent.OnClientEvent:Connect(function(gold: number, xp: number, level: number, _wins: number, settings: { [string]: any })
		goldLabel.Text = ("Gold: %d"):format(gold)
		levelLabel.Text = ("Level: %d"):format(level)
		xpLabel.Text = ("XP: %d"):format(xp)

		if settingsBuilt then
			return
		end
		settingsBuilt = true

		createSlider(settingsContent, 1, "Music Volume", settings.MusicVolume, function(value)
			UpdateSettingEvent:FireServer("MusicVolume", value)
		end)
		createSlider(settingsContent, 2, "SFX Volume", settings.SfxVolume, function(value)
			UpdateSettingEvent:FireServer("SfxVolume", value)
		end)
		createSlider(settingsContent, 3, "Camera Sensitivity", settings.CameraSensitivity, function(value)
			UpdateSettingEvent:FireServer("CameraSensitivity", value)
		end)
		createCycle(settingsContent, 4, "Graphics", GRAPHICS_OPTIONS, settings.Graphics, function(value)
			UpdateSettingEvent:FireServer("Graphics", value)
		end)
		createToggle(settingsContent, 5, "Colorblind Mode", settings.ColorblindMode, function(value)
			UpdateSettingEvent:FireServer("ColorblindMode", value)
		end)
		createToggle(settingsContent, 6, "Motion Blur", settings.MotionBlur, function(value)
			UpdateSettingEvent:FireServer("MotionBlur", value)
		end)
		createToggle(settingsContent, 7, "Vibration", settings.Vibration, function(value)
			UpdateSettingEvent:FireServer("Vibration", value)
		end)

		-- "Leave Game" — a straight client-side Teleport back to this same place with no
		-- PrivateServerId, which is exactly what a normal (non-reserved) server is, so it lands
		-- back in the Hub — no server round-trip needed, same as PromptProductPurchase being a
		-- direct client call elsewhere in this file.
		local leaveRow = newFrame("LeaveRow", settingsContent, UDim2.new(1, 0, 0, 40))
		leaveRow.LayoutOrder = 8
		local leaveButton = newButton("LeaveButton", leaveRow, "Leave Game", UDim2.new(1, 0, 0, 36))
		leaveButton.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
		leaveButton.MouseButton1Click:Connect(function()
			TeleportService:Teleport(game.PlaceId, LocalPlayer)
		end)
	end)

	InventoryUpdatedEvent.OnClientEvent:Connect(function(ownedIds: { string }, equipped: { [string]: any }, gold: number)
		populateShopPanel(shopContent, ownedIds, gold)
		populateInventoryPanel(inventoryContent, ownedIds, equipped)
	end)

	DailyStateChangedEvent.OnClientEvent:Connect(function(canClaimLogin: boolean, streak: number, missionProgress: { [string]: { Count: number, Claimed: boolean } })
		populateDailyPanel(dailyContent, canClaimLogin, streak, missionProgress)
	end)

	RunService.Heartbeat:Connect(function()
		if phase == "InProgress" then
			local elapsed = math.max(0, os.clock() - roundStartClock)
			local minutes = math.floor(elapsed / 60)
			local seconds = math.floor(elapsed % 60)
			statusLabel.Text = ("Round in progress — %d:%02d"):format(minutes, seconds)
		elseif phase == "Lobby" then
			-- Live player count changes as friends join/leave during the wait — keep the Start
			-- button's enabled state and label current without needing a dedicated remote for it.
			refreshStartButton()
		end
	end)
end

return HudController
