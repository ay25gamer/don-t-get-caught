--!strict
--[[
	Types.luau

	Shared type definitions used by both server and client. This module has no runtime
	behavior — other modules `local Types = require(...)` purely to reach into
	`Types.SomeExportedType` via `typeof`/`export type` re-use.

	Grows alongside each system. Keep game-loop-shaping enums here so every system agrees
	on the same vocabulary (e.g. RoundService and the client HUD both switch on RoundPhase).
]]

export type GuardState = "Reading" | "Looking"

export type RoundPhase = "Lobby" | "Intermission" | "InProgress" | "Ended"

-- A live public room, as tracked by PublicRoomService (Hub, in-memory cache) and
-- RoomReportingService (Match, the source of truth that publishes updates) — see the
-- README's "Lobby & Matchmaking" section. RoomId is always the Reserved Server's
-- PrivateServerId, so it doubles as the DataStore key and the MessagingService payload key.
export type RoomInfo = {
	RoomId: string,
	AccessCode: string,
	HostName: string,
	PlayerCount: number,
	MaxPlayers: number,
	Phase: RoundPhase,
	LastUpdate: number, -- os.time(); Hub servers drop entries older than Constants.PublicRooms.StaleAfterSeconds
}

return {}
