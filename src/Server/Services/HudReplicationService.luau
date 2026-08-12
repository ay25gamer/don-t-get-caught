--!strict
--[[
	HudReplicationService.luau

	Same job as SpectatorService, different data: turns server-only signals (RoundService,
	EatingService, PlayerDataService) into what the client-side HUD needs to display, and
	validates the one thing the client sends back (a settings change). Nothing here owns any
	game state — it only relays and validates.

	Round state (phase + intermission countdown) broadcasts to everyone. A player's own food %,
	noise, and profile stats (gold/XP/level/wins/settings) are only ever sent to that player
	specifically via FireClient — nobody else's business, and nothing a HUD needs to show for
	other players.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("HudReplicationService")

local RoundService = require(script.Parent.RoundService)
local EatingService = require(script.Parent.EatingService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local RoundStateChangedEvent = Shared.Remotes.GetEvent("RoundStateChanged")
local EatingStateChangedEvent = Shared.Remotes.GetEvent("EatingStateChanged")
local ProfileSnapshotEvent = Shared.Remotes.GetEvent("ProfileSnapshot")
local UpdateSettingEvent = Shared.Remotes.GetEvent("UpdateSetting")

local PROFILE_SYNC_INTERVAL = 1 -- seconds between periodic ProfileSnapshot resyncs

-- UpdateSetting has no natural cooldown of its own (unlike RequestBite's BiteInterval), and a
-- scripted client could otherwise FireServer() it in a tight loop — see RateLimiter.luau.
local settingUpdateLimiter = Shared.RateLimiter.new(0.3)

-- Every client-writable setting and how to validate a value for it before it touches
-- PlayerProfileData — never trust the client, even for something as low-stakes as settings.
local SETTING_VALIDATORS: { [string]: (value: unknown) -> boolean } = {
	MusicVolume = function(value) return typeof(value) == "number" and value >= 0 and value <= 1 end,
	SfxVolume = function(value) return typeof(value) == "number" and value >= 0 and value <= 1 end,
	CameraSensitivity = function(value) return typeof(value) == "number" and value >= 0 and value <= 1 end,
	Graphics = function(value)
		return value == "Auto" or value == "Low" or value == "Medium" or value == "High"
	end,
	ColorblindMode = function(value) return typeof(value) == "boolean" end,
	MotionBlur = function(value) return typeof(value) == "boolean" end,
	Vibration = function(value) return typeof(value) == "boolean" end,
}

local HudReplicationService = {}

local function onPhaseChanged(newPhase: string, _oldPhase: string)
	RoundStateChangedEvent:FireAllClients(newPhase, 0)
end

local function onIntermissionTick(secondsRemaining: number)
	RoundStateChangedEvent:FireAllClients("Intermission", secondsRemaining)
end

local function onFoodPercentChanged(player: Player, percent: number)
	EatingStateChangedEvent:FireClient(player, percent, EatingService:GetNoise(player))
end

local function onNoiseChanged(player: Player, noise: number)
	EatingStateChangedEvent:FireClient(player, EatingService:GetFoodPercent(player), noise)
end

local function sendProfileSnapshot(player: Player)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	ProfileSnapshotEvent:FireClient(player, data.Gold, data.XP, data.Level, data.Wins, data.Settings)
end

local function onProfileLoaded(player: Player, _profile: unknown)
	sendProfileSnapshot(player)
end

local function onUpdateSetting(player: Player, key: unknown, value: unknown)
	if not settingUpdateLimiter:TryAcquire(player) then
		return
	end
	if typeof(key) ~= "string" then
		return
	end

	local validator = SETTING_VALIDATORS[key]
	if not validator or not validator(value) then
		Logger:Warn(("%s sent an invalid setting update for '%s' — ignored."):format(player.Name, tostring(key)))
		return
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	(data.Settings :: any)[key] = value
end

local syncAccumulator = 0

local function onHeartbeat(dt: number)
	syncAccumulator += dt
	if syncAccumulator < PROFILE_SYNC_INTERVAL then
		return
	end
	syncAccumulator = 0

	for _, player in ipairs(Players:GetPlayers()) do
		sendProfileSnapshot(player)
	end
end

local function onPlayerRemoving(player: Player)
	settingUpdateLimiter:Clear(player)
end

function HudReplicationService.Start()
	RoundService.PhaseChanged:Connect(onPhaseChanged)
	RoundService.IntermissionTick:Connect(onIntermissionTick)
	EatingService.FoodPercentChanged:Connect(onFoodPercentChanged)
	EatingService.NoiseChanged:Connect(onNoiseChanged)
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	UpdateSettingEvent.OnServerEvent:Connect(onUpdateSetting)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return HudReplicationService
