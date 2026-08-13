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

	game.PrivateServerId itself is NOT readable from the client — Roblox blocks it ("PrivateServerId
	cannot be checked on the client") and it reads back as "" there, which would make every client
	resolve to "Hub" no matter what server it's actually on. So the server resolves it once (the
	only place PrivateServerId is ever touched) and publishes the result onto a ReplicatedStorage
	Attribute — set during Server/init.server.luau, i.e. before any player can finish connecting —
	which the client reads instead. Attributes are a replicated property, not a one-shot event, so
	this is safe regardless of exactly when a given client's scripts start running.

	Studio testing: TeleportService (including ReserveServer, which is how every real Match server
	comes to exist — see PartyService/PublicRoomService) never works during Studio Play/Test; this
	is a Roblox platform restriction, not something fixable from script. A plain Hub server could
	therefore never actually reach a Match server in Studio, making Match-only content (HUD,
	eating, guard, spectator...) untestable. So in Studio specifically, this resolves to "Match" by
	default — set the Workspace Attribute "StudioServerMode" to "Hub" (Properties panel, or the
	Command Bar: workspace:SetAttribute("StudioServerMode", "Hub")) to test the Hub/matchmaking UI
	instead. Live servers never read this Attribute (IsStudio() is always false there), so
	production behavior is completely unaffected.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MODE_ATTRIBUTE = "ServerMode"
local STUDIO_MODE_ATTRIBUTE = "StudioServerMode"

local ServerMode = {}

export type Mode = "Hub" | "Match"

local function resolveOnServer(): Mode
	if game.PrivateServerId ~= "" then
		return "Match"
	end
	if RunService:IsStudio() then
		local override = Workspace:GetAttribute(STUDIO_MODE_ATTRIBUTE)
		if override == "Hub" then
			return "Hub"
		end
		return "Match"
	end
	return "Hub"
end

function ServerMode.Current(): Mode
	if RunService:IsServer() then
		local mode = resolveOnServer()
		ReplicatedStorage:SetAttribute(MODE_ATTRIBUTE, mode)
		return mode :: Mode
	end

	local mode = ReplicatedStorage:GetAttribute(MODE_ATTRIBUTE)
	if mode == "Match" then
		return "Match"
	end
	return "Hub"
end

return ServerMode
