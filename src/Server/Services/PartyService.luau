--!strict
--[[
	PartyService.luau

	Hub-only. Lets a player reserve a private Match server and get back a short, human-
	shareable code (not Roblox's own long access code) that a friend can type in to join the
	exact same server. Wraps every TeleportService/DataStore call in pcall — reserving a server
	or looking up a code can fail (rate limits, no network, Studio without API access), and a
	failure here should read as "try again," not crash the Hub.

	The short code is looked up via a DataStore, not held in memory — it must resolve correctly
	even if the friend joining lands on a DIFFERENT Hub server than the one that created it
	(likely, since Roblox spreads players across many Hub server instances).

	This is also what distinguishes a "private party" from a "public room" (see
	PublicRoomService/RoomReportingService) even though both are Reserved Servers under the
	hood: a party's access code only ever lives in this PartyCodes store, never in the public
	room registry, so RoomReportingService never finds an entry for it and never lists it.
]]

local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("PartyService")
local Constants = Shared.Constants

local CreatePartyFunction = Shared.Remotes.GetFunction("CreateParty")
local JoinPartyFunction = Shared.Remotes.GetFunction("JoinParty")

local partyCodesStore = DataStoreService:GetDataStore("PartyCodes")

local PartyService = {}
-- Hub-only — there's no "create a party" concept once you're already in a match.
PartyService.Modes = { "Hub" }

type PartyCodeEntry = {
	AccessCode: string,
	PrivateServerId: string,
	HostUserId: number,
	CreatedAt: number,
}

local function generateCode(): string
	local characters = Constants.Party.CodeCharacters
	local codeChars = {}
	for _ = 1, Constants.Party.CodeLength do
		local index = math.random(1, #characters)
		table.insert(codeChars, characters:sub(index, index))
	end
	return table.concat(codeChars)
end

local function onCreateParty(player: Player): (string?, string?, boolean?)
	-- game.PlaceId is 0 for a place that has never been published to Roblox — ReserveServer
	-- (and TeleportService generally) cannot work at all against PlaceId 0, and tends to hang
	-- rather than error cleanly when it can't, so this is checked BEFORE attempting the call
	-- (the Async.WithTimeout below is the second line of defense, for the published-but-Studio
	-- case where API access isn't enabled).
	if game.PlaceId == 0 then
		Logger:Warn(("%s tried to create a party, but this place has never been published."):format(player.Name))
		return nil, "Parties require this game to be published to Roblox first."
	end

	local reserveOk, resultA, resultB = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not reserveOk then
		Logger:Warn(("Failed to reserve a server for %s's party: %s"):format(player.Name, tostring(resultA)))
		return nil, "Couldn't create a party right now. Please try again."
	end
	local accessCode: string, privateServerId: string = resultA, resultB

	local code = generateCode()
	local entry: PartyCodeEntry = {
		AccessCode = accessCode,
		PrivateServerId = privateServerId,
		HostUserId = player.UserId,
		CreatedAt = os.time(),
	}

	local saveOk = pcall(function()
		partyCodesStore:SetAsync(code, entry)
	end)
	if not saveOk then
		Logger:Warn(("Failed to save a party code for %s."):format(player.Name))
		return nil, "Couldn't create a party right now. Please try again."
	end

	-- The host joins their own party immediately, same as CreatePublicRoom already does for
	-- its creator — there's no reason to leave them stuck looking at the Hub menu after they
	-- just made a room. The code rides along as TeleportData so PartyCodeService (Match-side)
	-- can put it back on screen once they land, letting them invite more friends later too.
	local teleportOk, teleportErr = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		-- Argument order is (placeId, accessCode, players, spawnName, teleportData,
		-- customLoadingScreen) — teleportData is 5th, NOT 6th. Passing the code table in the
		-- wrong slot silently made every one of these calls throw (customLoadingScreen expects
		-- an Instance, not a table), which is why this never actually teleported anyone.
		TeleportService:TeleportToPrivateServer(game.PlaceId, accessCode, { player }, nil, { PartyCode = code })
	end)
	if not teleportOk then
		Logger:Warn(("Party %s was created but failed to teleport host %s in: %s"):format(code, player.Name, tostring(teleportErr)))
		-- Still a valid party — the code works for JoinParty even if the host's own teleport
		-- glitched — so still return it rather than treating this as a hard failure, but flag
		-- it so the client can tell the host to use the code themselves instead of silently
		-- sitting on the Hub screen forever with no idea anything went wrong.
		Logger:Info(("%s created party %s."):format(player.Name, code))
		return code, nil, true
	end

	Logger:Info(("%s created party %s."):format(player.Name, code))
	return code, nil, false
end

local function onJoinParty(player: Player, codeValue: unknown): (boolean, string?)
	if typeof(codeValue) ~= "string" or #codeValue == 0 then
		return false, "Enter a party code first."
	end
	local code = string.upper(codeValue)

	local lookupOk, entry = pcall(function()
		return partyCodesStore:GetAsync(code) :: PartyCodeEntry?
	end)
	if not lookupOk or not entry then
		return false, "That code doesn't exist."
	end

	if os.time() - entry.CreatedAt > Constants.Party.CodeExpirySeconds then
		return false, "That code has expired."
	end

	local teleportOk, teleportErr = Shared.Async.WithTimeout(Constants.Party.ReserveServerTimeoutSeconds, function()
		TeleportService:TeleportToPrivateServer(game.PlaceId, entry.AccessCode, { player })
	end)
	if not teleportOk then
		Logger:Warn(("Failed to teleport %s into party %s: %s"):format(player.Name, code, tostring(teleportErr)))
		return false, "Couldn't join that party. It may have ended."
	end

	return true, nil
end

function PartyService.Start()
	CreatePartyFunction.OnServerInvoke = onCreateParty
	JoinPartyFunction.OnServerInvoke = onJoinParty
end

return PartyService
