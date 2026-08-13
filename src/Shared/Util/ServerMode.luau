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
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MODE_ATTRIBUTE = "ServerMode"

local ServerMode = {}

export type Mode = "Hub" | "Match"

function ServerMode.Current(): Mode
	if RunService:IsServer() then
		local mode: Mode = if game.PrivateServerId ~= "" then "Match" else "Hub"
		ReplicatedStorage:SetAttribute(MODE_ATTRIBUTE, mode)
		return mode
	end

	local mode = ReplicatedStorage:GetAttribute(MODE_ATTRIBUTE)
	if mode == "Match" then
		return "Match"
	end
	return "Hub"
end

return ServerMode
