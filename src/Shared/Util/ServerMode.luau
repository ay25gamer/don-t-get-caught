--!strict
--[[
	ServerMode.luau

	Whether this server is a "Hub" (the menu/matchmaking experience players land in via the
	normal in-game Play button — create/join a party, browse public rooms) or a "Match" (an
	actual round of Don't Get Caught). Same place, same Rojo project, two modes — see the
	README's "Lobby & Matchmaking" section for the full architecture.

	game.PrivateServerId is set by Roblox the instant a Reserved Server boots, before any
	player has joined, so this is knowable immediately at server start — no need to wait on
	player join data. Every Match server (both private parties and public rooms) is a Reserved
	Server, created via TeleportService:ReserveServer() by PartyService/PublicRoomService;
	ordinary direct joins (the normal Play button) never have a PrivateServerId, so they always
	land in a Hub server. Distinguishing "private party" from "public room" (both are Reserved
	Servers) needs an actual registry lookup — see RoomReportingService, not this module.

	Usable from both client and server — `game.PrivateServerId` is a public property.
]]

local ServerMode = {}

export type Mode = "Hub" | "Match"

function ServerMode.Current(): Mode
	if game.PrivateServerId ~= "" then
		return "Match"
	end
	return "Hub"
end

return ServerMode
