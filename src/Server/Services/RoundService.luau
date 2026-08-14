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
	-- How many rounds have reached "Ended" on THIS server since it booted — never reset by
	-- players leaving/joining, only by the server itself restarting (see transitionTo's "Ended"
	-- branch, the single place this increments). Server-only: read by GuardService for round-to-
	-- round escalation (replayability); never sent to any client.
	_roundsCompletedThisServer = 0,

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

-- `forcedWinner` lets a caller declare who won BEFORE the usual "exactly one player left
-- alive" check runs — see PlayerCompletedFood below. Nil (the normal case) falls through to
-- the original last-survivor detection unchanged.
local function transitionTo(newPhase: RoundPhase, forcedWinner: Player?)
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
		-- transitionTo is the sole place any phase change happens (every RequestStart/
		-- PlayerCompletedFood/max-duration/last-survivor path above funnels through here), so
		-- this fires exactly once per round reaching Ended — never double-counted, never skipped.
		self._roundsCompletedThisServer += 1

		local winner: Player? = forcedWinner
		if not winner and self._aliveCount == 1 then
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

-- Server-authoritative "this player finished their plate FIRST" entry point — only
-- EatingService should call this, and only after it has independently confirmed the player's
-- food percent reached FullPercent itself (RequestBite carries no payload; the server computes
-- bite count/food % entirely on its own, so there is nothing here for a client to lie about).
-- Ends the round immediately with THIS player as the winner, regardless of how many other
-- players are still alive/eating — "first to finish wins," not just "last one standing wins."
-- Re-validates its own preconditions rather than trusting the caller, same as
-- EliminatePlayer/RevivePlayer above: phase must still be InProgress, and the player must
-- still be alive (covers "still in this round," "not already eliminated," and "not already
-- caught between their last bite and this call" all at once, since _alive is the single source
-- of truth for every one of those).
function RoundService.PlayerCompletedFood(self: Self, player: Player): boolean
	if self._phase ~= "InProgress" then
		return false
	end
	if not self._alive[player] then
		return false
	end

	Logger:Info(("%s finished their plate first — round over!"):format(player.Name))
	transitionTo("Ended", player)
	return true
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

-- Undoes a RevivePlayer() call that turned out not to be safe to complete — e.g. the player
-- physically couldn't be re-seated/locked afterward (RevivalService checks this before calling
-- this). Deliberately NOT EliminatePlayer(): this isn't a new catch, and routing it through
-- EliminatePlayer would double-count it in RewardService/DailyService's statistics (an extra
-- "eliminated" for what was actually a revive that never really completed). Silent on purpose —
-- no signal fired — because the corresponding RevivePlayer() call above already fired
-- PlayerRevived; only RevivalService should call this, and only immediately afterward, before
-- anything else has had a chance to act on the player being alive again.
function RoundService.CancelRevive(self: Self, player: Player)
	if not self._alive[player] then
		return
	end
	self._alive[player] = nil
	self._aliveCount -= 1
	Logger:Warn(("%s's revive could not be completed and was rolled back."):format(player.Name))
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

-- Server-only — see the field's own comment above. Currently read by GuardService for round-to-
-- round escalation; nothing here should ever route this to a client.
function RoundService.GetRoundsCompletedThisServer(self: Self): number
	return self._roundsCompletedThisServer
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
