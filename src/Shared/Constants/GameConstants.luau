--!strict
--[[
	GameConstants.luau

	Single source of truth for game tuning values. Server-authoritative systems read from
	here; this module defines numbers/strings only, no logic, so designers can retune the
	game without touching behavior code.

	Values below come directly from the game design (round pacing, guard timing windows,
	player limits). Later systems (RoundService, GuardService, SeatingService, ...) must
	read from here instead of hardcoding literals.
]]

local GameConstants = {}

GameConstants.Players = {
	Min = 2,
	Max = 10,
}

GameConstants.Seating = {
	SeatCount = 10,
}

GameConstants.Round = {
	IntermissionCountdown = 15, -- seconds between "minimum players reached" and round start
	MinDuration = 120, -- 2 minutes, soft floor used for pacing/analytics
	MaxDuration = 300, -- 5 minutes, hard cap before the round is force-ended
	EndedDisplayDuration = 8, -- seconds the "winner" screen holds before returning to Lobby
}

GameConstants.Guard = {
	ReadingDurationMin = 0.5,
	ReadingDurationMax = 10,
	LookingDurationMin = 1,
	LookingDurationMax = 2,
	-- How long after Looking begins detection stays OFF, giving a player a genuine chance to
	-- stop eating before the guard actually starts checking — see GuardService.luau. Well under
	-- LookingDurationMin so a real detection window always remains afterward; this is a delay
	-- on WHEN checks start, never a change to what counts as "still eating."
	LookingReactionWindow = 0.3,

	-- Second Look: after a NORMAL Looking phase ends, a chance the following Reading is short,
	-- leading into a quick second glance soon after the first. See GuardService.luau for the
	-- full state machine and why this structurally can never chain into a third consecutive
	-- quick look (a mandatory full-length Reading always follows a second look).
	SecondLookReadingMax = 1.5, -- floor reuses ReadingDurationMin above; only the ceiling shrinks
	SecondLookBaseChance = 0.05, -- chance to trigger at Suspicion 0 — never truly zero
	SecondLookMaxChance = 0.35, -- chance to trigger at Suspicion Max — never a guarantee
}

-- The GUARD's global suspicion meter — invisible to players (see design doc). Distinct from
-- GameConstants.Noise, which is each player's own visible, individual meter.
GameConstants.Suspicion = {
	Max = 100,
	DecayPerSecond = 2,
	PerEatingPlayerPerSecond = 3, -- passive trickle per currently-eating alive player, per second ("many players eating")
	PerNoisePoint = 0.5, -- suspicion added per point a player's own noise meter rises ("loud noises" / "rapid bites")
	ReadingDurationInfluence = 0.7, -- 0-1, how much max suspicion compresses the next Reading duration toward the minimum
	-- Coarse, qualitative bands the CLIENT is allowed to know about (see SuspicionTierChanged in
	-- Remotes.luau) — the real 0-100 number itself never leaves the server. A value at or above
	-- a threshold belongs to that tier.
	RisingThreshold = 30,
	HighThreshold = 70,
}

GameConstants.Eating = {
	FullPercent = 100,
	BitesToFinish = 12, -- number of successful bites needed to go from 0% to FullPercent
	BiteInterval = 0.6, -- seconds; server-enforced minimum time between "Safe" mode bites
	-- "Fast" mode: exactly half BiteInterval — 12 bites in 3.6s instead of 7.2s. A real edge in
	-- the "first to finish wins" race (see RoundService:PlayerCompletedFood). Paid for in noise:
	-- EatingService charges Noise.SpamNoiseMultiplier per Fast bite instead of the normal rate —
	-- deliberately reusing that existing, already-tuned number rather than inventing a new one,
	-- since "Fast Eating" is mechanically "always pay the spam-click noise cost, but have it
	-- actually count." See EatingService.luau for how the mode is requested by the client but
	-- entirely enforced server-side.
	FastBiteInterval = 0.3,
}

GameConstants.Noise = {
	Max = 100,
	BaseBiteNoise = 12, -- added to a player's own noise meter per valid, well-timed bite
	SpamNoiseMultiplier = 2.5, -- multiplier applied instead when a bite request arrives before BiteInterval has elapsed — spam-clicking makes noise but doesn't speed up eating
	DecayPerSecond = 18, -- how fast a player's noise meter drains per second while they aren't generating noise
}

GameConstants.DataStore = {
	ProfileStoreName = "PlayerData",
}

GameConstants.Rewards = {
	WinGold = 50,
	WinXP = 100,
	-- A small, one-time-per-round payout for a player who gets caught, so an early elimination
	-- doesn't feel like a totally wasted round. Deliberately well below WinGold/WinXP (20%/15%)
	-- so winning always stays clearly better than losing — see RewardService.luau for the
	-- once-per-round guard (getting revived and caught again doesn't grant this twice).
	EliminationConsolationGold = 10,
	EliminationConsolationXP = 15,
}

GameConstants.Progression = {
	XPPerLevel = 100, -- flat XP required per level; simple placeholder curve, easy to replace later
}

-- CollectionService tag names. Centralized so the system that creates tagged instances (a map
-- builder) and the system(s) that consume them (SeatingService) always agree on the literal
-- string without duplicating it. The guard itself is a singleton looked up by fixed path
-- (Workspace.DiningRoom.Guard — see GuardService/PlaceholderMapService), not by tag: unlike
-- seats, there's only ever one, so a CollectionService tag would add indirection with no real
-- discovery problem to solve.
GameConstants.Tags = {
	DinnerSeat = "DinnerSeat",
}

GameConstants.Monetization = {
	BoostDurationSeconds = 24 * 60 * 60, -- how long a Double XP / Double Gold purchase lasts
}

-- How many missions are active is however many DailyMissionCatalog.luau lists — no separate
-- "Count" here, so there's exactly one place to add/remove a mission.
GameConstants.DailyMissions = {
	RewardGold = 100,
	RewardXP = 150,
}

-- Separate from DailyMissions: a simple login-streak reward, distinct from mission tasks (see
-- the design doc's Lobby UI "Daily Rewards" vs. "DAILY MISSIONS" sections).
GameConstants.DailyLogin = {
	BaseGold = 50,
	StreakBonusGoldPerDay = 10,
	MaxStreakBonusDays = 7, -- streak bonus caps here so it never grows unbounded
}

GameConstants.Party = {
	CodeLength = 6,
	-- No 0/O/1/I — visually ambiguous characters a friend might mistype when reading a shared code aloud or off a screenshot.
	CodeCharacters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789",
	CodeExpirySeconds = 6 * 60 * 60, -- 6 hours; DataStore has no native TTL, so this is checked at lookup time
	ReserveServerTimeoutSeconds = 8, -- TeleportService:ReserveServer() can hang rather than error (e.g. an unpublished place); see Async.WithTimeout
}

GameConstants.PublicRooms = {
	HeartbeatInterval = 15, -- seconds between a Match server's live MessagingService pings
	StaleAfterSeconds = 45, -- a Hub drops a room from its local cache if no ping arrives in this long
	IndexResyncInterval = 30, -- seconds between a Match server refreshing the durable DataStore entry (what freshly-booted Hubs read to seed their cache)
}

return GameConstants
