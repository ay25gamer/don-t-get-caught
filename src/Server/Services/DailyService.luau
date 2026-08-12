--!strict
--[[
	DailyService.luau

	Two independent daily systems that happen to share one "Daily Rewards" UI panel:

	  Daily login reward  -- PlayerProfileData.DailyRewards (Streak/LastClaimedTimestamp,
	                          reserved since step 2). Claimed manually via ClaimDailyLogin;
	                          streak increments if claimed on the calendar day right after the
	                          last claim, resets to 1 otherwise, capped for reward purposes at
	                          Constants.DailyLogin.MaxStreakBonusDays.
	  Daily missions      -- DailyMissionCatalog.luau (Shared, same "one list, read by both
	                          sides" pattern as CosmeticCatalog). Progress tracked purely by
	                          reacting to RoundService/EatingService signals — this service
	                          never decides whether a round was won or food was finished, it
	                          only counts. Claimed manually via ClaimMission once a mission's
	                          Count reaches its Target.

	Both use UTC calendar days (os.date("!*t", ...)) for "is this a new day" checks, so results
	don't depend on the server's local timezone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("DailyService")
local Constants = Shared.Constants

-- Required directly (not via the Shared aggregator) so its exported type can be imported below
-- — Luau's require-based type import only links through a direct require() call, not an
-- indexing expression like Shared.DailyMissionCatalog.
local DailyMissionCatalog = require(ReplicatedStorage.Shared.Data.DailyMissionCatalog)
type MissionDefinition = typeof(DailyMissionCatalog[1])

local RoundService = require(script.Parent.RoundService)
local EatingService = require(script.Parent.EatingService)
local PlayerDataService = require(script.Parent.PlayerDataService)

type PlayerProfileData = PlayerDataService.PlayerProfileData

local ClaimDailyLoginEvent = Shared.Remotes.GetEvent("ClaimDailyLogin")
local ClaimMissionEvent = Shared.Remotes.GetEvent("ClaimMission")
local DailyStateChangedEvent = Shared.Remotes.GetEvent("DailyStateChanged")

local SECONDS_PER_DAY = 24 * 60 * 60

-- Neither remote has a natural cooldown of its own — see RateLimiter.luau. The once-per-day
-- claim logic itself already blocks repeat grants; this just stops a scripted client from
-- spamming the check.
local claimLoginLimiter = Shared.RateLimiter.new(0.5)
local claimMissionLimiter = Shared.RateLimiter.new(0.5)

local DailyService = {}
DailyService.__index = DailyService

local self = setmetatable({
	-- Players still "surviving" the current round — everyone at RoundStarted, minus anyone
	-- PlayerEliminated removes. Whoever's left when RoundEnded fires gets SurviveRounds credit.
	_survivingThisRound = {} :: { [Player]: boolean },
}, DailyService)

type Self = typeof(self)

local function utcDateKey(timestamp: number): string
	local date = os.date("!*t", timestamp) :: { year: number, month: number, day: number }
	return ("%d-%d-%d"):format(date.year, date.month, date.day)
end

local function findMission(missionId: string): MissionDefinition?
	for _, candidate in ipairs(DailyMissionCatalog) do
		if candidate.Id == missionId then
			return candidate
		end
	end
	return nil
end

local function ensureMissionsCurrent(data: PlayerProfileData)
	local now = os.time()
	if utcDateKey(now) == utcDateKey(data.Missions.LastRefreshTimestamp) then
		return
	end

	data.Missions.LastRefreshTimestamp = now
	for _, mission in ipairs(DailyMissionCatalog) do
		data.Missions.Progress[mission.Id] = { Count = 0, Claimed = false }
	end
end

local function pushDailyState(player: Player, data: PlayerProfileData)
	ensureMissionsCurrent(data)

	local canClaimLogin = utcDateKey(os.time()) ~= utcDateKey(data.DailyRewards.LastClaimedTimestamp)
	DailyStateChangedEvent:FireClient(player, canClaimLogin, data.DailyRewards.Streak, data.Missions.Progress)
end

local function incrementMission(player: Player, missionType: string, amount: number)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	ensureMissionsCurrent(data)

	local changed = false
	for _, mission in ipairs(DailyMissionCatalog) do
		if mission.Type == missionType then
			local progress = data.Missions.Progress[mission.Id]
			if progress and not progress.Claimed and progress.Count < mission.Target then
				progress.Count = math.min(mission.Target, progress.Count + amount)
				changed = true
			end
		end
	end

	if changed then
		pushDailyState(player, data)
	end
end

local function onRoundStarted(participants: { Player })
	self._survivingThisRound = {}
	for _, player in ipairs(participants) do
		self._survivingThisRound[player] = true
	end
end

local function onPlayerEliminated(player: Player, _remainingAliveCount: number)
	self._survivingThisRound[player] = nil
end

local function onRoundEnded(winner: Player?)
	for player in pairs(self._survivingThisRound) do
		incrementMission(player, "SurviveRounds", 1)
	end
	self._survivingThisRound = {}

	if winner then
		incrementMission(winner, "WinGames", 1)
	end
end

local function onPlayerFinishedEating(player: Player)
	incrementMission(player, "FinishFood", 1)
end

local function onClaimDailyLogin(player: Player)
	if not claimLoginLimiter:TryAcquire(player) then
		return
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	local now = os.time()
	local todayKey = utcDateKey(now)
	if todayKey == utcDateKey(data.DailyRewards.LastClaimedTimestamp) then
		return -- already claimed today
	end

	local yesterdayKey = utcDateKey(now - SECONDS_PER_DAY)
	if utcDateKey(data.DailyRewards.LastClaimedTimestamp) == yesterdayKey then
		data.DailyRewards.Streak += 1
	else
		data.DailyRewards.Streak = 1
	end
	data.DailyRewards.LastClaimedTimestamp = now

	local bonusDays = math.min(data.DailyRewards.Streak - 1, Constants.DailyLogin.MaxStreakBonusDays)
	local gold = Constants.DailyLogin.BaseGold + bonusDays * Constants.DailyLogin.StreakBonusGoldPerDay
	local granted = Shared.Progression.GrantGold(data, gold)

	Logger:Info(("%s claimed the daily login reward: +%d gold (streak %d)."):format(player.Name, granted, data.DailyRewards.Streak))
	pushDailyState(player, data)
end

local function onClaimMission(player: Player, missionIdValue: unknown)
	if not claimMissionLimiter:TryAcquire(player) then
		return
	end
	if typeof(missionIdValue) ~= "string" then
		return
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	ensureMissionsCurrent(data)

	local mission = findMission(missionIdValue)
	if not mission then
		return
	end

	local progress = data.Missions.Progress[mission.Id]
	if not progress or progress.Claimed or progress.Count < mission.Target then
		return
	end

	progress.Claimed = true
	local gold = Shared.Progression.GrantGold(data, Constants.DailyMissions.RewardGold)
	local xp = Shared.Progression.GrantXP(data, Constants.DailyMissions.RewardXP)

	Logger:Info(("%s claimed mission '%s': +%d gold, +%d XP."):format(player.Name, mission.Name, gold, xp))
	pushDailyState(player, data)
end

local function onProfileLoaded(player: Player, _profile: unknown)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	pushDailyState(player, data)
end

local function onPlayerRemoving(player: Player)
	self._survivingThisRound[player] = nil
	claimLoginLimiter:Clear(player)
	claimMissionLimiter:Clear(player)
end

function DailyService.Start(self: Self)
	RoundService.RoundStarted:Connect(onRoundStarted)
	RoundService.PlayerEliminated:Connect(onPlayerEliminated)
	RoundService.RoundEnded:Connect(onRoundEnded)
	EatingService.PlayerFinishedEating:Connect(onPlayerFinishedEating)
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	ClaimDailyLoginEvent.OnServerEvent:Connect(onClaimDailyLogin)
	ClaimMissionEvent.OnServerEvent:Connect(onClaimMission)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return self
