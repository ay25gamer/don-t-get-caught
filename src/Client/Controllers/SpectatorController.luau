--!strict
--[[
	SpectatorController.luau

	Enters spectator mode for the LOCAL player when SpectatorService's "PlayerCaught" broadcast
	names them, and exits on "SpectateReset" (round back to Lobby) or "PlayerRevived" naming
	them specifically (an Instant Revive purchase completing mid-round — see RevivalService).
	While spectating, the
	camera is locked to Enum.CameraType.Scriptable (this is what "Free spectate disabled" means
	in practice — the default Roblox camera script stops driving the camera entirely, so
	there's nothing to switch to free-look) and follows one alive player at a time; Q/E cycle
	between them. This is a placeholder control scheme — a real HUD (later step) will replace
	it with on-screen prev/next buttons, but the underlying camera logic won't need to change.

	Never decides who's alive on its own — it only ever reacts to what the server broadcasts
	(RoundParticipants / PlayerCaught), matching every other controller in this codebase. The
	roster (_aliveRoster) is therefore already fully server-vetted: a player only ever leaves it
	via PlayerCaught or PlayerRemoving (disconnect), both server-driven, so the current spectate
	TARGET only ever needs to be re-derived FROM this roster, never independently validated
	against Players:GetPlayers() — a caught-but-still-connected player and a disconnected player
	are both already gone from _aliveRoster by the time either matters.

	Also owns a small camera-shake effect on every PlayerCaught broadcast (a shared dramatic
	beat everyone should feel, not just the caught player) — via Humanoid.CameraOffset, the
	standard Roblox technique for nudging the camera without fighting the default camera
	script's own control of CameraType.Custom. No VFX asset needed, same "placeholder-quality
	but functionally real" spirit as the rest of this codebase's effects.

	SpectateStateChanged(isSpectating, target) is the one thing this controller exposes beyond
	StartSpectating/CycleTarget — HudController subscribes to it to show "CAUGHT"/"SPECTATING:
	<name>" without owning any spectator state of its own; this remains the sole source of truth.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local RoundParticipantsEvent = Shared.Remotes.GetEvent("RoundParticipants")
local PlayerCaughtEvent = Shared.Remotes.GetEvent("PlayerCaught")
local SpectateResetEvent = Shared.Remotes.GetEvent("SpectateReset")
local PlayerRevivedEvent = Shared.Remotes.GetEvent("PlayerRevived")

local CAMERA_DISTANCE = 8
local CAMERA_HEIGHT = 4
local SHAKE_DURATION = 0.3
local SHAKE_MAGNITUDE = 0.3

local LocalPlayer = Players.LocalPlayer

local SpectatorController = {}
SpectatorController.__index = SpectatorController
-- Match-only — see RoundService.luau (server-side) for how this field is read via metatable fallback.
SpectatorController.Modes = { "Match" }

local self = setmetatable({
	_aliveRoster = {} :: { Player },
	-- The actual Player being spectated, or nil if there's currently no one valid to watch.
	-- Tracked by reference rather than an index into _aliveRoster on purpose — an index survives
	-- table.remove() shifting elements around it incorrectly (it used to silently point past the
	-- end of the array whenever the LAST entry was removed, freezing the camera forever); a
	-- reference just gets re-validated against the roster instead — see refreshTarget below.
	_currentTarget = nil :: Player?,
	_isSpectating = false,
	_shakeUntilClock = 0,

	-- (isSpectating: boolean, target: Player?) -- fired whenever either actually changes.
	SpectateStateChanged = Shared.Signal.new(),
}, SpectatorController)

-- Colon-sugar methods would type their implicit `self` from the empty class table, not the
-- singleton above — see RoundService.luau (server-side) for the full explanation.
type Self = typeof(self)

local function removeFromRoster(player: Player)
	local index = table.find(self._aliveRoster, player)
	if index then
		table.remove(self._aliveRoster, index)
	end
end

local function fireStateChanged()
	self.SpectateStateChanged:Fire(self._isSpectating, self._currentTarget)
end

-- The ONLY place _currentTarget is ever assigned. Keeps whatever it already is if that's still
-- in _aliveRoster (so cycling isn't reset by unrelated roster churn), otherwise falls back to
-- the roster's first entry, otherwise nil. Called after every roster mutation, so the target is
-- always correct within the same frame the roster changed — nothing waits for the next
-- Heartbeat to notice a now-invalid target.
local function refreshTarget()
	local previousTarget = self._currentTarget
	local newTarget: Player? = nil

	if self._currentTarget and table.find(self._aliveRoster, self._currentTarget) then
		newTarget = self._currentTarget
	elseif #self._aliveRoster > 0 then
		newTarget = self._aliveRoster[1]
	end

	self._currentTarget = newTarget
	if newTarget ~= previousTarget then
		fireStateChanged()
	end
end

local function enterSpectatorMode()
	self._isSpectating = true
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	refreshTarget()
	fireStateChanged()
end

local function exitSpectatorMode()
	self._isSpectating = false
	self._aliveRoster = {}
	self._currentTarget = nil
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	fireStateChanged()
end

local function cycleSpectateTarget(direction: number)
	if not self._isSpectating then
		return
	end
	refreshTarget() -- make sure we're cycling from a position that's still actually valid
	local roster = self._aliveRoster
	local count = #roster
	if count == 0 then
		return
	end

	local currentIndex = if self._currentTarget then table.find(roster, self._currentTarget) else nil
	local nextIndex = if currentIndex then ((currentIndex - 1 + direction) % count) + 1 else 1
	local newTarget = roster[nextIndex]
	if newTarget ~= self._currentTarget then
		self._currentTarget = newTarget
		fireStateChanged()
	end
end

local function onRoundParticipants(participants: { Player })
	self._aliveRoster = table.clone(participants)
	refreshTarget()
end

local function onPlayerCaught(caughtPlayer: Player)
	removeFromRoster(caughtPlayer)
	if caughtPlayer == LocalPlayer then
		-- enterSpectatorMode() already calls refreshTarget() — no need to call it twice.
		enterSpectatorMode()
	else
		-- Someone ELSE was caught — if we're currently spectating them (or anyone), make sure
		-- our own target is still valid. Section 6's "spectated player gets caught -> auto-
		-- advance to another alive player" requirement, satisfied by the same single function
		-- that already handles every other roster change.
		refreshTarget()
	end
	-- Everyone feels the gunshot, not just the caught player.
	self._shakeUntilClock = os.clock() + SHAKE_DURATION
end

local function onSpectateReset()
	exitSpectatorMode()
end

local function onPlayerRevived(revivedPlayer: Player)
	if not table.find(self._aliveRoster, revivedPlayer) then
		table.insert(self._aliveRoster, revivedPlayer)
	end

	-- exitSpectatorMode() clears _aliveRoster, but only ever runs here for the revived
	-- player's OWN client (they no longer need it — they're playing again, not spectating),
	-- so it doesn't clobber the addition above for anyone else's client.
	if revivedPlayer == LocalPlayer then
		exitSpectatorMode()
	else
		refreshTarget()
	end
end

local function onPlayerRemoving(player: Player)
	removeFromRoster(player)
	refreshTarget()
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or not self._isSpectating then
		return
	end
	if input.KeyCode == Enum.KeyCode.E then
		cycleSpectateTarget(1)
	elseif input.KeyCode == Enum.KeyCode.Q then
		cycleSpectateTarget(-1)
	end
end

local function updateShake()
	local shakeUntil = self._shakeUntilClock
	if shakeUntil <= 0 then
		return
	end

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	if os.clock() >= shakeUntil then
		humanoid.CameraOffset = Vector3.zero
		self._shakeUntilClock = 0
		return
	end

	humanoid.CameraOffset = Vector3.new((math.random() - 0.5) * 2 * SHAKE_MAGNITUDE, (math.random() - 0.5) * 2 * SHAKE_MAGNITUDE, 0)
end

local function onHeartbeat()
	updateShake()

	if not self._isSpectating then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local target = self._currentTarget
	if not target then
		return
	end

	local character = target.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (humanoidRootPart and humanoidRootPart:IsA("BasePart")) then
		return
	end

	local targetCFrame = humanoidRootPart.CFrame
	local cameraPosition = targetCFrame.Position - targetCFrame.LookVector * CAMERA_DISTANCE + Vector3.new(0, CAMERA_HEIGHT, 0)
	camera.CFrame = CFrame.lookAt(cameraPosition, targetCFrame.Position + Vector3.new(0, 1.5, 0))
end

function SpectatorController.Start(self: Self)
	RoundParticipantsEvent.OnClientEvent:Connect(onRoundParticipants)
	PlayerCaughtEvent.OnClientEvent:Connect(onPlayerCaught)
	SpectateResetEvent.OnClientEvent:Connect(onSpectateReset)
	PlayerRevivedEvent.OnClientEvent:Connect(onPlayerRevived)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	UserInputService.InputBegan:Connect(onInputBegan)
	RunService.Heartbeat:Connect(onHeartbeat)
end

-- Lets HudController's "Spectate" button voluntarily enter spectator mode (e.g. a player who
-- joined mid-round and isn't a participant) — the automatic entry on being caught calls the
-- same underlying enterSpectatorMode(), this is just the manual front door for it.
function SpectatorController.StartSpectating(self: Self)
	if self._isSpectating then
		return
	end
	enterSpectatorMode()
end

-- Public front door for HudController's prev/next buttons — direction is +1 (next) or -1
-- (prev). Same underlying logic as the Q/E keybind (onInputBegan), just reachable from a
-- button tap too, so PC and mobile share one real control path instead of two.
function SpectatorController.CycleTarget(self: Self, direction: number)
	cycleSpectateTarget(direction)
end

return self
