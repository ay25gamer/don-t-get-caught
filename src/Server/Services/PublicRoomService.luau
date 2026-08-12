--!strict
--[[
	PublicRoomService.luau

	Hub-only. Owns the live, browsable public-room list. A public room is a Reserved Server
	exactly like a private party (see PartyService) — the only difference is this service
	writes an entry for it into the "PublicRooms" DataStore/MessagingService registry, which is
	what RoomReportingService (running on the Match server itself) checks to decide whether to
	report in at all.

	Two data paths, deliberately different tools for different jobs:
	  - MessagingService ("PublicRoomUpdates" topic): near-real-time player-count/phase pings
	    from every live public Match server. Cheap, fast, high throughput — but a fresh Hub
	    server that just booted has received none of these yet (no replay of past messages).
	  - DataStore (:ListKeysAsync then :GetAsync per key): the durable fallback a freshly-booted
	    Hub reads ONCE to seed its cache, so the room list isn't empty for the first
	    `Constants.PublicRooms.HeartbeatInterval` seconds of a new Hub server's life.
	Thereafter, the MessagingService subscription keeps the cache live; stale entries (no ping
	in `Constants.PublicRooms.StaleAfterSeconds`) are swept out locally, independent of whether
	the source Match server cleaned up its own DataStore entry (e.g. it crashed).

	Known scale limit, acceptable for a small party game: :ListKeysAsync enumerates every room
	ever written until removed, so a large number of orphaned (crashed, never cleaned up) rooms
	would grow the seed-read cost over time. Not a concern at the player counts this game
	targets (2-10 per room); would need a proper expiring index for a much bigger game.
]]

local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("PublicRoomService")
local Constants = Shared.Constants

local Types = require(ReplicatedStorage.Shared.Types.Types)
type RoomInfo = Types.RoomInfo

local CreatePublicRoomFunction = Shared.Remotes.GetFunction("CreatePublicRoom")
local JoinPublicRoomFunction = Shared.Remotes.GetFunction("JoinPublicRoom")
local PublicRoomsUpdatedEvent = Shared.Remotes.GetEvent("PublicRoomsUpdated")

local TOPIC = "PublicRoomUpdates"
local MAX_SEED_ROOMS = 200 -- bound the initial DataStore seed read; see file doc

local publicRoomsStore = DataStoreService:GetDataStore("PublicRooms")

local PublicRoomService = {}
PublicRoomService.__index = PublicRoomService
-- Hub-only — see file doc and Shared/Util/ServerMode.luau.
PublicRoomService.Modes = { "Hub" }

local self = setmetatable({
	_rooms = {} :: { [string]: RoomInfo },
	_dirty = false,
}, PublicRoomService)

type Self = typeof(self)

local function isStale(room: RoomInfo): boolean
	return os.time() - room.LastUpdate > Constants.PublicRooms.StaleAfterSeconds
end

local function broadcastIfDirty()
	if not self._dirty then
		return
	end
	self._dirty = false

	local roomList = {}
	for roomId, room in pairs(self._rooms) do
		if isStale(room) then
			self._rooms[roomId] = nil
		else
			table.insert(roomList, room)
		end
	end

	PublicRoomsUpdatedEvent:FireAllClients(roomList)
end

local function applyUpdate(room: RoomInfo)
	self._rooms[room.RoomId] = room
	self._dirty = true
end

local function applyRemove(roomId: string)
	if self._rooms[roomId] then
		self._rooms[roomId] = nil
		self._dirty = true
	end
end

local function onMessage(message: { Data: any })
	local payload = message.Data
	if typeof(payload) ~= "table" then
		return
	end

	if payload.Type == "Update" and typeof(payload.Room) == "table" then
		applyUpdate(payload.Room :: RoomInfo)
	elseif payload.Type == "Remove" and typeof(payload.RoomId) == "string" then
		applyRemove(payload.RoomId)
	end
end

local function seedFromDataStore()
	local listOk, pages = pcall(function()
		return publicRoomsStore:ListKeysAsync()
	end)
	if not listOk then
		Logger:Warn("Failed to list existing public rooms — starting with an empty cache.")
		return
	end

	local seeded = 0
	while seeded < MAX_SEED_ROOMS do
		local items = pages:GetCurrentPage()
		for _, item in ipairs(items) do
			if seeded >= MAX_SEED_ROOMS then
				break
			end
			local getOk, room = pcall(function()
				return publicRoomsStore:GetAsync(item.KeyName) :: RoomInfo?
			end)
			if getOk and room and not isStale(room) then
				self._rooms[room.RoomId] = room
				self._dirty = true
			end
			seeded += 1
		end

		if pages.IsFinished then
			break
		end
		local advanceOk = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			break
		end
	end
end

local function onCreatePublicRoom(player: Player): (boolean, string?)
	-- See PartyService.onCreateParty for why this is checked up front, and why the reserve
	-- call below is wrapped in a timeout rather than a bare pcall.
	if game.PlaceId == 0 then
		Logger:Warn(("%s tried to create a public room, but this place has never been published."):format(player.Name))
		return false, "Public rooms require this game to be published to Roblox first."
	end

	local reserveOk, resultA, resultB = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not reserveOk then
		Logger:Warn(("Failed to reserve a public room for %s: %s"):format(player.Name, tostring(resultA)))
		return false, "Couldn't create a room right now. Please try again."
	end
	local accessCode: string, privateServerId: string = resultA, resultB

	local room: RoomInfo = {
		RoomId = privateServerId,
		AccessCode = accessCode,
		HostName = player.Name,
		PlayerCount = 0,
		MaxPlayers = Constants.Players.Max,
		Phase = "Lobby",
		LastUpdate = os.time(),
	}

	local saveOk = pcall(function()
		publicRoomsStore:SetAsync(room.RoomId, room)
	end)
	if not saveOk then
		return false, "Couldn't create a room right now. Please try again."
	end

	pcall(function()
		MessagingService:PublishAsync(TOPIC, { Type = "Update", Room = room })
	end)
	applyUpdate(room)

	local teleportOk = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		TeleportService:TeleportToPrivateServer(game.PlaceId, accessCode, { player })
	end)
	if not teleportOk then
		return false, "Room created, but couldn't join it — try Browse Public Rooms."
	end

	return true, nil
end

local function onJoinPublicRoom(player: Player, roomIdValue: unknown): (boolean, string?)
	if typeof(roomIdValue) ~= "string" then
		return false, "Invalid room."
	end

	local room = self._rooms[roomIdValue]
	if not room then
		return false, "That room is no longer available."
	end

	local teleportOk, teleportErr = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		TeleportService:TeleportToPrivateServer(game.PlaceId, room.AccessCode, { player })
	end)
	if not teleportOk then
		Logger:Warn(("Failed to teleport %s into room %s: %s"):format(player.Name, room.RoomId, tostring(teleportErr)))
		return false, "Couldn't join that room. It may have ended."
	end

	return true, nil
end

local broadcastAccumulator = 0

local function onHeartbeat(dt: number)
	broadcastAccumulator += dt
	if broadcastAccumulator < 1 then
		return
	end
	broadcastAccumulator = 0
	broadcastIfDirty()
end

function PublicRoomService.Start(self: Self)
	seedFromDataStore()

	local subscribeOk, connectionOrErr = pcall(function()
		return MessagingService:SubscribeAsync(TOPIC, onMessage)
	end)
	if not subscribeOk then
		Logger:Warn(("Failed to subscribe to public room updates: %s"):format(tostring(connectionOrErr)))
	end

	CreatePublicRoomFunction.OnServerInvoke = onCreatePublicRoom
	JoinPublicRoomFunction.OnServerInvoke = onJoinPublicRoom
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Push the seeded cache immediately rather than waiting up to a second for the first
	-- Heartbeat-throttled broadcast.
	self._dirty = true
	broadcastIfDirty()
end

return self
