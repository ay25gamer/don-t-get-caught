--!strict
--[[
	GuardService.luau

	The guard's Reading/Looking state machine, invisible suspicion meter, AND — new this step
	— detection, shooting, and elimination. Owns the placeholder guard figure built by
	PlaceholderMapService (Newspaper/Gun parts) directly, the same way EatingService owns each
	seat's Food/Fork: no remote needed for any of this, ordinary Workspace replication carries
	the newspaper tween, gun aim, muzzle flash, and hit effect to every client for free.

	States (see design doc "Guard AI"):
	  Reading — 0.5 to 10s (Constants.Guard.ReadingDurationMin/Max), shrinks toward the low end
	            as suspicion rises ("higher suspicion increases chance of checking sooner"), but
	            never fully collapses to a fixed number — see Constants.Suspicion.ReadingDurationInfluence.
	  Looking — 1 to 2s, always. Every alive player is checked EVERY HEARTBEAT for the whole
	            duration of this state (not just once at the start) — see "Detection" below.
	Only runs while RoundService is InProgress; idle (and reset) otherwise.

	Suspicion (design doc "Guard Suspicion") accumulates from two independent sources and
	decays passively:
	  - "Many players eating": a small per-second trickle for every alive player currently
	    EatingService:IsPlayerEating() — simultaneous activity is risky even if quiet.
	  - "Loud noises" / "rapid bites": GuardService listens to EatingService.NoiseChanged and
	    adds suspicion proportional to any INCREASE in a player's own noise meter — a spam
	    click's bigger noise spike (Constants.Noise.SpamNoiseMultiplier) naturally produces a
	    bigger suspicion spike here too, without needing separate "rapid bites" bookkeeping.
	Suspicion is intentionally never exposed to clients — it's the guard's private state, not
	a player-facing meter (unlike each player's own, visible Noise Meter).

	Detection (design doc "Player Detection" / "Shooting"): while LOOKING, every alive player
	with EatingService:IsPlayerEating() == true gets caught — aim/flash/sound/hit-effect play
	(all placeholder-quality, see PlaceholderMapService), their Humanoid is force-stood and
	PlatformStand'd (a simple, reliable ragdoll placeholder — a proper multi-limb ragdoll is a
	future polish upgrade), and RoundService:EliminatePlayer() is called. Detection runs
	entirely server-side; nothing about "am I eating" is ever trusted from the client.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("GuardService")
local Constants = Shared.Constants

local Types = require(ReplicatedStorage.Shared.Types.Types)
type GuardState = Types.GuardState

local RoundService = require(script.Parent.RoundService)
local EatingService = require(script.Parent.EatingService)

local NEWSPAPER_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local AIM_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true) -- aims, then returns
local FLASH_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true) -- flashes, then fades
local HIT_EFFECT_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type GuardParts = {
	model: Model,
	newspaper: BasePart,
	newspaperUpCFrame: CFrame,
	newspaperDownCFrame: CFrame,
	gun: BasePart,
	gunRestCFrame: CFrame,
	muzzleFlash: PointLight,
	gunshotSound: Sound,
}

local GuardService = {}
GuardService.__index = GuardService
-- Match-only — see RoundService.luau for how this field is read via metatable fallback.
GuardService.Modes = { "Match" }

local self = setmetatable({
	_state = "Reading" :: GuardState,
	_stateDeadline = 0,
	_suspicion = 0,
	_lastNoise = {} :: { [Player]: number },
	_ragdolledPlayers = {} :: { [Player]: boolean },

	-- (newState: GuardState, oldState: GuardState) -- fired on every Reading<->Looking flip.
	StateChanged = Shared.Signal.new(),
}, GuardService)

-- Colon-sugar methods would type their implicit `self` from the empty class table, not the
-- singleton above — see RoundService.luau for the full explanation.
type Self = typeof(self)

-- Guard parts are only ever looked up well after PlaceholderMapService.Init has built them
-- (the earliest possible use is a round actually reaching InProgress, long after every
-- service's Init/Start has run), so a single lazy cache with a one-time warning is enough —
-- unlike SeatingService's seats, there's no scenario where the guard model appears later.
local guardParts: GuardParts? = nil
local guardPartsLookupFailed = false

local function getGuardParts(): GuardParts?
	if guardParts then
		return guardParts
	end
	if guardPartsLookupFailed then
		return nil
	end

	local diningRoom = Workspace:FindFirstChild("DiningRoom")
	local model = diningRoom and diningRoom:FindFirstChild("Guard")
	if not (model and model:IsA("Model")) then
		Logger:Warn("Workspace.DiningRoom.Guard not found — guard will run without visuals.")
		guardPartsLookupFailed = true
		return nil
	end

	local newspaper = model:FindFirstChild("Newspaper")
	local gun = model:FindFirstChild("Gun")
	if not (newspaper and newspaper:IsA("BasePart") and gun and gun:IsA("BasePart")) then
		Logger:Warn("Guard model is missing its Newspaper/Gun parts — guard will run without visuals.")
		guardPartsLookupFailed = true
		return nil
	end

	local muzzleFlash = gun:FindFirstChild("MuzzleFlash")
	local gunshotSound = gun:FindFirstChild("GunshotSound")
	if not (muzzleFlash and muzzleFlash:IsA("PointLight") and gunshotSound and gunshotSound:IsA("Sound")) then
		Logger:Warn("Guard Gun is missing MuzzleFlash/GunshotSound — guard will run without shoot effects.")
		guardPartsLookupFailed = true
		return nil
	end

	guardParts = {
		model = model,
		newspaper = newspaper,
		newspaperUpCFrame = newspaper.CFrame,
		newspaperDownCFrame = newspaper.CFrame * CFrame.new(0, -1.6, 0.3),
		gun = gun,
		gunRestCFrame = gun.CFrame,
		muzzleFlash = muzzleFlash,
		gunshotSound = gunshotSound,
	}
	return guardParts
end

local function setNewspaperPose(state: GuardState, animate: boolean)
	local parts = getGuardParts()
	if not parts then
		return
	end

	local targetCFrame = if state == "Reading" then parts.newspaperUpCFrame else parts.newspaperDownCFrame
	if animate then
		TweenService:Create(parts.newspaper, NEWSPAPER_TWEEN_INFO, { CFrame = targetCFrame }):Play()
	else
		parts.newspaper.CFrame = targetCFrame
	end
end

local function spawnHitEffect(position: Vector3)
	local effect = Instance.new("Part")
	effect.Name = "HitEffect"
	effect.Shape = Enum.PartType.Ball
	effect.Size = Vector3.new(0.6, 0.6, 0.6)
	effect.Position = position
	effect.Color = Color3.fromRGB(150, 20, 20)
	effect.Material = Enum.Material.Neon
	effect.Anchored = true
	effect.CanCollide = false
	effect.Parent = Workspace

	TweenService:Create(effect, HIT_EFFECT_TWEEN_INFO, { Size = Vector3.new(2, 2, 2), Transparency = 1 }):Play()
	Debris:AddItem(effect, 0.5)
end

-- Placeholder-quality: no gunshot texture/sound asset exists yet (see PlaceholderMapService),
-- so this is aim + light-flash + a plain hit-flash Part. The orchestration/timing is real —
-- swapping in real VFX/SFX later is a matter of pointing GunshotSound.SoundId at a real asset
-- and giving MuzzleFlash a proper particle effect, not restructuring this function.
local function playShootEffects(targetPosition: Vector3)
	local parts = getGuardParts()
	if not parts then
		return
	end

	local aimCFrame = CFrame.lookAt(parts.gunRestCFrame.Position, targetPosition)
	TweenService:Create(parts.gun, AIM_TWEEN_INFO, { CFrame = aimCFrame }):Play()
	TweenService:Create(parts.muzzleFlash, FLASH_TWEEN_INFO, { Brightness = 8 }):Play()

	if parts.gunshotSound.SoundId ~= "" then
		parts.gunshotSound:Play()
	end

	spawnHitEffect(targetPosition)
end

local function catchPlayer(player: Player)
	local character = player.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	local targetPosition = if humanoidRootPart and humanoidRootPart:IsA("BasePart") then humanoidRootPart.Position else nil

	if targetPosition then
		playShootEffects(targetPosition)
	end

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
		humanoid.PlatformStand = true
		self._ragdolledPlayers[player] = true
	end

	Logger:Info(("%s was caught eating!"):format(player.Name))
	RoundService:EliminatePlayer(player, "caught eating")
end

local function checkForCaughtPlayers()
	for _, player in ipairs(RoundService:GetAlivePlayers()) do
		if EatingService:IsPlayerEating(player) then
			catchPlayer(player)
		end
	end
end

local function pickReadingDuration(suspicion: number): number
	local guard = Constants.Guard
	local susp = Constants.Suspicion
	local range = guard.ReadingDurationMax - guard.ReadingDurationMin
	local compressedMax = guard.ReadingDurationMax - range * (suspicion / susp.Max) * susp.ReadingDurationInfluence
	compressedMax = math.max(guard.ReadingDurationMin, compressedMax)
	return guard.ReadingDurationMin + math.random() * (compressedMax - guard.ReadingDurationMin)
end

local function pickLookingDuration(): number
	local guard = Constants.Guard
	return guard.LookingDurationMin + math.random() * (guard.LookingDurationMax - guard.LookingDurationMin)
end

local function startGuardCycle()
	self._suspicion = 0
	self._state = "Reading"
	local duration = pickReadingDuration(0)
	self._stateDeadline = os.clock() + duration
	setNewspaperPose("Reading", false)
	Logger:Info(("Guard cycle started — Reading for %.1fs."):format(duration))
end

local function transitionState()
	local oldState = self._state
	local newState: GuardState = if oldState == "Reading" then "Looking" else "Reading"
	self._state = newState

	local duration = if newState == "Reading" then pickReadingDuration(self._suspicion) else pickLookingDuration()
	self._stateDeadline = os.clock() + duration
	setNewspaperPose(newState, true)

	Logger:Info(("Guard %s -> %s (%.1fs, suspicion=%.0f)"):format(oldState, newState, duration, self._suspicion))
	self.StateChanged:Fire(newState, oldState)
end

local function addSuspicion(amount: number)
	self._suspicion = math.clamp(self._suspicion + amount, 0, Constants.Suspicion.Max)
end

local function onNoiseChanged(player: Player, newNoise: number)
	local previousNoise = self._lastNoise[player] or 0
	self._lastNoise[player] = newNoise

	local delta = newNoise - previousNoise
	if delta > 0 then
		addSuspicion(delta * Constants.Suspicion.PerNoisePoint)
	end
end

local function updateSuspicionFromActivity(dt: number)
	self._suspicion = math.max(0, self._suspicion - Constants.Suspicion.DecayPerSecond * dt)

	local eatingCount = 0
	for _, player in ipairs(RoundService:GetAlivePlayers()) do
		if EatingService:IsPlayerEating(player) then
			eatingCount += 1
		end
	end

	if eatingCount > 0 then
		addSuspicion(eatingCount * Constants.Suspicion.PerEatingPlayerPerSecond * dt)
	end
end

local function onHeartbeat(dt: number)
	if RoundService:GetPhase() ~= "InProgress" then
		return
	end

	updateSuspicionFromActivity(dt)

	if self._state == "Looking" then
		checkForCaughtPlayers()
	end

	if os.clock() >= self._stateDeadline then
		transitionState()
	end
end

local function unragdollPlayer(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function unragdollEveryone()
	for player in pairs(self._ragdolledPlayers) do
		unragdollPlayer(player)
	end
	self._ragdolledPlayers = {}
end

local function onPhaseChanged(newPhase: string)
	if newPhase == "InProgress" then
		startGuardCycle()
	elseif newPhase == "Lobby" then
		self._lastNoise = {}
		unragdollEveryone()
	end
end

local function onPlayerRemoving(player: Player)
	self._lastNoise[player] = nil
	self._ragdolledPlayers[player] = nil
end

function GuardService.Start(self: Self)
	RoundService.PhaseChanged:Connect(onPhaseChanged)
	EatingService.NoiseChanged:Connect(onNoiseChanged)
	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function GuardService.GetState(self: Self): GuardState
	return self._state
end

-- Server-internal only — never relay this to clients (see the file doc comment).
function GuardService.GetSuspicion(self: Self): number
	return self._suspicion
end

-- Un-ragdolls a single player immediately rather than waiting for the next Lobby transition —
-- only MonetizationService's Instant Revive flow should call this, right after
-- RoundService:RevivePlayer() and SeatingService:ReviveSeat() succeed.
function GuardService.ClearRagdoll(self: Self, player: Player)
	if not self._ragdolledPlayers[player] then
		return
	end
	unragdollPlayer(player)
	self._ragdolledPlayers[player] = nil
end

return self
