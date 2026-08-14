--!strict
--[[
	EatingService.luau

	Server-authoritative eating + noise. Handles "RequestBite" (fired by EatingController
	while the player holds the eat button) and decides whether it counts as a real bite,
	updates that player's food %, and drives every visual (food shrinking, fork moving)
	directly on the replicated seat parts — no remote needed for that, ordinary Workspace
	instance replication does it for free.

	Noise: every accepted bite adds an amount to the player's OWN noise meter (visible to them
	individually — see design doc's "Noise System") that depends on their requested eating mode
	(see below). A bite request that arrives before its mode's required interval has elapsed
	still makes noise (the fork clanks against the plate) but doesn't count toward food progress
	— spam-clicking doesn't make you eat faster, it just makes you louder. Noise decays passively
	over time. This is per-player only; aggregating everyone's noise into the guard's suspicion
	meter is GuardService's job, not this one's.

	Reacts to SeatingService.PlayerSeated (not RoundService.RoundStarted) to reset a player's
	food/noise state — RoundStarted fires to every listening service in an unspecified order,
	so waiting for "this player is actually seated" is the only ordering-safe hook.

	Eating Speed (Safe/Fast): RequestBite now carries a requested EatingMode ("Safe" or "Fast",
	see Shared/Types/Types.luau) — the ONLY thing the client ever supplies about speed. This
	module alone maps that mode to the real numbers (BITE_INTERVAL_BY_MODE / NOISE_PER_BITE_BY_MODE
	below) and re-validates the claimed mode itself (an unrecognized value is just dropped).
	Switching which mode is claimed on successive calls can't be used to bite faster than Fast's
	own interval allows: every attempt is gated against the SAME shared _lastBiteClock using
	ITS OWN claimed mode's required interval, so the fastest any sequence of claims can ever
	achieve is Fast's own rate — there is no combination of Safe/Fast claims that beats always
	claiming Fast outright.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("EatingService")
local Constants = Shared.Constants

local Types = require(ReplicatedStorage.Shared.Types.Types)
type EatingMode = Types.EatingMode

local RoundService = require(script.Parent.RoundService)
local SeatingService = require(script.Parent.SeatingService)

local RequestBiteEvent = Shared.Remotes.GetEvent("RequestBite")

-- The required interval since the last COUNTED bite, and the noise a counted bite costs, per
-- requested mode. Fast's noise reuses Noise.SpamNoiseMultiplier rather than a new invented
-- number — see GameConstants.luau's Eating.FastBiteInterval doc comment for why.
local BITE_INTERVAL_BY_MODE: { [EatingMode]: number } = {
	Safe = Constants.Eating.BiteInterval,
	Fast = Constants.Eating.FastBiteInterval,
}
local NOISE_PER_BITE_BY_MODE: { [EatingMode]: number } = {
	Safe = Constants.Noise.BaseBiteNoise,
	Fast = Constants.Noise.BaseBiteNoise * Constants.Noise.SpamNoiseMultiplier,
}

-- BITE_INTERVAL_BY_MODE already rate-limits how often a click COUNTS toward food progress, but
-- that check only lives inside onRequestBite's own logic — it does nothing to stop the REMOTE
-- itself from being invoked far faster than any real click/tap could (a modified client calling
-- RequestBiteEvent:FireServer() directly, bypassing EatingController's own Heartbeat pacing).
-- Every invocation, even ones rejected as "too soon," still does real work: a table write plus
-- a NoiseChanged Signal:Fire() that fans out to GuardService (suspicion math) and
-- HudReplicationService (a FireClient network send) — so an unthrottled flood is both a real
-- CPU/bandwidth cost and a way to grief the whole round by spiking the guard's (global, shared)
-- suspicion meter on demand. 0.1s is far below even Fast's interval, so no legitimate input
-- pattern (mouse, touch, or otherwise) in either mode can ever hit it — this only ever rejects
-- calls no real client input could produce.
local requestBiteLimiter = Shared.RateLimiter.new(0.1)

local FOOD_TWEEN_INFO = TweenInfo.new(Constants.Eating.BiteInterval * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FORK_TWEEN_INFO =
	TweenInfo.new(Constants.Eating.BiteInterval / 2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, true)
local MIN_FOOD_SCALE = 0.05

local EatingService = {}
EatingService.__index = EatingService
-- Match-only — see RoundService.luau for how this field is read via metatable fallback.
EatingService.Modes = { "Match" }

local self = setmetatable({
	_foodPercent = {} :: { [Player]: number },
	_biteCount = {} :: { [Player]: number },
	_lastBiteClock = {} :: { [Player]: number },
	_noise = {} :: { [Player]: number },
	-- os.clock() timestamp until which the player counts as "visibly eating" (fork at mouth).
	-- Only set by successful bites, not spam-rejected ones — see :IsPlayerEating().
	_eatingUntilClock = {} :: { [Player]: number },

	-- Static per-seat geometry caches, keyed by seat Model. Seats are permanent Workspace
	-- instances (unlike the per-player tables above), so these are populated once ever per
	-- seat and never cleared between rounds.
	_originalFoodSize = {} :: { [Model]: Vector3 },
	_originalForkCFrame = {} :: { [Model]: CFrame },

	-- (player: Player, percent: number) -- fired whenever a bite changes food progress
	FoodPercentChanged = Shared.Signal.new(),
	-- (player: Player, noise: number) -- fired whenever a player's own noise meter changes
	NoiseChanged = Shared.Signal.new(),
	-- (player: Player) -- fired once, when a player's food reaches FullPercent
	PlayerFinishedEating = Shared.Signal.new(),
}, EatingService)

-- Colon-sugar methods would type their implicit `self` from the empty class table, not the
-- singleton above — see RoundService.luau for the full explanation.
type Self = typeof(self)

local function setNoise(player: Player, amount: number)
	local updated = math.clamp((self._noise[player] or 0) + amount, 0, Constants.Noise.Max)
	self._noise[player] = updated
	self.NoiseChanged:Fire(player, updated)
end

-- Restores a seat's Food/Fork parts to their original appearance and caches that original
-- appearance the first time this seat is ever seen (its current state IS its original state
-- at that point, since nothing has shrunk/moved it yet).
local function resetSeatVisuals(seatModel: Model)
	local foodPart = seatModel:FindFirstChild("Food")
	if foodPart and foodPart:IsA("BasePart") then
		if not self._originalFoodSize[seatModel] then
			self._originalFoodSize[seatModel] = foodPart.Size
		end
		foodPart.Size = self._originalFoodSize[seatModel]
		foodPart.Transparency = 0
	end

	local forkPart = seatModel:FindFirstChild("Fork")
	if forkPart and forkPart:IsA("BasePart") then
		if not self._originalForkCFrame[seatModel] then
			self._originalForkCFrame[seatModel] = forkPart.CFrame
		end
		forkPart.CFrame = self._originalForkCFrame[seatModel]
	end
end

-- Placeholder-quality visual feedback (see PlaceholderMapService) — shrinks the Food part
-- toward the player's progress and gives the Fork a quick lift-and-return tween. Once real art
-- exists this is the natural place to swap in a proper fork/mouth animation instead.
local function playBiteVisuals(seatModel: Model, percent: number)
	local foodPart = seatModel:FindFirstChild("Food")
	local originalSize = self._originalFoodSize[seatModel]
	if foodPart and foodPart:IsA("BasePart") and originalSize then
		local remainingFraction = math.max(MIN_FOOD_SCALE, 1 - percent / Constants.Eating.FullPercent)
		TweenService:Create(foodPart, FOOD_TWEEN_INFO, { Size = originalSize * remainingFraction }):Play()
		if percent >= Constants.Eating.FullPercent then
			foodPart.Transparency = 1
		end
	end

	local forkPart = seatModel:FindFirstChild("Fork")
	local originalForkCFrame = self._originalForkCFrame[seatModel]
	if forkPart and forkPart:IsA("BasePart") and originalForkCFrame then
		TweenService:Create(forkPart, FORK_TWEEN_INFO, { CFrame = originalForkCFrame * CFrame.new(0, 1.5, -1) }):Play()
	end
end

local function onPlayerSeated(player: Player, seatModel: Model)
	self._foodPercent[player] = 0
	self._biteCount[player] = 0
	self._lastBiteClock[player] = 0
	self._noise[player] = 0

	resetSeatVisuals(seatModel)

	self.FoodPercentChanged:Fire(player, 0)
	self.NoiseChanged:Fire(player, 0)
end

local function onPhaseChanged(newPhase: string)
	if newPhase == "Lobby" then
		self._foodPercent = {}
		self._biteCount = {}
		self._lastBiteClock = {}
		self._noise = {}
		self._eatingUntilClock = {}
	end
end

local function onRequestBite(player: Player, modeValue: unknown)
	if not requestBiteLimiter:TryAcquire(player) then
		return
	end
	if RoundService:GetPhase() ~= "InProgress" then
		return
	end
	if not RoundService:IsPlayerAlive(player) then
		return
	end

	-- The client only ever ASKS for "Safe" or "Fast" — never a numeric interval/noise value.
	-- Anything else is either a bug in a legitimate client (which only ever sends one of these
	-- two) or a modified one; either way, there is nothing safe to fall back to, so just drop it.
	local mode: EatingMode
	if modeValue == "Safe" then
		mode = "Safe"
	elseif modeValue == "Fast" then
		mode = "Fast"
	else
		return
	end

	local seatModel = SeatingService:GetSeatForPlayer(player)
	if not seatModel then
		return
	end

	local currentPercent = self._foodPercent[player] or 0
	if currentPercent >= Constants.Eating.FullPercent then
		return
	end

	local requiredInterval = BITE_INTERVAL_BY_MODE[mode]
	local now = os.clock()
	local elapsedSinceLastBite = now - (self._lastBiteClock[player] or 0)

	if elapsedSinceLastBite < requiredInterval then
		-- Spam click (or a modified client claiming Fast faster than even Fast allows): the
		-- fork clanks against the plate, but it's too soon to count as a bite. Always the
		-- universal spam rate, regardless of claimed mode — see the file doc for why
		-- alternating claims can't be used to beat Fast's own interval.
		setNoise(player, Constants.Noise.BaseBiteNoise * Constants.Noise.SpamNoiseMultiplier)
		return
	end

	self._lastBiteClock[player] = now
	self._eatingUntilClock[player] = now + requiredInterval
	local biteCount = (self._biteCount[player] or 0) + 1
	self._biteCount[player] = biteCount

	local percent = math.min(Constants.Eating.FullPercent, (biteCount / Constants.Eating.BitesToFinish) * Constants.Eating.FullPercent)
	self._foodPercent[player] = percent

	setNoise(player, NOISE_PER_BITE_BY_MODE[mode])
	playBiteVisuals(seatModel, percent)
	self.FoodPercentChanged:Fire(player, percent)

	if percent >= Constants.Eating.FullPercent then
		Logger:Info(("%s finished eating."):format(player.Name))
		self.PlayerFinishedEating:Fire(player)

		-- First to reach FullPercent wins the round outright — see RoundService.luau's file
		-- doc on PlayerCompletedFood. `percent` above was computed entirely server-side from
		-- this player's own tracked _biteCount; nothing about "did I finish" is ever taken from
		-- the client. RoundService re-validates phase/alive itself too (same defense-in-depth
		-- as every other cross-service call in this codebase), so calling this unconditionally
		-- here is safe even in an edge case where the round somehow already ended a frame ago.
		RoundService:PlayerCompletedFood(player)
	end
end

-- Non-linear decay rate for THIS instant, from the player's current meal progress — see
-- GameConstants.luau's Noise.DecayEarlyMultiplier/DecayLateMultiplier doc comment. Only the
-- passive decay below uses this; bite noise amounts (BITE_INTERVAL_BY_MODE/NOISE_PER_BITE_BY_MODE)
-- and the spam-click noise cost are entirely untouched by meal progress.
local function decayRateFor(player: Player): number
	local progress = math.clamp((self._foodPercent[player] or 0) / Constants.Eating.FullPercent, 0, 1)
	local multiplier = Constants.Noise.DecayEarlyMultiplier
		+ (Constants.Noise.DecayLateMultiplier - Constants.Noise.DecayEarlyMultiplier) * progress
	return Constants.Noise.DecayPerSecond * multiplier
end

local function onHeartbeat(dt: number)
	for player, noise in pairs(self._noise) do
		if noise > 0 then
			local updated = math.max(0, noise - decayRateFor(player) * dt)
			if updated ~= noise then
				self._noise[player] = updated
				self.NoiseChanged:Fire(player, updated)
			end
		end
	end
end

local function onPlayerRemoving(player: Player)
	requestBiteLimiter:Clear(player)
	self._foodPercent[player] = nil
	self._biteCount[player] = nil
	self._lastBiteClock[player] = nil
	self._noise[player] = nil
	self._eatingUntilClock[player] = nil
end

function EatingService.Start(self: Self)
	SeatingService.PlayerSeated:Connect(onPlayerSeated)
	RoundService.PhaseChanged:Connect(onPhaseChanged)
	RequestBiteEvent.OnServerEvent:Connect(onRequestBite)
	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function EatingService.GetFoodPercent(self: Self, player: Player): number
	return self._foodPercent[player] or 0
end

function EatingService.GetNoise(self: Self, player: Player): number
	return self._noise[player] or 0
end

function EatingService.HasFinishedEating(self: Self, player: Player): boolean
	return (self._foodPercent[player] or 0) >= Constants.Eating.FullPercent
end

-- True for a short window after each successful (non-spam) bite, matching how long the fork
-- visually stays lifted toward the mouth. This is what GuardService's detection (a future
-- step) will check when it's LOOKING, and what feeds its "many players eating" suspicion —
-- spam clicks deliberately do NOT set this (see onRequestBite), only real bites do.
function EatingService.IsPlayerEating(self: Self, player: Player): boolean
	return (self._eatingUntilClock[player] or 0) > os.clock()
end

return self
