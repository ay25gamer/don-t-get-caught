--!strict
--[[
	HubController.luau

	Hub-only. The menu players land in via the normal Play button: create a private party (get
	a short shareable code) or join one, and create/browse public rooms. HudController is the
	separate, Match-only equivalent for the actual game — see ServerMode.luau for why these
	stay as two entirely separate controllers instead of one mode-branching UI.

	Every action (CreateParty, JoinParty, CreatePublicRoom, JoinPublicRoom) is a RemoteFunction
	call — these yield the calling thread (a UI event handler's own coroutine, so nothing else
	freezes) until the server responds with success/failure, which is exactly the UX these need:
	the player is waiting for a real answer ("here's your code" / "that code doesn't exist"),
	not firing a request and hoping. Buttons disable themselves for the duration of their own
	in-flight call to prevent double-submission.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local Widgets = require(script.Parent.Parent.UI.Widgets)
local newFrame = Widgets.NewFrame
local newLabel = Widgets.NewLabel
local newButton = Widgets.NewButton
local newTextBox = Widgets.NewTextBox

local CreatePartyFunction = Shared.Remotes.GetFunction("CreateParty")
local JoinPartyFunction = Shared.Remotes.GetFunction("JoinParty")
local CreatePublicRoomFunction = Shared.Remotes.GetFunction("CreatePublicRoom")
local JoinPublicRoomFunction = Shared.Remotes.GetFunction("JoinPublicRoom")
local PublicRoomsUpdatedEvent = Shared.Remotes.GetEvent("PublicRoomsUpdated")

local LocalPlayer = Players.LocalPlayer

local HubController = {}
-- Hub-only — see file doc and Shared/Util/ServerMode.luau.
HubController.Modes = { "Hub" }

-- Wraps a button so clicking it disables it, runs `action` (which may yield on a RemoteFunction
-- call), and re-enables it afterward — prevents a slow/pending request from being fired twice.
local function withBusyGuard(button: TextButton, idleText: string, busyText: string, action: () -> ())
	button.MouseButton1Click:Connect(function()
		if not button.Active then
			return
		end
		button.Active = false
		button.Text = busyText
		-- action returns nothing on success, so pcall's precise generic type only accounts for
		-- one return value (the boolean); cast to sidestep that and still capture the error
		-- pcall always produces on failure regardless of the wrapped function's own signature.
		local ok, err = pcall(action :: any)
		if not ok then
			warn(("HubController action failed: %s"):format(tostring(err)))
		end
		button.Active = true
		button.Text = idleText
	end)
end

function HubController.Start()
	local statusMessage = ""

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HubGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local mainFrame = newFrame("MainFrame", screenGui, UDim2.new(0, 460, 0, 520), UDim2.new(0.5, -230, 0.5, -260), Color3.fromRGB(22, 22, 26))
	mainFrame.BackgroundTransparency = 0.05

	-- Every child below is already sized/positioned as a scale fraction of mainFrame (e.g.
	-- "1, -20" widths, "0.65"/"0.35" split inputs) — so scaling mainFrame itself down to fit a
	-- phone screen (never up, past its actual 460x520 design size) carries every one of those
	-- proportions with it for free; nothing else in this function needs to change.
	local camera = Workspace.CurrentCamera
	if camera then
		Widgets.FitToAvailableSpace(mainFrame, Vector2.new(460, 520), function()
			local currentCamera = Workspace.CurrentCamera
			return if currentCamera then currentCamera.ViewportSize else Vector2.zero
		end, camera:GetPropertyChangedSignal("ViewportSize"))
	end

	newLabel("Title", mainFrame, "Don't Get Caught", UDim2.new(1, 0, 0, 40), Enum.TextXAlignment.Center).Position = UDim2.new(0, 0, 0, 10)

	local statusLabel = newLabel("Status", mainFrame, "", UDim2.new(1, -20, 0, 30), Enum.TextXAlignment.Center)
	statusLabel.Position = UDim2.new(0, 10, 0, 50)
	statusLabel.TextColor3 = Color3.fromRGB(255, 210, 120)
	statusLabel.TextWrapped = true
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 14

	local function setStatus(message: string)
		statusMessage = message
		statusLabel.Text = statusMessage
	end

	-- "Play with Friends" section
	newLabel("PartyHeader", mainFrame, "Play with Friends", UDim2.new(1, -20, 0, 24), Enum.TextXAlignment.Left).Position = UDim2.new(0, 10, 0, 90)

	local createPartyButton = newButton("CreatePartyButton", mainFrame, "Create Party", UDim2.new(1, -20, 0, 36))
	createPartyButton.Position = UDim2.new(0, 10, 0, 118)

	local partyCodeBox = newTextBox("PartyCodeBox", mainFrame, "", UDim2.new(1, -20, 0, 36))
	partyCodeBox.Position = UDim2.new(0, 10, 0, 160)
	partyCodeBox.Text = ""
	partyCodeBox.TextXAlignment = Enum.TextXAlignment.Center
	partyCodeBox.Font = Enum.Font.GothamBold
	partyCodeBox.TextSize = 20
	partyCodeBox.Visible = false

	local joinCodeInput = newTextBox("JoinCodeInput", mainFrame, "Enter a party code...", UDim2.new(0.65, -15, 0, 36))
	joinCodeInput.Position = UDim2.new(0, 10, 0, 206)

	local joinPartyButton = newButton("JoinPartyButton", mainFrame, "Join", UDim2.new(0.35, -5, 0, 36))
	joinPartyButton.Position = UDim2.new(0.65, 5, 0, 206)

	withBusyGuard(createPartyButton, "Create Party", "Creating...", function()
		local code, errorMessage, autoJoinFailed = CreatePartyFunction:InvokeServer()
		if code then
			partyCodeBox.Text = code :: string
			partyCodeBox.Visible = true
			if autoJoinFailed then
				-- The party itself is valid (the code works), only the automatic teleport-in
				-- glitched — pre-fill Join with the same code so getting in is a single click
				-- instead of leaving the host stuck looking at this screen with no path forward.
				joinCodeInput.Text = code :: string
				setStatus("Party created, but couldn't join automatically — press Join below to get in.")
			else
				setStatus("Party created! Share this code with your friend.")
			end
		else
			setStatus(errorMessage or "Couldn't create a party.")
		end
	end)

	withBusyGuard(joinPartyButton, "Join", "Joining...", function()
		local success, errorMessage = JoinPartyFunction:InvokeServer(joinCodeInput.Text)
		if success then
			setStatus("Joining party...")
		else
			setStatus(errorMessage or "Couldn't join that party.")
		end
	end)

	-- "Public Rooms" section
	newLabel("PublicHeader", mainFrame, "Public Rooms", UDim2.new(1, -20, 0, 24), Enum.TextXAlignment.Left).Position = UDim2.new(0, 10, 0, 256)

	local createRoomButton = newButton("CreatePublicRoomButton", mainFrame, "Create Public Room", UDim2.new(1, -20, 0, 36))
	createRoomButton.Position = UDim2.new(0, 10, 0, 284)

	withBusyGuard(createRoomButton, "Create Public Room", "Creating...", function()
		local success, errorMessage = CreatePublicRoomFunction:InvokeServer()
		if success then
			setStatus("Room created! Joining...")
		else
			setStatus(errorMessage or "Couldn't create a room.")
		end
	end)

	local roomList = Instance.new("ScrollingFrame")
	roomList.Name = "RoomList"
	roomList.Size = UDim2.new(1, -20, 1, -336)
	roomList.Position = UDim2.new(0, 10, 0, 328)
	roomList.BackgroundColor3 = Color3.fromRGB(16, 16, 19)
	roomList.BackgroundTransparency = 0.1
	roomList.BorderSizePixel = 0
	roomList.ScrollBarThickness = 6
	roomList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	roomList.CanvasSize = UDim2.new(0, 0, 0, 0)
	roomList.Parent = mainFrame

	local roomListLayout = Instance.new("UIListLayout")
	roomListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	roomListLayout.Padding = UDim.new(0, 4)
	roomListLayout.Parent = roomList

	local function buildRoomRow(order: number, room: { [string]: any })
		local row = newFrame(("Room_%s"):format(room.RoomId), roomList, UDim2.new(1, -8, 0, 40), nil, Color3.fromRGB(32, 32, 38))
		row.LayoutOrder = order

		local label = newLabel(
			"Info",
			row,
			("%s's room — %d/%d players (%s)"):format(room.HostName, room.PlayerCount, room.MaxPlayers, room.Phase),
			UDim2.new(0.65, 0, 1, 0),
			Enum.TextXAlignment.Left
		)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.Font = Enum.Font.Gotham
		label.TextSize = 14

		local joinButton = newButton("Join", row, "Join", UDim2.new(0, 80, 0, 28))
		joinButton.Position = UDim2.new(1, -88, 0.5, -14)

		local full = room.PlayerCount >= room.MaxPlayers
		if full then
			joinButton.Active = false
			joinButton.Text = "Full"
			joinButton.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
		else
			withBusyGuard(joinButton, "Join", "Joining...", function()
				local success, errorMessage = JoinPublicRoomFunction:InvokeServer(room.RoomId)
				if success then
					setStatus("Joining room...")
				else
					setStatus(errorMessage or "Couldn't join that room.")
				end
			end)
		end
	end

	PublicRoomsUpdatedEvent.OnClientEvent:Connect(function(rooms: { { [string]: any } })
		for _, child in ipairs(roomList:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		if #rooms == 0 then
			newLabel("EmptyMessage", roomList, "No public rooms right now — create one!", UDim2.new(1, -8, 0, 30), Enum.TextXAlignment.Left)
			return
		end

		for index, room in ipairs(rooms) do
			buildRoomRow(index, room)
		end
	end)
end

return HubController
