--!strict
--[[
	DailyMissionCatalog.luau

	Fixed set of daily missions — not randomized/drawn from a larger pool, to keep
	DailyMissionService simple. Every mission resets (progress cleared, claimed reset) once a
	day; see DailyMissionService for the reset check. Every mission pays the same flat reward
	(Constants.DailyMissions.RewardGold/RewardXP) when claimed — per-mission custom rewards
	would need a richer catalog entry, not worth it for 3 missions.

	Add a mission by adding an entry here and a case in DailyMissionService's progress-tracking
	signal handlers for its Type — nothing else needs to change.
]]

export type MissionType = "SurviveRounds" | "WinGames" | "FinishFood"

export type MissionDefinition = {
	Id: string,
	Type: MissionType,
	Name: string,
	Target: number,
}

local DailyMissionCatalog: { MissionDefinition } = {
	{ Id = "SurviveThree", Type = "SurviveRounds", Name = "Survive 3 rounds", Target = 3 },
	{ Id = "WinOne", Type = "WinGames", Name = "Win 1 game", Target = 1 },
	{ Id = "FinishFive", Type = "FinishFood", Name = "Finish your food 5 times", Target = 5 },
}

return DailyMissionCatalog
