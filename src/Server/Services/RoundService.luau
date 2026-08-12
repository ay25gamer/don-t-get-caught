--!strict
--[[
	RoundService.luau

	Owns the round lifecycle state machine — the "MAIN GAME LOOP" from the design doc:

	  Lobby -> (host starts it) -> Intermission (countdown) -> InProgress -> Ended -> Lobby
	              ^------------ cancels back to Lobby if players drop below minimum -------|

	Lobby -> Intermission is deliberately NOT automatic (it used to fire the instant the
	minimum player count was reached) — see RoundService:RequestStart(), called only by
	HostService once it's validated the caller is actually this server's current host. Every
	other transition in the diagram above still happens on its own timer/condition.

	This service knows NOTHING about seats, guards, eating, or guns — that separation is the
	point. It only tracks who is "alive" in the current round and exposes
	RoundService:EliminatePlayer() for whichever future system (GuardService) decides a player
	got caught. Every future system reacts to this service's signals (PhaseChanged,
	RoundStarted, PlayerEliminated, RoundEnded) instead of managing round timing itself — that's
	what keeps SeatingService/GuardService/EatingService independent, swappable modules instead
	of one tangled script.

	Driven by RunService.Heartbeat instead of a `while wait()` polling loop, so phase checks
	are frame-accurate and never block anything else connected to Heartbeat.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("RoundService")
local Constants = Shared.Constants

local Types = require(ReplicatedStorage.Shared.Types.Types)
type RoundPhase = Types.RoundPhase

local RoundService = {}
RoundService.__index = RoundService
-- Match-only: this whole service is inert on a Hub server (see Shared/Util/ServerMode.luau
-- and the bootstrap's mode-gating). Set on the class table, not the instance below, but reads
-- the same via `self.Modes` / `service.Modes` through the __index metatable fallback.
RoundService.Modes = { "Match" }

local self = setmetatable({
	_phase = "Lobby" :: RoundPhase,
	_alive = {} :: { [Player]: boolean },
	_aliveCount = 0,
	-- Every participant of the CURRENT round, populated at InProgress and never shrunk (unlike
	-- _alive) until the next Lobby reset — this is what lets RevivePlayer distinguish "was
	-- eliminated from this round" from "was never in it" (e.g. a mid-round joiner).
	_roster = {} :: { [Player]: boolean },
	_intermissionDeadline = nil :: number?,
	_roundStartClock = nil :: number?,
	_endedDeadline = nil :: number?,
	_lastTickSecond = nil :: number?,

	-- (newPhase: RoundPhase, oldPhase: RoundPhase)
	PhaseChanged = Shared.Signal.new(),
	-- (secondsRemaining: number) -- fired at most once per second during Intermission
	IntermissionTick = Shared.Signal.new(),
	-- (participants: {Player}) -- fired once, entering InProgress
	RoundStarted = Shared.Signal.new(),
	-- (player: Player, remainingAliveCount: number) -- fired when EliminatePlayer() is called
	PlayerEliminated = Shared.Signal.new(),
	-- (player: Player) -- fired when RevivePlayer() successfully brings someone back
	PlayerRevived = Shared.Signal.new(),
	-- (winner: Player?) -- winner is nil if every participant left before anyone was declared the winner
	RoundEnded = Shared.Signal.new(),
}, RoundService)

-- Colon-sugar methods (`function RoundService:Foo()`) would type their implicit `self` from
-- the empty `RoundService` class table, not from the actual singleton above — that's enough
-- for reads, but arithmetic on `self` fields (e.g. `self._aliveCount -= 1`) then fails to
-- type-check with "Unknown type used in operation". Every public method below takes an
-- explicit `self: Self` parameter instead so it's fully typed.
type Self = typeof(self)

local function currentPlayerCount(): number
	return #Players:GetPlayers()
end

local function transitionTo(newPhase: RoundPhase)
	local oldPhase = self._phase
	self._phase = newPhase

	if newPhase == "Lobby" then
		self._intermissionDeadline = nil
		self._roundStartClock = nil
		self._endedDeadline = nil
		self._alive = {}
		self._aliveCount = 0
		self._roster = {}
		Logger:Info("Waiting in Lobby for players.")
	elseif newPhase == "Intermission" then
		self._intermissionDeadline = os.clock() + Constants.Round.IntermissionCountdown
		self._lastTickSecond = nil
		Logger:Info(
			("Intermission started — %d player(s) present, %ds countdown."):format(
				currentPlayerCount(),
				Constants.Round.IntermissionCountdown
			)
		)
	elseif newPhase == "InProgress" then
		self._roundStartClock = os.clock()
		self._alive = {}
		self._aliveCount = 0
		self._roster = {}

		local participants = {}
		for _, player in ipairs(Players:GetPlayers()) do
			self._alive[player] = true
			self._roster[player] = true
			self._aliveCount += 1
			table.insert(participants, player)
		end

		Logger:Info(("Round started with %d participant(s)."):format(#participants))
		self.RoundStarted:Fire(participants)
	elseif newPhase == "Ended" then
		self._endedDeadline = os.clock() + Constants.Round.EndedDisplayDuration

		local winner: Player? = nil
		if self._aliveCount == 1 then
			for player in pairs(self._alive) do
				winner = player
				break
			end
		end

		Logger:Info(("Round ended. Winner: %s"):format(if winner then winner.Name else "none"))
		self.RoundEnded:Fire(winner)
	end

	self.PhaseChanged:Fire(newPhase, oldPhase)
end

local function onHeartbeat()
	local phase = self._phase

	if phase == "Intermission" then
		if currentPlayerCount() < Constants.Players.Min then
			Logger:Info("Not enough players — cancelling intermission.")
			transitionTo("Lobby")
			return
		end

		local deadline = self._intermissionDeadline
		if not deadline then
			return
		end

		local secondsRemaining = math.max(0, math.ceil(deadline - os.clock()))
		if secondsRemaining ~= self._lastTickSecond then
			self._lastTickSecond = secondsRemaining
			self.IntermissionTick:Fire(secondsRemaining)
		end

		if os.clock() >= deadline then
			transitionTo("InProgress")
		end
	elseif phase == "InProgress" then
		if self._aliveCount <= 1 then
			transitionTo("Ended")
			return
		end

		local roundStartClock = self._roundStartClock
		if roundStartClock and os.clock() - roundStartClock >= Constants.Round.MaxDuration then
			Logger:Warn("Round hit its max duration — force-ending.")
			transitionTo("Ended")
		end
	elseif phase == "Ended" then
		local deadline = self._endedDeadline
		if deadline and os.clock() >= deadline then
			transitionTo("Lobby")
		end
	end
end

-- A player disconnecting mid-round isn't an "elimination" (no catch happened, nothing to play
-- a shoot/death effect for) — just quietly drop them from the alive roster so the remaining
-- players aren't stuck waiting for someone who is never coming back.
local function onPlayerRemoving(player: Player)
	if self._phase == "InProgress" and self._alive[player] then
		self._alive[player] = nil
		self._aliveCount -= 1
		Logger:Info(("%s left mid-round (%d player(s) remain)."):format(player.Name, self._aliveCount))
	end
end

function RoundService.Start(self: Self)
	RunService.Heartbeat:Connect(onHeartbeat)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Logger:Info("Round state machine started.")
end

-- Server-authoritative "this player got caught" entry point. Only GuardService (once it
-- exists) should call this — it is the sole judge of when a player got caught.
function RoundService.EliminatePlayer(self: Self, player: Player, reason: string?)
	if self._phase ~= "InProgress" then
		return
	end
	if not self._alive[player] then
		return
	end

	self._alive[player] = nil
	self._aliveCount -= 1
	Logger:Info(("%s was caught (%s). %d player(s) remain."):format(player.Name, reason or "unknown", self._aliveCount))
	self.PlayerEliminated:Fire(player, self._aliveCount)
end

-- Server-authoritative "bring this eliminated player back" entry point — only MonetizationService
-- (after a verified Instant Revive purchase) should call this. Requires the player to have been
-- a participant THIS round (see _roster) and not currently alive; returns false otherwise so
-- the caller (which already spent the player's Robux) knows whether to refund/no-op.
function RoundService.RevivePlayer(self: Self, player: Player): boolean
	if self._phase ~= "InProgress" then
		return false
	end
	if not self._roster[player] then
		return false
	end
	if self._alive[player] then
		return false
	end

	self._alive[player] = true
	self._aliveCount += 1
	Logger:Info(("%s was revived. %d player(s) remain."):format(player.Name, self._aliveCount))
	self.PlayerRevived:Fire(player)
	return true
end

-- Called only by HostService, only after it's confirmed the caller is this server's current
-- host — this method itself only re-checks phase/player count, not who's asking, matching how
-- RevivePlayer/EliminatePlayer stay ignorant of WHO is allowed to call them and leave that to
-- their own callers.
function RoundService.RequestStart(self: Self): (boolean, string?)
	if self._phase ~= "Lobby" then
		return false, "A round is already starting or in progress."
	end
	if currentPlayerCount() < Constants.Players.Min then
		return false, ("Need at least %d players to start."):format(Constants.Players.Min)
	end
	transitionTo("Intermission")
	return true, nil
end

function RoundService.GetPhase(self: Self): RoundPhase
	return self._phase
end

function RoundService.IsPlayerAlive(self: Self, player: Player): boolean
	return self._alive[player] == true
end

function RoundService.GetAlivePlayers(self: Self): { Player }
	local alivePlayers = {}
	for player in pairs(self._alive) do
		table.insert(alivePlayers, player)
	end
	return alivePlayers
end

return self
