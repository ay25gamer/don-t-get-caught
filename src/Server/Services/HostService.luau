--!strict
--[[
	HostService.luau

	Match-only. "Host" is deliberately just "the first player present in this server" — for a
	private party AND a public room alike, that's always the player who created it: PartyService
	and PublicRoomService both teleport their creator in immediately (see their file docs), long
	before anyone else could possibly have the party code or see the room in the public list, so
	the creator structurally always arrives first. No separate flag needs to travel through
	TeleportData just to mark them — arrival order already is that signal.

	Owns two things:
	  - Who currently holds host, reassigned to a random remaining player the instant the
	    current host leaves, so a room never gets stuck with nobody able to start it.
	  - The one host-gated action: starting the round early via RoundService:RequestStart()
	    instead of waiting on an automatic timer. The client is never trusted for this —
	    RequestStartRound is checked against whoever THIS service currently considers host, not
	    whatever the client claims about itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("HostService")

local RoundService = require(script.Parent.RoundService)

local HostChangedEvent = Shared.Remotes.GetEvent("HostChanged")
local RequestStartRoundEvent = Shared.Remotes.GetEvent("RequestStartRound")

local HostService = {}
-- Match-only — "host" is a private-party/public-room concept; the Hub has no rounds to start.
HostService.Modes = { "Match" }

local host: Player? = nil

local function setHost(newHost: Player?)
	host = newHost
	HostChangedEvent:FireAllClients(newHost)
	if newHost then
		Logger:Info(("%s is now the host."):format(newHost.Name))
	end
end

local function onPlayerAdded(player: Player)
	if not host then
		setHost(player)
		return
	end
	-- HostChangedEvent only reaches whoever's already connected at the moment it fires — a
	-- later joiner needs to be caught up individually or they'd never learn who it is.
	HostChangedEvent:FireClient(player, host)
end

local function onPlayerRemoving(player: Player)
	if host ~= player then
		return
	end

	local remaining = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			table.insert(remaining, other)
		end
	end

	if #remaining == 0 then
		setHost(nil)
		return
	end

	setHost(remaining[math.random(#remaining)])
end

local function onRequestStartRound(player: Player)
	if player ~= host then
		Logger:Warn(("%s tried to start the round but isn't the host."):format(player.Name))
		return
	end

	local started, errorMessage = RoundService:RequestStart()
	if not started then
		Logger:Info(("%s tried to start the round: %s"):format(player.Name, errorMessage or "failed"))
	end
end

function HostService.Start()
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	RequestStartRoundEvent.OnServerEvent:Connect(onRequestStartRound)
end

return HostService
