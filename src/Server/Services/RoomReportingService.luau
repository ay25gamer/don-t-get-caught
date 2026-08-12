--!strict
--[[
	RoomReportingService.luau

	Match-only. The other half of PublicRoomService's registry: on boot, checks whether THIS
	Reserved Server (game.PrivateServerId) has an entry in the "PublicRooms" DataStore. If it
	does, this server is a public room — created via PublicRoomService.CreatePublicRoom, which
	wrote that entry before anyone teleported in — and this service periodically publishes live
	player-count/phase updates. If no entry exists, this server is a private party (created via
	PartyService, which never touches the PublicRooms registry) and this service does nothing:
	that's the entire mechanism that keeps private parties unlisted.

	Cleans up after itself: publishes a "Remove" and deletes the DataStore entry both when the
	room empties out (nobody left to play) and on server shutdown (game:BindToClose) — a public
	room should never sit in the browsable list once it's not actually joinable.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("RoomReportingService")
local Constants = Shared.Constants

local Types = require(ReplicatedStorage.Shared.Types.Types)
type RoomInfo = Types.RoomInfo

local RoundService = require(script.Parent.RoundService)

local TOPIC = "PublicRoomUpdates"
local publicRoomsStore = DataStoreService:GetDataStore("PublicRooms")

local RoomReportingService = {}
RoomReportingService.__index = RoomReportingService
-- Match-only — see file doc and Shared/Util/ServerMode.luau.
RoomReportingService.Modes = { "Match" }

local self = setmetatable({
	_room = nil :: RoomInfo?,
	_heartbeatAccumulator = 0,
	_resyncAccumulator = 0,
	_cleanedUp = false,
}, RoomReportingService)

type Self = typeof(self)

local function currentRoomInfo(): RoomInfo
	local room = self._room :: RoomInfo
	return {
		RoomId = room.RoomId,
		AccessCode = room.AccessCode,
		HostName = room.HostName,
		PlayerCount = #Players:GetPlayers(),
		MaxPlayers = room.MaxPlayers,
		Phase = RoundService:GetPhase(),
		LastUpdate = os.time(),
	}
end

local function publishUpdate()
	local updated = currentRoomInfo()
	self._room = updated
	pcall(function()
		MessagingService:PublishAsync(TOPIC, { Type = "Update", Room = updated })
	end)
end

local function resyncDataStore()
	local room = self._room
	if not room then
		return
	end
	pcall(function()
		publicRoomsStore:SetAsync(room.RoomId, room)
	end)
end

local function cleanUp()
	if self._cleanedUp or not self._room then
		return
	end
	self._cleanedUp = true

	local roomId = self._room.RoomId
	pcall(function()
		MessagingService:PublishAsync(TOPIC, { Type = "Remove", RoomId = roomId })
	end)
	pcall(function()
		publicRoomsStore:RemoveAsync(roomId)
	end)
	Logger:Info("Public room removed from the registry.")
end

local function onHeartbeat(dt: number)
	if not self._room or self._cleanedUp then
		return
	end

	self._heartbeatAccumulator += dt
	if self._heartbeatAccumulator >= Constants.PublicRooms.HeartbeatInterval then
		self._heartbeatAccumulator = 0
		publishUpdate()
	end

	self._resyncAccumulator += dt
	if self._resyncAccumulator >= Constants.PublicRooms.IndexResyncInterval then
		self._resyncAccumulator = 0
		resyncDataStore()
	end
end

local function onPlayerRemoving(_player: Player)
	if not self._room then
		return
	end
	-- #Players:GetPlayers() still includes the leaving player during PlayerRemoving, so check
	-- for "about to reach zero" rather than "already at zero".
	if #Players:GetPlayers() <= 1 then
		cleanUp()
	end
end

function RoomReportingService.Start(self: Self)
	if game.PrivateServerId == "" then
		return
	end

	local ok, room = pcall(function()
		return publicRoomsStore:GetAsync(game.PrivateServerId) :: RoomInfo?
	end)
	if not ok or not room then
		return -- private party, or the lookup failed — either way, stay unlisted
	end

	self._room = room
	Logger:Info("This is a public room — starting registry heartbeat.")
	publishUpdate()

	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	game:BindToClose(cleanUp)
end

return self
