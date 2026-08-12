--!strict
--[[
	MonetizationService.luau

	Owns all MarketplaceService integration: Developer Product receipts (ProcessReceipt) and
	Game Pass ownership. Every product/pass ID lives in Shared.MonetizationIds as a PLACEHOLDER
	0 until real ones are created in the Creator Dashboard — see that file's header comment for
	exactly how. A 0 ID makes the relevant Marketplace call fail; this service logs a warning
	and moves on rather than erroring, so nothing else in the codebase is blocked by missing IDs
	during development.

	Developer Products (consumable, granted once per purchase):
	  ReviveSecond / ReviveThird / ReviveFourthPlus -> RevivalService:GrantPaidRevive(). Three
	    separate products, not one, because Roblox products have a single fixed Dashboard
	    price — a player's FIRST revive each round is free and never reaches this file at all
	    (see RevivalService:AttemptFreeRevive, wired straight to its own remote).
	  DoubleXP / DoubleGold -> sets a Boosts.*Until timestamp RewardService/DailyService check
	Every granted receipt is recorded in PlayerProfileData.ProcessedReceipts BEFORE returning
	Granted, keyed by PurchaseId, so a retried ProcessReceipt callback (Roblox retries until you
	return Granted) can never double-grant.

	Game Passes (permanent, cosmetic-only — "No gameplay advantages. Never pay-to-win."):
	  Ownership is checked once per session (on profile load) and cached into
	  PlayerProfileData.OwnedGamepasses so ShopService doesn't need an async MarketplaceService
	  call every time a player tries to equip a pass-gated cosmetic. VIP additionally
	  auto-grants its Title cosmetic the moment ownership is confirmed.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("MonetizationService")
local Constants = Shared.Constants
local MonetizationIds = Shared.MonetizationIds

local PlayerDataService = require(script.Parent.PlayerDataService)
local RevivalService = require(script.Parent.RevivalService)

type PlayerProfileData = PlayerDataService.PlayerProfileData

local GAMEPASS_TITLE_COSMETIC = "Title_VIP"

local function applyDoubleXP(data: PlayerProfileData)
	data.Boosts.DoubleXPUntil = os.time() + Constants.Monetization.BoostDurationSeconds
end

local function applyDoubleGold(data: PlayerProfileData)
	data.Boosts.DoubleGoldUntil = os.time() + Constants.Monetization.BoostDurationSeconds
end

local function grantProduct(player: Player, data: PlayerProfileData, productKey: string): boolean
	if productKey == "ReviveSecond" or productKey == "ReviveThird" or productKey == "ReviveFourthPlus" then
		-- All three paid tiers grant the same thing — a revive. The Robux is already spent by
		-- now; see RevivalService:GrantPaidRevive for why this doesn't re-check which tier the
		-- player "should" be on.
		return RevivalService:GrantPaidRevive(player)
	elseif productKey == "DoubleXP" then
		applyDoubleXP(data)
		return true
	elseif productKey == "DoubleGold" then
		applyDoubleGold(data)
		return true
	end
	return false
end

local productKeyByAssetId: { [number]: string } = {}
for key, id in pairs(MonetizationIds.DeveloperProducts) do
	if id ~= 0 then
		productKeyByAssetId[id] = key
	end
end

local function onProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Not in this server (anymore) to receive it — Roblox retries later, elsewhere.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = PlayerDataService:GetData(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)
	if data.ProcessedReceipts[purchaseId] then
		-- Already granted this exact purchase — Roblox still requires confirming it again.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local productKey = productKeyByAssetId[receiptInfo.ProductId]
	if not productKey then
		Logger:Warn(("Received a receipt for unknown ProductId %d — ignoring."):format(receiptInfo.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = grantProduct(player, data, productKey)
	if not granted then
		-- e.g. Instant Revive bought while not actually eliminated. The purchase still
		-- happened, so it's still marked processed rather than retried forever.
		Logger:Warn(("%s bought %s but it couldn't be applied (nothing to grant right now)."):format(player.Name, productKey))
	end

	data.ProcessedReceipts[purchaseId] = true
	Logger:Info(("%s purchased %s."):format(player.Name, productKey))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function syncGamepasses(player: Player, data: PlayerProfileData)
	for key, id in pairs(MonetizationIds.GamePasses) do
		if id == 0 then
			continue
		end

		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
		end)

		if not ok then
			Logger:Warn(("Failed to check Game Pass '%s' ownership for %s."):format(key, player.Name))
			continue
		end

		if owns and not table.find(data.OwnedGamepasses, id) then
			table.insert(data.OwnedGamepasses, id)
		end

		if key == "VIP" and owns and not table.find(data.Inventory.OwnedCosmetics, GAMEPASS_TITLE_COSMETIC) then
			table.insert(data.Inventory.OwnedCosmetics, GAMEPASS_TITLE_COSMETIC)
		end
	end
end

local function onProfileLoaded(player: Player, _profile: unknown)
	local data = PlayerDataService:GetData(player)
	if not data then
		return
	end
	syncGamepasses(player, data)
end

local MonetizationService = {}

function MonetizationService.Start()
	MarketplaceService.ProcessReceipt = onProcessReceipt
	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
end

return MonetizationService
