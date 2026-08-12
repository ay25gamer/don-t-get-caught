--!strict
--[[
	Remotes.luau

	Central registry for every RemoteEvent/RemoteFunction in the game. The server creates the
	actual Instances (via Remotes.Init, called once from the server bootstrap); server and
	client code both fetch them through Remotes.GetEvent/GetFunction instead of poking around
	ReplicatedStorage directly.

	Add new remotes here as systems are built — do not create RemoteEvents ad-hoc inside a
	service. Naming convention: verb-based for events fired by the client requesting an action
	(e.g. "RequestEat"), noun/past-tense for events the server broadcasts (e.g. "PlayerCaught").

	IMPORTANT (server authority): remotes fired FROM the client must be treated as untrusted
	input. Every server-side handler must validate state itself (round phase, seat ownership,
	cooldowns, etc.) — never trust a value the client sends about itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type RemoteEventName = string
export type RemoteFunctionName = string

local RemoteEventDefinitions: { RemoteEventName } = {
	-- Client -> Server, no payload: "I attempted a bite right now." EatingService derives
	-- everything else (who, whether it counts, how much noise it makes) server-side.
	"RequestBite",

	-- Server -> all clients, fired on RoundService.RoundStarted with the participant list, so
	-- clients know the initial spectate-able roster before anyone's been caught.
	"RoundParticipants",
	-- Server -> all clients, fired on RoundService.PlayerEliminated with the caught Player.
	-- Every client uses this to drop that player from their local spectate roster; the caught
	-- player's own client uses it to enter spectator mode.
	"PlayerCaught",
	-- Server -> all clients, no payload, fired when the round returns to Lobby. Tells any
	-- still-spectating client to restore normal camera control.
	"SpectateReset",
	-- Server -> all clients, fired on RoundService.PlayerRevived with the revived Player.
	-- Every client adds them back to its local spectate roster; the revived player's own
	-- client exits spectator mode and restores normal camera control mid-round (unlike
	-- SpectateReset, which only fires at the end of a whole round).
	"PlayerRevived",

	-- Server -> all clients: (phase: string, secondsRemaining: number). secondsRemaining is
	-- only meaningful during "Intermission" (the countdown); HudController ignores it
	-- otherwise and just runs its own local stopwatch for "time in round" display.
	"RoundStateChanged",
	-- Server -> owning client only: (foodPercent: number, noise: number). A player's own
	-- eating/noise state — never broadcast, it isn't anyone else's business.
	"EatingStateChanged",
	-- Server -> owning client only: (gold, xp, level, wins, settings). Pushed once on profile
	-- load and resynced periodically so the HUD reflects RewardService's writes.
	"ProfileSnapshot",
	-- Client -> Server, no payload: "revive me for free." Only ever succeeds server-side if
	-- this is the player's first revive of the round — see RevivalService:AttemptFreeRevive.
	"RequestFreeRevive",
	-- Server -> owning client only: (tier: string, one of "Free"/"Second"/"Third"/"FourthPlus").
	-- Fired whenever a player is eliminated, telling THEM (and only them) what their next
	-- revive would cost — HudController's revive button reads this to decide whether to fire
	-- RequestFreeRevive directly or prompt the matching paid Developer Product. See
	-- RevivalService for why the price escalates and why only the tier name (not a Robux
	-- number) is sent — the client already looks up the real price via GetProductInfo.
	"ReviveTierChanged",
	-- Client -> Server: (settingKey: string, value: any). HudReplicationService validates the
	-- key/value against a known allow-list before writing it — see its SETTING_VALIDATORS.
	"UpdateSetting",

	-- Client -> Server: (itemId: string). ShopService validates price/funds/ownership.
	"PurchaseCosmetic",
	-- Client -> Server: (itemId: string). ShopService validates ownership (Gold or Game Pass).
	"EquipCosmetic",
	-- Server -> owning client: (ownedIds: {string}, equipped: table, gold: number). Pushed on
	-- profile load and after every purchase/equip/level-up so the Shop/Inventory UI stays live.
	"InventoryUpdated",
	-- Client -> Server, no payload: claim today's login reward.
	"ClaimDailyLogin",
	-- Client -> Server: (missionId: string): claim a completed daily mission's reward.
	"ClaimMission",
	-- Server -> owning client: (canClaimLogin: boolean, streak: number, missionProgress: table).
	-- Pushed on profile load and after any claim/progress change.
	"DailyStateChanged",

	-- Server (Hub only) -> all clients: (rooms: {RoomInfo}). The current full snapshot of live
	-- public rooms, broadcast whenever PublicRoomService's local cache changes. See its file
	-- doc for why this is push-based (subscribed to MessagingService) rather than polled.
	"PublicRoomsUpdated",
	-- Server (Match only) -> each client, fired once per player: (code: string). Only fires in
	-- a Match server that was created as a private party (see PartyCodeService) — lets the code
	-- stay visible in the HUD for the whole match so the host can invite MORE than just the one
	-- friend they shared it with before teleporting in.
	"PartyCodeAssigned",
	-- Server (Match only) -> all clients: (host: Player?). Fired whenever the current host
	-- changes — first joiner by default, reassigned randomly if they leave. See HostService.
	"HostChanged",
	-- Client -> Server (Match only), no payload: "start the round now." Server re-validates the
	-- sender is actually the current host and that enough players are present — see HostService.
	"RequestStartRound",
}

local RemoteFunctionDefinitions: { RemoteFunctionName } = {
	-- Client -> Server (Hub only): () -> (code: string?, errorMessage: string?,
	-- autoJoinFailed: boolean?). Reserves a private Match server and returns a short, human-
	-- shareable code for it. The host is auto-teleported in immediately; autoJoinFailed is true
	-- if THAT specific step failed (rare — network/API hiccup) even though the party itself
	-- was created fine — the code still works, the host just needs to use Join manually. See
	-- PartyService.
	"CreateParty",
	-- Client -> Server (Hub only): (code: string) -> (success: boolean, errorMessage: string?).
	-- Looks up a code created by CreateParty and teleports the caller into that server.
	"JoinParty",
	-- Client -> Server (Hub only): () -> (success: boolean, errorMessage: string?). Like
	-- CreateParty, but also lists the new server in the public room registry and teleports the
	-- creator in immediately. See PublicRoomService.
	"CreatePublicRoom",
	-- Client -> Server (Hub only): (roomId: string) -> (success: boolean, errorMessage: string?).
	-- Teleports the caller into an existing room from the PublicRoomsUpdated list.
	"JoinPublicRoom",
}

local Remotes = {}

local remotesFolder: Folder? = nil

local function getOrCreateFolder(): Folder
	if remotesFolder then
		return remotesFolder
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
		remotesFolder = folder
		return folder
	end

	local folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	remotesFolder = folder
	return folder
end

-- Must be called exactly once, from the server bootstrap, before any service starts.
function Remotes.Init()
	assert(RunService:IsServer(), "Remotes.Init must only be called from the server")
	local folder = getOrCreateFolder()

	for _, name in ipairs(RemoteEventDefinitions) do
		if not folder:FindFirstChild(name) then
			local remoteEvent = Instance.new("RemoteEvent")
			remoteEvent.Name = name
			remoteEvent.Parent = folder
		end
	end

	for _, name in ipairs(RemoteFunctionDefinitions) do
		if not folder:FindFirstChild(name) then
			local remoteFunction = Instance.new("RemoteFunction")
			remoteFunction.Name = name
			remoteFunction.Parent = folder
		end
	end
end

function Remotes.GetEvent(name: RemoteEventName): RemoteEvent
	local folder = getOrCreateFolder()
	return folder:WaitForChild(name) :: RemoteEvent
end

function Remotes.GetFunction(name: RemoteFunctionName): RemoteFunction
	local folder = getOrCreateFolder()
	return folder:WaitForChild(name) :: RemoteFunction
end

return Remotes
