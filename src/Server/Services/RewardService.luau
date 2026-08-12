--!strict
--[[
	RewardService.luau

	Turns RoundService's round-lifecycle signals into permanent PlayerDataService progression:
	match/elimination/survival statistics for everyone who played, and Gold/XP/Wins/Level for
	the winner. This is the only system that writes those Statistics fields — GuardService only
	ever calls RoundService:EliminatePlayer(), it has no idea PlayerDataService exists, and
	RoundService itself has no idea progression exists either. Same separation as everywhere
	else: round timing/state, guard behavior, and player progression are three independent
	modules that only ever talk through RoundService's signals.

	A player who disconnects mid-round already had their ProfileStore session ended by
	PlayerDataService (see its PlayerRemoving handler) by the time anything here runs for them,
	so every write goes through PlayerDataService:GetData() and silently skips players whose
	data isn't available anymore instead of erroring.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("RewardService")
local Constants = Shared.Constants

local RoundService = require(script.Parent.RoundService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local RewardService = {}
RewardService.__index = RewardService
-- Match-only — see RoundService.luau for how this field is read via metatable fallback.
RewardService.Modes = { "Match" }

local self = setmetatable({
	_roundStartClock = 0,
	-- (player: Player, newLevel: number) -- fired whenever GrantXP() crosses a level threshold
	LevelUp = Shared.Signal.new(),
}, RewardService)

-- Colon-sugar methods would type their implicit `self` from the empty class table, not the
-- singleton above — see RoundService.luau for the full explanation.
type Self = typeof(self)

-- Built-in Highlight instance — no particle/texture asset needed, unlike a "real" celebration
-- effect would require. A future polish pass can replace this with real VFX/an actual victory
-- animation without touching anything else in this file.
local function celebrateWinner(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "WinnerHighlight"
	highlight.FillColor = Color3.fromRGB(255, 215, 0)
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0.5
	highlight.Parent = character

	Debris:AddItem(highlight, Constants.Round.EndedDisplayDuration)
end

local function onRoundStarted(participants: { Player })
	self._roundStartClock = os.clock()
	for _, player in ipairs(participants) do
		local data = PlayerDataService:GetData(player)
		if data then
			data.Statistics.MatchesPlayed += 1
		end
	end
end

local function onPlayerEliminated(player: Player, _remainingAliveCount: number)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	data.Statistics.TotalEliminations += 1
	data.Statistics.CurrentWinStreak = 0

	local survivedSeconds = os.clock() - self._roundStartClock
	data.Statistics.LongestSurvivalSeconds = math.max(data.Statistics.LongestSurvivalSeconds, survivedSeconds)
end

local function onRoundEnded(winner: Player?)
	if not winner then
		return
	end

	local data = PlayerDataService:GetData(winner)
	if not data then
		return
	end

	local goldGranted = Shared.Progression.GrantGold(data, Constants.Rewards.WinGold)
	local xpGranted, levelsGained = Shared.Progression.GrantXP(data, Constants.Rewards.WinXP)
	data.Wins += 1
	data.Statistics.CurrentWinStreak += 1

	local survivedSeconds = os.clock() - self._roundStartClock
	data.Statistics.LongestSurvivalSeconds = math.max(data.Statistics.LongestSurvivalSeconds, survivedSeconds)

	Logger:Info(
		("%s won the round! +%d gold, +%d XP (level %d, %d gold total)."):format(
			winner.Name,
			goldGranted,
			xpGranted,
			data.Level,
			data.Gold
		)
	)
	celebrateWinner(winner)

	if levelsGained > 0 then
		self.LevelUp:Fire(winner, data.Level)
	end
end

function RewardService.Start(self: Self)
	RoundService.RoundStarted:Connect(onRoundStarted)
	RoundService.PlayerEliminated:Connect(onPlayerEliminated)
	RoundService.RoundEnded:Connect(onRoundEnded)
end

return self
