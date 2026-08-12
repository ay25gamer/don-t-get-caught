--!strict
--[[
	ShopService.luau

	The Gold side of the shop/inventory system — CosmeticCatalog.luau (Shared, so the client
	UI reads the exact same list) is the single source of truth for what exists; this service
	is the only thing allowed to grant ownership or change what's equipped.

	Three ways an item becomes ownable:
	  Price == 0 or Level >= UnlockLevel  -> auto-granted (syncAutoUnlocks), on profile load and
	                                          on RewardService.LevelUp
	  Price > 0                            -> PurchaseCosmetic, Gold deducted server-side
	  GamePassId set                       -> never granted here; MonetizationService caches
	                                          real ownership into OwnedGamepasses, checked at
	                                          equip time instead (no separate "own" step)

	Equipping only ever succeeds if the item is actually ownable per the rules above — the
	client sends intent (which item, which slot), the server is the only judge of whether it's
	allowed, same pattern as every other remote handler in this codebase.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("ShopService")
local MonetizationIds = Shared.MonetizationIds

-- Required directly (not via the Shared aggregator) so its exported CosmeticItem type can be
-- imported below — Luau's require-based type import only links through a direct require()
-- call, not an indexing expression like Shared.CosmeticCatalog.
local CosmeticCatalog = require(ReplicatedStorage.Shared.Data.CosmeticCatalog)
type CosmeticItem = typeof(CosmeticCatalog[1])

local RewardService = require(script.Parent.RewardService)
local PlayerDataService = require(script.Parent.PlayerDataService)

type PlayerProfileData = PlayerDataService.PlayerProfileData

local PurchaseCosmeticEvent = Shared.Remotes.GetEvent("PurchaseCosmetic")
local EquipCosmeticEvent = Shared.Remotes.GetEvent("EquipCosmetic")
local InventoryUpdatedEvent = Shared.Remotes.GetEvent("InventoryUpdated")

-- Declared here (not at the bottom, where a stateless service like this would normally put its
-- exported table) specifically so the private handler functions below can close over
-- EquipmentChanged as an upvalue — a local only becomes visible to closures defined AFTER it.
local ShopService = {}
-- (player: Player) -- fired whenever applyEquip() succeeds. SkinVisualsService listens to this
-- to re-skin a player's seat live if they change loadout while already seated (the Shop is
-- reachable mid-round via the HUD, not just between rounds).
ShopService.EquipmentChanged = Shared.Signal.new()

-- Neither remote has a natural cooldown of its own — see RateLimiter.luau.
local purchaseLimiter = Shared.RateLimiter.new(0.3)
local equipLimiter = Shared.RateLimiter.new(0.3)

local function findItem(itemId: string): CosmeticItem?
	for _, item in ipairs(CosmeticCatalog) do
		if item.Id == itemId then
			return item
		end
	end
	return nil
end

local function pushInventoryUpdate(player: Player, data: PlayerProfileData)
	InventoryUpdatedEvent:FireClient(player, data.Inventory.OwnedCosmetics, data.Inventory.EquippedCosmetics, data.Gold)
end

local function syncAutoUnlocks(data: PlayerProfileData)
	for _, item in ipairs(CosmeticCatalog) do
		local shouldOwn = item.Price == 0 or (item.UnlockLevel ~= nil and data.Level >= item.UnlockLevel)
		if shouldOwn and not table.find(data.Inventory.OwnedCosmetics, item.Id) then
			table.insert(data.Inventory.OwnedCosmetics, item.Id)
		end
	end
end

local function canEquip(data: PlayerProfileData, item: CosmeticItem): boolean
	if table.find(data.Inventory.OwnedCosmetics, item.Id) then
		return true
	end
	if item.GamePassId then
		local gamePassAssetId = MonetizationIds.GamePasses[item.GamePassId]
		if gamePassAssetId and gamePassAssetId ~= 0 and table.find(data.OwnedGamepasses, gamePassAssetId) then
			return true
		end
	end
	return false
end

local function applyEquip(data: PlayerProfileData, item: CosmeticItem)
	local equipped = data.Inventory.EquippedCosmetics

	if item.Category == "Emote" then
		local index = table.find(equipped.Emotes, item.Id)
		if index then
			table.remove(equipped.Emotes, index)
		else
			table.insert(equipped.Emotes, item.Id)
		end
	elseif item.Category == "Fork" then
		equipped.Fork = item.Id
	elseif item.Category == "Plate" then
		equipped.Plate = item.Id
	elseif item.Category == "Chair" then
		equipped.Chair = item.Id
	elseif item.Category == "Food" then
		equipped.Food = item.Id
	elseif item.Category == "Title" then
		equipped.Title = item.Id
	elseif item.Category == "VictoryAnimation" then
		equipped.VictoryAnimation = item.Id
	end
end

local function onPurchaseCosmetic(player: Player, itemIdValue: unknown)
	if not purchaseLimiter:TryAcquire(player) then
		return
	end
	if typeof(itemIdValue) ~= "string" then
		return
	end

	local item = findItem(itemIdValue)
	if not item or not item.Price or item.Price <= 0 then
		return
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	if table.find(data.Inventory.OwnedCosmetics, item.Id) then
		return
	end
	if data.Gold < item.Price then
		return
	end

	data.Gold -= item.Price
	table.insert(data.Inventory.OwnedCosmetics, item.Id)
	Logger:Info(("%s purchased %s for %d gold."):format(player.Name, item.Name, item.Price))
	pushInventoryUpdate(player, data)
end

local function onEquipCosmetic(player: Player, itemIdValue: unknown)
	if not equipLimiter:TryAcquire(player) then
		return
	end
	if typeof(itemIdValue) ~= "string" then
		return
	end

	local item = findItem(itemIdValue)
	if not item then
		return
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end

	if not canEquip(data, item) then
		return
	end

	applyEquip(data, item)
	Logger:Info(("%s equipped %s."):format(player.Name, item.Name))
	pushInventoryUpdate(player, data)
	ShopService.EquipmentChanged:Fire(player)
end

local function onProfileLoaded(player: Player, _profile: unknown)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	syncAutoUnlocks(data)
	pushInventoryUpdate(player, data)
end

local function onLevelUp(player: Player, _newLevel: number)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	syncAutoUnlocks(data)
	pushInventoryUpdate(player, data)
end

local function onPlayerRemoving(player: Player)
	purchaseLimiter:Clear(player)
	equipLimiter:Clear(player)
end

function ShopService.Start()
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	RewardService.LevelUp:Connect(onLevelUp)
	PurchaseCosmeticEvent.OnServerEvent:Connect(onPurchaseCosmetic)
	EquipCosmeticEvent.OnServerEvent:Connect(onEquipCosmetic)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return ShopService
