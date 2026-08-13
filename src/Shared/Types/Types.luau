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

-- The client's requested eating speed — "Safe" (the original single behavior) or "Fast" (new,
-- faster progress for more noise). Sent as RequestBite's payload; EatingService is the only
-- thing that ever decides what either value actually means numerically (interval, noise) — see
-- its file doc.
export type EatingMode = "Safe" | "Fast"

-- A coarse, qualitative reading of the guard's private Suspicion meter — the ONLY thing about
-- Suspicion the client is ever allowed to know (see GuardService.luau and SuspicionTierChanged
-- in Remotes.luau). Never a number.
export type SuspicionTier = "Calm" | "Rising" | "High"

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
