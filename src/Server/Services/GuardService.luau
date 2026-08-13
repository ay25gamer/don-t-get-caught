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

	Reaction window: detection doesn't start checking the INSTANT Looking begins — see
	Constants.Guard.LookingReactionWindow. This is a delay on when checkForCaughtPlayers starts
	running each Looking phase, computed and enforced entirely server-side; the client only ever
	learns "Looking" started (via GuardStateChanged, same moment either way) and reacts on its
	own, exactly as before. Deliberately well short of LookingDurationMin so a real detection
	window always follows it — a player is never safe for the WHOLE Looking phase, only briefly
	at its start.

	Second Look: after a NORMAL Looking phase ends, a chance (see secondLookChance, scaled by
	current Suspicion but never 0% or 100%) that the following Reading is short
	(Constants.Guard.SecondLookReadingMax instead of the usual suspicion-scaled range), leading
	into a quick second glance soon after the first. Tracked with two booleans:
	  _pendingSecondLookReading — decided the moment a Looking phase ends: should the Reading
	    we're about to enter be the short setup one?
	  _currentLookIsSecondLook — carried into a Looking phase from whether the Reading it came
	    from was that short setup one.
	The anti-chain rule lives entirely in transitionState's Looking->Reading branch: if the Look
	that just ended WAS a second look, no roll happens at all — the next Reading is unconditionally
	full-length. A third consecutive quick look is therefore not just rare, it is structurally
	impossible: a second look can only ever be followed by a full, normal-duration Reading.
	The client never receives a timer, a probability, or advance notice of any kind — only the
	same GuardStateChanged("Looking") it would get for an ordinary Look, at the same moment.

	Suspicion tier (Calm/Rising/High — Shared.Types.SuspicionTier): the ONLY thing about
	Suspicion ever revealed to clients, and only as one of these three qualitative bands, never
	the real number — see Constants.Suspicion.RisingThreshold/HighThreshold and
	SuspicionTierChanged in Remotes.luau. Recomputed once per Heartbeat alongside the Suspicion
	value itself, but the signal only actually fires when the tier changes, never every tick.
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
type SuspicionTier = Types.SuspicionTier

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
	-- os.clock() timestamp before which checkForCaughtPlayers is skipped even while Looking —
	-- see the file doc's "Reaction window". Only ever meaningful while _state == "Looking";
	-- freshly set at the top of every Reading->Looking flip, so there's no stale-value risk.
	_lookingDetectionStartClock = 0,
	-- See the file doc's "Second Look" section for what these two mean and how together they
	-- make a third consecutive quick look structurally impossible.
	_pendingSecondLookReading = false,
	_currentLookIsSecondLook = false,
	_suspicion = 0,
	_suspicionTier = "Calm" :: SuspicionTier,
	_lastNoise = {} :: { [Player]: number },
	_ragdolledPlayers = {} :: { [Player]: boolean },

	-- (newState: GuardState, oldState: GuardState) -- fired on every Reading<->Looking flip.
	StateChanged = Shared.Signal.new(),
	-- (newTier: SuspicionTier, oldTier: SuspicionTier) -- fired only when the tier itself
	-- changes, never on a fixed interval or every Heartbeat.
	SuspicionTierChanged = Shared.Signal.new(),
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

-- The short Reading that sets up a potential second look — NOT suspicion-scaled (only whether
-- this roll happens at all is), just a much narrower range than a normal Reading. Floor reuses
-- ReadingDurationMin so it's still governed by the same "never instant" guarantee.
local function pickSecondLookReadingDuration(): number
	local guard = Constants.Guard
	return guard.ReadingDurationMin + math.random() * (guard.SecondLookReadingMax - guard.ReadingDurationMin)
end

-- Linear interpolation between BaseChance (at Suspicion 0) and MaxChance (at Suspicion Max) —
-- see GameConstants.luau. Never 0%, never 100%, by construction.
local function secondLookChance(suspicion: number): number
	local guard = Constants.Guard
	return guard.SecondLookBaseChance + (suspicion / Constants.Suspicion.Max) * (guard.SecondLookMaxChance - guard.SecondLookBaseChance)
end

local function suspicionTierFor(suspicion: number): SuspicionTier
	local susp = Constants.Suspicion
	if suspicion >= susp.HighThreshold then
		return "High"
	elseif suspicion >= susp.RisingThreshold then
		return "Rising"
	else
		return "Calm"
	end
end

-- Recomputes the qualitative tier from the current (real, server-only) Suspicion value and
-- fires SuspicionTierChanged ONLY if it actually changed — this is what stops the client-facing
-- signal from firing every Heartbeat even though this function itself is called every Heartbeat.
local function refreshSuspicionTier()
	local newTier = suspicionTierFor(self._suspicion)
	if newTier == self._suspicionTier then
		return
	end
	local oldTier = self._suspicionTier
	self._suspicionTier = newTier
	self.SuspicionTierChanged:Fire(newTier, oldTier)
end

local function startGuardCycle()
	self._suspicion = 0
	self._suspicionTier = "Calm"
	self._pendingSecondLookReading = false
	self._currentLookIsSecondLook = false
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

	local duration: number
	if newState == "Looking" then
		-- Carry forward whether the Reading we're leaving was the short "second look setup" —
		-- that's what makes THIS Looking phase a second look.
		self._currentLookIsSecondLook = self._pendingSecondLookReading
		duration = pickLookingDuration()
		self._lookingDetectionStartClock = os.clock() + Constants.Guard.LookingReactionWindow
	else
		-- newState == "Reading": a Looking phase just ended.
		if self._currentLookIsSecondLook then
			-- The Look that just ended WAS a second look — mandatory cooldown: no roll, full
			-- normal-duration Reading, guaranteed. This is the only thing that needs to be true
			-- for a third consecutive quick look to be structurally impossible.
			self._pendingSecondLookReading = false
			duration = pickReadingDuration(self._suspicion)
		elseif math.random() < secondLookChance(self._suspicion) then
			self._pendingSecondLookReading = true
			duration = pickSecondLookReadingDuration()
		else
			self._pendingSecondLookReading = false
			duration = pickReadingDuration(self._suspicion)
		end
	end

	self._stateDeadline = os.clock() + duration
	setNewspaperPose(newState, true)

	Logger:Info(
		("Guard %s -> %s (%.1fs, suspicion=%.0f%s)"):format(
			oldState,
			newState,
			duration,
			self._suspicion,
			if self._currentLookIsSecondLook and newState == "Looking" then ", second look" else ""
		)
	)
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

	refreshSuspicionTier()
end

local function onHeartbeat(dt: number)
	if RoundService:GetPhase() ~= "InProgress" then
		return
	end

	updateSuspicionFromActivity(dt)

	if self._state == "Looking" and os.clock() >= self._lookingDetectionStartClock then
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
		-- onHeartbeat stops touching Suspicion entirely once the phase leaves InProgress (it
		-- would otherwise sit frozen at whatever it was the instant the round ended, for the
		-- whole Ended hold plus however long this Lobby wait lasts). Reset it explicitly here
		-- rather than only at the next round's startGuardCycle, so a client joining DURING this
		-- Lobby wait — or the border on any client still connected from last round — reads the
		-- honest current answer ("Calm," nothing is happening) instead of a stale carryover.
		self._suspicion = 0
		refreshSuspicionTier()
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

-- Safe to relay to clients — this is already the coarsest form Suspicion comes in (see the file
-- doc's "Suspicion tier" section). Used by HudReplicationService both for the broadcast on
-- change and to catch a newly-loaded/late-joining player up to the CURRENT tier immediately.
function GuardService.GetSuspicionTier(self: Self): SuspicionTier
	return self._suspicionTier
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
