--!strict
--[[
	SeatingService.luau

	Assigns each round's participants to a physical seat around the dining table and sits them
	there. Deliberately knows nothing about eating, noise, or the guard — it exposes
	:GetSeatForPlayer() so those future systems can find a player's Plate/Food/Fork without
	SeatingService needing to know why they want it.

	Seats are discovered via CollectionService tag (Constants.Tags.DinnerSeat), never a
	hardcoded Workspace path — this service doesn't care whether they came from
	PlaceholderMapService or a hand-built map an artist made later. It only requires each
	tagged seat to be a Model with a "SeatPart" (a real Seat instance) child; Plate/Food/Fork/
	Cup children exist for other systems to read, SeatingService itself never touches them.

	Physical seating uses Roblox's built-in Seat:Sit() (native sit animation, weld, and
	Occupant tracking) rather than manually welding characters — less code, and Roblox already
	solves this problem correctly.

	Seat ASSIGNMENT and movement LOCKING are deliberately two separate moments, not one:
	  - The instant a player's character exists (joining, or respawning) during Lobby/
	    Intermission, they're assigned a free seat and sat down — "you're at the table" is true
	    well before the round actually starts, so the wait feels like sitting together rather
	    than standing around. Movement is NOT restricted yet; the round hasn't started.
	  - Only RoundService.RoundStarted locks movement (see lockAtSeat) on top of whatever seat
	    each participant is already sitting in — no reshuffle, no re-teleport, just freezing
	    them in place. A participant who somehow has no seat yet (joined at the very last
	    instant) gets one assigned as a fallback at this point too.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("SeatingService")
local Constants = Shared.Constants

local RoundService = require(script.Parent.RoundService)

local SEAT_TAG = Constants.Tags.DinnerSeat

local SeatingService = {}
SeatingService.__index = SeatingService
-- Match-only — see RoundService.luau for how this field is read via metatable fallback.
SeatingService.Modes = { "Match" }

local self = setmetatable({
	_seats = {} :: { Model },
	_seatOfPlayer = {} :: { [Player]: Model },
	_playerOfSeat = {} :: { [Model]: Player },
	-- Guards against the default Roblox Seat behavior of standing a player up the moment they
	-- press a movement/jump key — see lockAtSeat below. Keyed so it can be disconnected the
	-- instant a player SHOULD be free to stand (eliminated, or the round ended).
	_lockConnections = {} :: { [Player]: RBXScriptConnection },

	-- (player: Player, seatModel: Model) -- fired right after a player is physically seated.
	-- Other systems (EatingService) should react to THIS instead of RoundService.RoundStarted
	-- directly — RoundStarted fires to every connected service in an unspecified order, so a
	-- listener can't assume seating has already happened just because RoundStarted fired.
	PlayerSeated = Shared.Signal.new(),
}, SeatingService)

-- Colon-sugar methods (`function SeatingService:Foo()`) would type their implicit `self` from
-- the empty `SeatingService` class table, not from the actual singleton above — see
-- RoundService.luau for the full explanation. Every public method takes an explicit
-- `self: Self` parameter instead.
type Self = typeof(self)

local function getSeatPart(seatModel: Model): Seat?
	local part = seatModel:FindFirstChild("SeatPart")
	if part and part:IsA("Seat") then
		return part
	end
	return nil
end

local function registerSeat(instance: Instance)
	if not instance:IsA("Model") then
		Logger:Warn(("Tagged '%s' is not a Model — ignoring."):format(instance:GetFullName()))
		return
	end
	if not getSeatPart(instance) then
		Logger:Warn(("Seat '%s' has no 'SeatPart' Seat child — ignoring."):format(instance:GetFullName()))
		return
	end
	if table.find(self._seats, instance) then
		return
	end
	table.insert(self._seats, instance)
end

local function unregisterSeat(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local index = table.find(self._seats, instance)
	if index then
		table.remove(self._seats, index)
	end
end

local function assignFreeSeat(): Model?
	local freeSeats = {}
	for _, seatModel in ipairs(self._seats) do
		if not self._playerOfSeat[seatModel] then
			table.insert(freeSeats, seatModel)
		end
	end
	if #freeSeats == 0 then
		return nil
	end
	return freeSeats[math.random(#freeSeats)]
end

-- Roblox's plain Seat stands a player up the instant they press a movement or jump key — fine
-- for a normal chair, wrong for this game, where "you can only eat, you can't just walk away
-- from the table" is the whole point. WalkSpeed/Jump are zeroed so there's nowhere to walk TO
-- even if a client tried, and the Seated listener force-sits them right back down if they
-- still manage to pop out, as long as they're still supposed to be locked in (round running,
-- not eliminated, still assigned to this exact seat — revival re-locks separately).
local function unlockMovement(player: Player)
	local connection = self._lockConnections[player]
	if connection then
		connection:Disconnect()
		self._lockConnections[player] = nil
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.JumpHeight = 7.2
	end
end

local function lockAtSeat(player: Player, seatModel: Model, seatPart: Seat, humanoid: Humanoid)
	local existing = self._lockConnections[player]
	if existing then
		existing:Disconnect()
	end

	seatPart:Sit(humanoid)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0

	self._lockConnections[player] = humanoid.Seated:Connect(function(active: boolean)
		if active then
			return
		end
		if self._seatOfPlayer[player] ~= seatModel then
			return -- no longer assigned here (round ended, or this connection is stale)
		end
		if RoundService:GetPhase() ~= "InProgress" or not RoundService:IsPlayerAlive(player) then
			return -- legitimately allowed up: eliminated (ragdoll), or round already over
		end
		local currentCharacter = player.Character
		local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
		if currentHumanoid then
			seatPart:Sit(currentHumanoid)
		end
	end)
end

-- Sits a player down the moment they can be — joining, respawning, or right after a round
-- ends and the table clears for the next one — WITHOUT locking movement (see file doc). Only
-- runs pre-round (Lobby/Intermission); a mid-round joiner just waits, there's no seat to hand
-- them without disturbing an active round.
local function seatPlayerUnlocked(player: Player)
	if RoundService:GetPhase() == "InProgress" then
		return
	end

	-- Explicitly `Model?` — a plain `local x = self._seatOfPlayer[player]` would infer `Model`
	-- (Luau doesn't treat generic table-index reads as optional the way a missing key at
	-- runtime actually is), which then rejects the `assignFreeSeat()` reassignment below.
	local maybeSeatModel: Model? = self._seatOfPlayer[player]
	if not maybeSeatModel then
		maybeSeatModel = assignFreeSeat()
		if not maybeSeatModel then
			Logger:Warn(("No free seat available for %s."):format(player.Name))
			return
		end
		self._seatOfPlayer[player] = maybeSeatModel
		self._playerOfSeat[maybeSeatModel] = player
	end
	-- Definitely non-nil past this point (every path above either returned or assigned it) —
	-- Luau's flow narrowing doesn't carry a reassigned local across the branch merge above, so
	-- this cast makes it explicit rather than fighting the analyzer further.
	local seatModel = maybeSeatModel :: Model

	local seatPart = getSeatPart(seatModel)
	if not seatPart then
		return
	end

	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		Logger:Warn(("%s has no Humanoid — cannot seat."):format(player.Name))
		return
	end

	seatPart:Sit(humanoid)
	self.PlayerSeated:Fire(player, seatModel)
end

local function seatAllPresentPlayers()
	for _, player in ipairs(Players:GetPlayers()) do
		seatPlayerUnlocked(player)
	end
end

-- The round is actually starting: lock every participant into whatever seat they're already
-- sitting in (assigned back when they joined). A participant with no seat yet — joined at the
-- very last instant, right as Intermission ended — gets one assigned here as a fallback.
local function onRoundStarted(participants: { Player })
	local lockedCount = 0
	for _, player in ipairs(participants) do
		local maybeSeatModel: Model? = self._seatOfPlayer[player]
		if not maybeSeatModel then
			maybeSeatModel = assignFreeSeat()
			if maybeSeatModel then
				self._seatOfPlayer[player] = maybeSeatModel
				self._playerOfSeat[maybeSeatModel] = player
			end
		end
		if not maybeSeatModel then
			continue
		end
		local seatModel = maybeSeatModel :: Model

		local seatPart = getSeatPart(seatModel)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if seatPart and humanoid then
			lockAtSeat(player, seatModel, seatPart, humanoid)
			lockedCount += 1
		end
	end

	if lockedCount < #participants then
		Logger:Warn(("Only locked %d/%d participant(s) into a seat — not enough seats?"):format(lockedCount, #participants))
	else
		Logger:Info(("Locked %d participant(s) into their seats for the round."):format(lockedCount))
	end
end

-- Force-stands every seated player so the Lobby is a clean slate for the next round's
-- assignment. `Humanoid.Sit = false` is the standard way to un-seat a humanoid regardless of
-- which Seat instance it's currently in.
local function releaseAllSeats()
	for player in pairs(self._seatOfPlayer) do
		unlockMovement(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Sit = false
		end
	end
	self._seatOfPlayer = {}
	self._playerOfSeat = {}
end

local function onPhaseChanged(newPhase: string)
	if newPhase == "Lobby" then
		releaseAllSeats()
		-- Straight back into (fresh) seats for the next round's wait — "you're at the table" is
		-- true continuously, not just the first time someone joins this server.
		seatAllPresentPlayers()
	end
end

-- Being caught legitimately un-seats a player (GuardService ragdolls them) — give back normal
-- movement control rather than leaving WalkSpeed/Jump zeroed on a player who's no longer
-- sitting. _seatOfPlayer deliberately stays intact (see file doc) so a later revive knows
-- where to lock them back down.
local function onPlayerEliminated(player: Player, _aliveCount: number)
	unlockMovement(player)
end

local function onPlayerRemoving(player: Player)
	unlockMovement(player)
	local seatModel = self._seatOfPlayer[player]
	if seatModel then
		self._playerOfSeat[seatModel] = nil
		self._seatOfPlayer[player] = nil
	end
end

function SeatingService.Init(self: Self)
	for _, instance in ipairs(CollectionService:GetTagged(SEAT_TAG)) do
		registerSeat(instance)
	end

	CollectionService:GetInstanceAddedSignal(SEAT_TAG):Connect(registerSeat)
	CollectionService:GetInstanceRemovedSignal(SEAT_TAG):Connect(unregisterSeat)

	if #self._seats < Constants.Seating.SeatCount then
		Logger:Warn(("Found %d/%d expected seats tagged '%s'."):format(#self._seats, Constants.Seating.SeatCount, SEAT_TAG))
	else
		Logger:Info(("Discovered %d seat(s)."):format(#self._seats))
	end
end

-- Re-applies the correct seating state for `player`'s CURRENT character. seatPlayerUnlocked
-- deliberately no-ops during InProgress (there's no seat to newly ASSIGN mid-round) — but a
-- mid-round respawn (e.g. the player using Roblox's built-in "Reset Character") still hands
-- them a brand-new Humanoid with none of lockAtSeat's WalkSpeed/JumpPower zeroing on it, so
-- without this check they'd end up free to walk around while RoundService still counts them as
-- an alive, seated participant. Re-lock them at their EXISTING seat instead — the same
-- mechanism ReviveSeat uses — but only if they're actually still supposed to be locked in
-- (still alive; an eliminated/spectating player respawning deliberately stays free, matching
-- onPlayerEliminated's own unlockMovement).
local function reseatCharacter(player: Player)
	if RoundService:GetPhase() == "InProgress" and RoundService:IsPlayerAlive(player) then
		local seatModel: Model? = self._seatOfPlayer[player]
		local seatPart = seatModel and getSeatPart(seatModel)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if seatModel and seatPart and humanoid then
			lockAtSeat(player, seatModel, seatPart, humanoid)
		end
		return
	end
	seatPlayerUnlocked(player)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function()
		reseatCharacter(player)
	end)
	if player.Character then
		reseatCharacter(player)
	end
end

function SeatingService.Start(self: Self)
	RoundService.RoundStarted:Connect(onRoundStarted)
	RoundService.PhaseChanged:Connect(onPhaseChanged)
	RoundService.PlayerEliminated:Connect(onPlayerEliminated)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

-- Re-sits a player at their EXISTING seat assignment (elimination never clears
-- _seatOfPlayer — see onRoundStarted/onPlayerRemoving) without firing PlayerSeated. Only
-- MonetizationService's Instant Revive flow should call this: deliberately NOT going through
-- the normal seatPlayer() path is what keeps EatingService from resetting food/noise progress,
-- matching the design doc's "Revive returns player to their seat, food progress stays unchanged."
function SeatingService.ReviveSeat(self: Self, player: Player): boolean
	local seatModel = self._seatOfPlayer[player]
	if not seatModel then
		return false
	end

	local seatPart = getSeatPart(seatModel)
	if not seatPart then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end

	lockAtSeat(player, seatModel, seatPart, humanoid :: Humanoid)
	return true
end

function SeatingService.GetSeatForPlayer(self: Self, player: Player): Model?
	return self._seatOfPlayer[player]
end

function SeatingService.GetPlayerForSeat(self: Self, seatModel: Model): Player?
	return self._playerOfSeat[seatModel]
end

function SeatingService.GetAllSeats(self: Self): { Model }
	return table.clone(self._seats)
end

return self
