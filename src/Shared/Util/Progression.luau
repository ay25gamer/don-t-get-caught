--!strict
--[[
	Progression.luau

	Centralizes XP/Level/Gold-granting math so RewardService and DailyService (and anything
	future that grants progression) can't drift out of sync on the leveling curve or how
	Double XP / Double Gold boosts (Constants.Monetization, granted by MonetizationService)
	apply. Pure functions — callers still own firing any signals/logging around the grant.

	`ProgressionData` is a minimal structural subset of PlayerDataService's real
	PlayerProfileData — this module lives in Shared (so both RewardService and DailyService can
	use it), and Shared must never depend on a server-only module like PlayerDataService.
	Any real PlayerProfileData value satisfies this structurally, so callers just pass
	`data` straight through with no cast needed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants.GameConstants)

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
