--!strict
--[[
	RevivalService.luau

	Orchestrates bringing an eliminated player back into the current round — the design doc's
	"Revive returns player to their seat, food progress stays unchanged." Also owns the
	escalating revive pricing: a player's FIRST revive each round is free (a direct server
	action — there's no such thing as a free Robux purchase, so this never touches
	MarketplaceService at all); every revive after that costs Robux, and the price climbs each
	time (see Shared/Constants/MonetizationIds.luau for why and the actual suggested prices).
	Roblox has no per-purchase dynamic pricing on a single Developer Product, so each paid tier
	is genuinely a separate product — this file only tracks which tier a player is on, never a
	Robux amount.

	Two entry points, matching the two ways a revive can happen:
	  AttemptFreeRevive  -- called directly off the RequestFreeRevive remote; server re-checks
	                        eligibility itself rather than trusting the client's "it's my first
	                        time" claim.
	  GrantPaidRevive    -- called by MonetizationService after ANY paid tier's receipt is
	                        verified. The Robux is already spent by the time this runs (Roblox
	                        purchases can't be un-charged), so it always grants the revive if
	                        the player is otherwise eligible — it doesn't re-validate which
	                        specific tier they bought against their current count. Pricing is
	                        enforced by which product HudController shows/prompts, not by
	                        rejecting purchases after the fact.

	Deliberately three separate calls inside the actual revive sequence, not one big
	cross-cutting function inside RoundService:
	  RoundService:RevivePlayer()   -- game-state authority: are they even allowed back?
	  SeatingService:ReviveSeat()   -- physically re-sits them at their EXISTING seat, without
	                                   going through the normal seatPlayer() path (see its own
	                                   comment) so EatingService never resets their food/noise
	  GuardService:ClearRagdoll()   -- stands them back up
	Each service still only knows about its own concern; this is just the sequencing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("RevivalService")

local RoundService = require(script.Parent.RoundService)
local SeatingService = require(script.Parent.SeatingService)
local GuardService = require(script.Parent.GuardService)

local RequestFreeReviveEvent = Shared.Remotes.GetEvent("RequestFreeRevive")
local ReviveTierChangedEvent = Shared.Remotes.GetEvent("ReviveTierChanged")

export type ReviveTier = "Free" | "Second" | "Third" | "FourthPlus"

local RevivalService = {}
RevivalService.__index = RevivalService
-- Match-only — see Shared/Util/ServerMode.luau. Revives only mean anything inside a round.
RevivalService.Modes = { "Match" }

local self = setmetatable({
	-- A player's completed revive count THIS round. Reset whenever RoundService starts a
	-- fresh round (see onRoundStarted) — matches how RoundService's own _roster/_alive and
	-- DailyService's _survivingThisRound all reset at the same boundary.
	_revivesThisRound = {} :: { [Player]: number },
}, RevivalService)

type Self = typeof(self)

local function tierForCount(revivesSoFar: number): ReviveTier
	if revivesSoFar <= 0 then
		return "Free"
	elseif revivesSoFar == 1 then
		return "Second"
	elseif revivesSoFar == 2 then
		return "Third"
	else
		return "FourthPlus"
	end
end

local function performRevive(player: Player): boolean
	local revived = RoundService:RevivePlayer(player)
	if not revived then
		return false
	end

	SeatingService:ReviveSeat(player)
	GuardService:ClearRagdoll(player)

	Logger:Info(("%s was revived and returned to their seat."):format(player.Name))
	return true
end

-- What tier a player's NEXT revive would be, without spending anything.
function RevivalService.GetReviveTier(self: Self, player: Player): ReviveTier
	return tierForCount(self._revivesThisRound[player] or 0)
end

function RevivalService.AttemptFreeRevive(self: Self, player: Player): boolean
	if (self._revivesThisRound[player] or 0) > 0 then
		Logger:Debug(("%s tried to use their free revive again this round — denied."):format(player.Name))
		return false
	end

	local revived = performRevive(player)
	if revived then
		self._revivesThisRound[player] = 1
	end
	return revived
end

function RevivalService.GrantPaidRevive(self: Self, player: Player): boolean
	local revived = performRevive(player)
	if revived then
		self._revivesThisRound[player] = (self._revivesThisRound[player] or 0) + 1
	end
	return revived
end

local function onRequestFreeRevive(player: Player)
	self:AttemptFreeRevive(player)
end

local function onPlayerEliminated(player: Player, _aliveCount: number)
	-- Tell just this player what their NEXT revive would cost, before they've spent anything —
	-- the revive button only appears for the eliminated player themselves (see HudController),
	-- so nobody else needs this.
	ReviveTierChangedEvent:FireClient(player, self:GetReviveTier(player))
end

local function onRoundStarted(_participants: { Player })
	table.clear(self._revivesThisRound)
end

function RevivalService.Start(self: Self)
	RequestFreeReviveEvent.OnServerEvent:Connect(onRequestFreeRevive)
	RoundService.PlayerEliminated:Connect(onPlayerEliminated)
	RoundService.RoundStarted:Connect(onRoundStarted)
	Logger:Debug("Started.")
end

return self
