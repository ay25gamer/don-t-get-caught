--!strict
--[[
	EatingController.luau

	Detects "holding Left Mouse Button" (and the touch equivalent, for mobile — console/
	gamepad input is a follow-up) and fires RequestBite at a steady cadence while held.

	This is intentionally dumb: it forwards player intent and nothing else. The server
	(EatingService) is the sole judge of whether a bite counts, and drives every visual (food
	shrinking, fork moving) directly on the replicated seat parts — there's nothing to predict
	or fake client-side, so this controller doesn't even know the player's current food %.

	Paced with RunService.Heartbeat (not a `while wait()` loop) so it costs nothing while the
	button isn't held.

	Eating Speed (Safe/Fast): SetFastModeEnabled (called by HudController's toggle button) is
	the ONLY thing this controller decides about speed — which of the two fixed paces to send
	RequestBite at, and which mode name to claim. Every real number behind either mode (the
	actual interval, the actual noise) lives entirely in EatingService; this controller has no
	idea what either number is, same "client is dumb" principle as everything else here.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Constants = Shared.Constants

local RequestBiteEvent = Shared.Remotes.GetEvent("RequestBite")

local EatingController = {}
EatingController.__index = EatingController
-- Match-only — see RoundService.luau (server-side) for how this field is read via metatable
-- fallback, and Shared/Util/ServerMode.luau for what "Match" means.
EatingController.Modes = { "Match" }

local self = setmetatable({
	_holding = false,
	_lastAttemptClock = 0,
	_fastModeEnabled = false,
}, EatingController)

-- Colon-sugar methods would type their implicit `self` from the empty class table, not the
-- singleton above — see RoundService.luau (server-side) for the full explanation.
type Self = typeof(self)

local function isEatInput(inputType: Enum.UserInputType): boolean
	return inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end
	if isEatInput(input.UserInputType) then
		self._holding = true
	end
end

local function onInputEnded(input: InputObject, _gameProcessedEvent: boolean)
	if isEatInput(input.UserInputType) then
		self._holding = false
	end
end

local function onHeartbeat()
	if not self._holding then
		return
	end

	-- Only paces how OFTEN this client bothers to ask — EatingService enforces the real
	-- interval for whichever mode is actually claimed independently, so this is purely "don't
	-- fire the remote needlessly," not a security boundary (see EatingService.luau's file doc).
	local pace = if self._fastModeEnabled then Constants.Eating.FastBiteInterval else Constants.Eating.BiteInterval

	local now = os.clock()
	if now - self._lastAttemptClock < pace then
		return
	end

	self._lastAttemptClock = now
	RequestBiteEvent:FireServer(if self._fastModeEnabled then "Fast" else "Safe")
end

-- Called by HudController's Fast Eating toggle button — the only entry point for changing this.
function EatingController.SetFastModeEnabled(self: Self, enabled: boolean)
	self._fastModeEnabled = enabled
end

function EatingController.Start(self: Self)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return self
