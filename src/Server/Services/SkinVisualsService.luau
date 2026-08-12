--!strict
--[[
	SkinVisualsService.luau

	Match-only. The piece that was missing: ShopService already tracks what a player owns and
	has equipped, but nothing read that data and changed what their seat's Fork/Plate/Chair/
	Food parts actually look like. This service is that link — CosmeticCatalog.luau is the
	single source of truth for what each skin's Color/Material/SpecialEffect is; this service
	just applies it to the real parts at a player's seat, the same "server manipulates real
	Workspace instances directly, replication is free" pattern EatingService/GuardService use
	for the fork tween/food shrink/newspaper tween — no remote needed for any of this.

	Two triggers:
	  SeatingService.PlayerSeated  -- apply their current loadout the moment they sit down
	  ShopService.EquipmentChanged -- re-apply live if they change loadout while already seated
	                                   (the Shop is reachable mid-round via the HUD)

	Two continuous effects (Constants-free, just two small Heartbeat-driven loops) for the
	catalog's flashier items: Food_Rainbow cycles hue every frame, Chair_Animated gently sways.
	Both are removed from their effect set the moment a player re-equips something else, so
	switching skins never leaves a stale effect running on an old part.

	Deliberately never touches Size/Transparency on the Food part — EatingService owns those
	(shrinking it as the player eats) — only Color/Material/rotation, so the two systems can't
	fight over the same property.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("SkinVisualsService")

-- Required directly (not via the Shared aggregator) so its exported CosmeticItem type can be
-- imported below — see ShopService.luau for why.
local CosmeticCatalog = require(ReplicatedStorage.Shared.Data.CosmeticCatalog)
type CosmeticItem = typeof(CosmeticCatalog[1])

local SeatingService = require(script.Parent.SeatingService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ShopService = require(script.Parent.ShopService)

type PlayerProfileData = PlayerDataService.PlayerProfileData

local SWAY_AMPLITUDE = math.rad(4)
local SWAY_PERIOD_SECONDS = 3
local RAINBOW_CYCLE_SECONDS = 3

local SkinVisualsService = {}
SkinVisualsService.__index = SkinVisualsService
-- Match-only — see Shared/Util/ServerMode.luau.
SkinVisualsService.Modes = { "Match" }

local self = setmetatable({
	_rainbowFoodParts = {} :: { [BasePart]: boolean },
	_swayBaseCFrames = {} :: { [BasePart]: CFrame },
}, SkinVisualsService)

type Self = typeof(self)

local function findItem(itemId: string): CosmeticItem?
	for _, item in ipairs(CosmeticCatalog) do
		if item.Id == itemId then
			return item
		end
	end
	return nil
end

local function applyStaticLook(part: BasePart, item: CosmeticItem?)
	if not item then
		return
	end
	if item.Color then
		part.Color = item.Color
	end
	if item.Material then
		part.Material = item.Material
	end
end

local function applySeatSkins(seatModel: Model, data: PlayerProfileData)
	local equipped = data.Inventory.EquippedCosmetics

	local forkPart = seatModel:FindFirstChild("Fork")
	if forkPart and forkPart:IsA("BasePart") then
		applyStaticLook(forkPart, findItem(equipped.Fork))
	end

	local platePart = seatModel:FindFirstChild("Plate")
	if platePart and platePart:IsA("BasePart") then
		applyStaticLook(platePart, findItem(equipped.Plate))
	end

	local seatPart = seatModel:FindFirstChild("SeatPart")
	if seatPart and seatPart:IsA("BasePart") then
		local chairItem = findItem(equipped.Chair)
		applyStaticLook(seatPart, chairItem)

		if chairItem and chairItem.SpecialEffect == "Sway" then
			if not self._swayBaseCFrames[seatPart] then
				self._swayBaseCFrames[seatPart] = seatPart.CFrame
			end
		else
			self._swayBaseCFrames[seatPart] = nil
		end
	end

	local foodPart = seatModel:FindFirstChild("Food")
	if foodPart and foodPart:IsA("BasePart") then
		local foodItem = findItem(equipped.Food)
		applyStaticLook(foodPart, foodItem)

		if foodItem and foodItem.SpecialEffect == "Rainbow" then
			self._rainbowFoodParts[foodPart] = true
		else
			self._rainbowFoodParts[foodPart] = nil
		end
	end
end

local function onPlayerSeated(player: Player, seatModel: Model)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	applySeatSkins(seatModel, data)
end

local function onEquipmentChanged(player: Player)
	local seatModel = SeatingService:GetSeatForPlayer(player)
	if not seatModel then
		return -- not currently seated; their new loadout will apply next time they sit
	end
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	applySeatSkins(seatModel, data)
end

local function onHeartbeat(_dt: number)
	local now = os.clock()

	for foodPart in pairs(self._rainbowFoodParts) do
		if foodPart.Parent then
			foodPart.Color = Color3.fromHSV((now / RAINBOW_CYCLE_SECONDS) % 1, 0.85, 1)
		else
			self._rainbowFoodParts[foodPart] = nil
		end
	end

	for seatPart, baseCFrame in pairs(self._swayBaseCFrames) do
		if seatPart.Parent then
			local angle = math.sin(now * (2 * math.pi / SWAY_PERIOD_SECONDS)) * SWAY_AMPLITUDE
			seatPart.CFrame = baseCFrame * CFrame.Angles(0, angle, 0)
		else
			self._swayBaseCFrames[seatPart] = nil
		end
	end
end

function SkinVisualsService.Start(self: Self)
	SeatingService.PlayerSeated:Connect(onPlayerSeated)
	ShopService.EquipmentChanged:Connect(onEquipmentChanged)
	RunService.Heartbeat:Connect(onHeartbeat)
	Logger:Debug("Started.")
end

return self
