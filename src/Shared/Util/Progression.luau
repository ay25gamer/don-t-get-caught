--!strict
--[[
	Progression.luau

	Centralizes XP/Level/Gold-granting math so RewardService and DailyService (and anything
	future that grants progression) can't drift out of sync on the leveling curve or how
	Double XP / Double Gold boosts (Constants.Monetization, granted by MonetizationService)
	apply. GrantXP/GrantGold stay pure (no side effects beyond mutating `data`) — callers decide
	whether/how to log the grant.

	`ProgressionData` is a minimal structural subset of PlayerDataService's real
	PlayerProfileData — this module lives in Shared (so both RewardService and DailyService can
	use it), and Shared must never depend on a server-only module like PlayerDataService.
	Any real PlayerProfileData value satisfies this structurally, so callers just pass
	`data` straight through with no cast needed.

	LevelUp is the single, canonical "a player just crossed a level threshold" notification —
	every XP-granting call site (RewardService on a round win, DailyService on a claimed
	mission) fires this itself once it sees GrantXP's returned levelsGained > 0, instead of each
	maintaining its own separate signal. ShopService (auto-unlocking level-gated cosmetics) is
	the one listener that needs this and only ever needs to subscribe once, here, regardless of
	how many systems end up granting XP in the future. Deliberately NOT fired from inside
	GrantXP itself — a "pure" calculation function silently also emitting an event is a hidden
	side effect callers wouldn't expect; firing it explicitly at each call site (right next to
	the GrantXP call whose result triggered it) keeps that visible.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants.GameConstants)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type ProgressionData = {
	XP: number,
	Level: number,
	Gold: number,
	Boosts: {
		DoubleXPUntil: number,
		DoubleGoldUntil: number,
	},
}

local Progression = {}

-- (player: Player, newLevel: number) -- fire this after any GrantXP call whose returned
-- levelsGained > 0. See the file doc for why this lives here instead of on RewardService.
Progression.LevelUp = Signal.new()

local function xpForLevel(level: number): number
	return level * Constants.Progression.XPPerLevel
end

-- Returns (xpActuallyGranted, levelsGained) so callers can log/react to a level-up.
function Progression.GrantXP(data: ProgressionData, baseAmount: number): (number, number)
	local boosted = if os.time() < data.Boosts.DoubleXPUntil then baseAmount * 2 else baseAmount
	local previousLevel = data.Level

	data.XP += boosted
	while data.XP >= xpForLevel(data.Level) do
		data.XP -= xpForLevel(data.Level)
		data.Level += 1
	end

	return boosted, data.Level - previousLevel
end

-- Returns the gold actually granted (post-boost) so callers can log it.
function Progression.GrantGold(data: ProgressionData, baseAmount: number): number
	local boosted = if os.time() < data.Boosts.DoubleGoldUntil then baseAmount * 2 else baseAmount
	data.Gold += boosted
	return boosted
end

return Progression
