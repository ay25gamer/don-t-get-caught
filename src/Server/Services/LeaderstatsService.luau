--!strict
--[[
	LeaderstatsService.luau

	Populates the native Roblox leaderboard (the built-in top-right player list) via the
	standard `leaderstats` Folder convention — zero custom UI needed, Roblox renders it
	automatically for every player. Satisfies the design doc's Lobby "Leaderboard" bullet.

	Values resync from PlayerDataService every second rather than trying to hook every possible
	writer of Gold/Wins/Level (currently just RewardService, but that's not a contract this
	service should depend on).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PlayerDataService = require(script.Parent.PlayerDataService)

local SYNC_INTERVAL = 1

local LeaderstatsService = {}

local function ensureLeaderstats(player: Player): Folder
	local existing = player:FindFirstChild("leaderstats")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local gold = Instance.new("IntValue")
	gold.Name = "Gold"
	gold.Parent = folder

	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = folder

	local level = Instance.new("IntValue")
	level.Name = "Level"
	level.Parent = folder

	folder.Parent = player
	return folder
end

local function onProfileLoaded(player: Player, _profile: unknown)
	ensureLeaderstats(player)
end

local function syncPlayer(player: Player)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	local folder = ensureLeaderstats(player)
	local gold = folder:FindFirstChild("Gold")
	local wins = folder:FindFirstChild("Wins")
	local level = folder:FindFirstChild("Level")

	if gold and gold:IsA("IntValue") then
		gold.Value = data.Gold
	end
	if wins and wins:IsA("IntValue") then
		wins.Value = data.Wins
	end
	if level and level:IsA("IntValue") then
		level.Value = data.Level
	end
end

local syncAccumulator = 0

local function onHeartbeat(dt: number)
	syncAccumulator += dt
	if syncAccumulator < SYNC_INTERVAL then
		return
	end
	syncAccumulator = 0

	for _, player in ipairs(Players:GetPlayers()) do
		syncPlayer(player)
	end
end

function LeaderstatsService.Start()
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return LeaderstatsService
