--!strict
--[[
	SpectatorService.luau

	The only bridge from RoundService's server-only signals to the clients that need to react
	to them for spectator mode. RoundService/GuardService don't know clients exist (by design —
	see their file docs); this is the one place that turns "a round started" / "a player was
	eliminated" / "a player was revived" / "we're back in the Lobby" into the broadcasts every
	client needs to track a spectate-able roster and know when to enter/exit spectator mode.

	No state, no per-player logic — SpectatorController (client) owns all of that. This service
	only relays.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local RoundService = require(script.Parent.RoundService)

local RoundParticipantsEvent = Shared.Remotes.GetEvent("RoundParticipants")
local PlayerCaughtEvent = Shared.Remotes.GetEvent("PlayerCaught")
local SpectateResetEvent = Shared.Remotes.GetEvent("SpectateReset")
local PlayerRevivedEvent = Shared.Remotes.GetEvent("PlayerRevived")

local SpectatorService = {}
-- Match-only — see Shared/Util/ServerMode.luau.
SpectatorService.Modes = { "Match" }

local function onRoundStarted(participants: { Player })
	RoundParticipantsEvent:FireAllClients(participants)
end

local function onPlayerEliminated(player: Player, _remainingAliveCount: number)
	PlayerCaughtEvent:FireAllClients(player)
end

local function onPlayerRevived(player: Player)
	PlayerRevivedEvent:FireAllClients(player)
end

local function onPhaseChanged(newPhase: string, _oldPhase: string)
	-- Fires at "Ended" (the round just concluded), not only "Lobby" 8s later — a spectating
	-- client whose _aliveRoster had gone empty (their last watchable target was just
	-- eliminated) would otherwise sit with a frozen camera and Scriptable control for the
	-- entire Ended-hold, with nothing telling it to reset until Lobby finally arrived. Also
	-- still fires on "Lobby" itself (harmless if already reset at Ended) so nothing regresses
	-- for whatever path a round ends through.
	if newPhase == "Ended" or newPhase == "Lobby" then
		SpectateResetEvent:FireAllClients()
	end
end

function SpectatorService.Start()
	RoundService.RoundStarted:Connect(onRoundStarted)
	RoundService.PlayerEliminated:Connect(onPlayerEliminated)
	RoundService.PlayerRevived:Connect(onPlayerRevived)
	RoundService.PhaseChanged:Connect(onPhaseChanged)
end

return SpectatorService
