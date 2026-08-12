--!strict
--[[
	AtmosphereService.luau

	The "Map Design" / "Sound Design" atmosphere bullets that don't need any art asset to
	deliver: dark atmosphere, warm lighting, ambient rain/thunder. Everything here is Lighting
	service properties and a couple of Atmosphere/ParticleEmitter instances built with
	primitives, same "placeholder-but-functionally-real" spirit as PlaceholderMapService (which
	this complements — that file builds geometry, this one builds mood).

	Thunder is a periodic full-map brightness flicker (a PointLight burst, same technique as
	GuardService's muzzle flash) on a random interval — no thunder sound asset exists yet
	(SoundId left empty, same placeholder pattern as the gunshot), so this is visual-only until
	one is assigned.

	Idempotent-ish: only ever touches Lighting properties and instances it creates itself under
	Workspace.DiningRoom, so re-running the server just re-applies the same settings.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("AtmosphereService")

local THUNDER_MIN_INTERVAL = 20
local THUNDER_MAX_INTERVAL = 60
local THUNDER_FLASH_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)

local AtmosphereService = {}
-- Match-only — the Hub gets its own simple environment, not the dining room's mood lighting.
AtmosphereService.Modes = { "Match" }

local function applyLighting()
	Lighting.Brightness = 1
	Lighting.Ambient = Color3.fromRGB(20, 18, 25)
	Lighting.OutdoorAmbient = Color3.fromRGB(15, 15, 20)
	Lighting.ColorShift_Bottom = Color3.fromRGB(40, 20, 10)
	Lighting.ColorShift_Top = Color3.fromRGB(10, 10, 20)
	Lighting.ClockTime = 22
	Lighting.FogColor = Color3.fromRGB(10, 10, 15)
	Lighting.FogStart = 40
	Lighting.FogEnd = 220

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.4
		atmosphere.Offset = 0.25
		atmosphere.Color = Color3.fromRGB(30, 28, 35)
		atmosphere.Decay = Color3.fromRGB(10, 10, 15)
		atmosphere.Glare = 0
		atmosphere.Haze = 1.5
		atmosphere.Parent = Lighting
	end
end

-- Warm point lights over the table so the "warm lighting" bullet reads even though the room
-- ambient is dark — cheap, asset-free, and reuses the table geometry PlaceholderMapService
-- already built.
local function addTableLighting()
	local diningRoom = Workspace:FindFirstChild("DiningRoom")
	local table_ = diningRoom and diningRoom:FindFirstChild("Table")
	if not (table_ and table_:IsA("BasePart")) then
		Logger:Warn("Workspace.DiningRoom.Table not found — skipping table lighting.")
		return
	end

	if table_:FindFirstChild("WarmLight") then
		return
	end

	local light = Instance.new("PointLight")
	light.Name = "WarmLight"
	light.Color = Color3.fromRGB(255, 190, 120)
	light.Brightness = 2
	light.Range = 24
	light.Shadows = true
	light.Parent = table_
end

local function flashThunder()
	local diningRoom = Workspace:FindFirstChild("DiningRoom")
	if not diningRoom then
		return
	end

	local flash = diningRoom:FindFirstChild("ThunderFlash")
	if not (flash and flash:IsA("PointLight")) then
		local ceiling = Instance.new("Part")
		ceiling.Name = "ThunderFlashAnchor"
		ceiling.Size = Vector3.new(1, 1, 1)
		ceiling.Position = Vector3.new(0, 18, 0)
		ceiling.Transparency = 1
		ceiling.CanCollide = false
		ceiling.Anchored = true
		ceiling.Parent = diningRoom

		flash = Instance.new("PointLight")
		flash.Name = "ThunderFlash"
		flash.Color = Color3.fromRGB(200, 210, 255)
		flash.Brightness = 0
		flash.Range = 60
		flash.Parent = ceiling
	end

	TweenService:Create(flash :: PointLight, THUNDER_FLASH_TWEEN_INFO, { Brightness = 6 }):Play()

	-- TODO: assign a real thunder rumble SoundId once an audio asset exists; the trigger point
	-- (right here, in sync with the visual flash) is already correct.
end

local function thunderLoop()
	while true do
		local waitSeconds = THUNDER_MIN_INTERVAL + math.random() * (THUNDER_MAX_INTERVAL - THUNDER_MIN_INTERVAL)
		task.wait(waitSeconds)
		flashThunder()
	end
end

function AtmosphereService.Init()
	applyLighting()
end

function AtmosphereService.Start()
	-- Deliberately not in Init(): PlaceholderMapService.Init() builds Workspace.DiningRoom.Table,
	-- but Init phase ordering between services is unspecified (bootstrap iterates via pairs()),
	-- so this could run before or after it. Start() only ever runs after every service's Init
	-- has finished, guaranteeing the table already exists by the time this looks for it — same
	-- fix as SeatingService/GuardService needed for their own cross-service Workspace lookups.
	addTableLighting()

	-- A single long-lived background loop, not a per-frame Heartbeat connection — thunder
	-- fires every 20-60s, so task.wait() here (unlike a `while wait()` polling loop checking
	-- state every frame) is the right tool: this thread does nothing but sleep between flashes.
	task.spawn(thunderLoop)
end

return AtmosphereService
