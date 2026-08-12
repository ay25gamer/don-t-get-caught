--!strict
--[[
	CosmeticCatalog.luau

	The single source of truth for every cosmetic item in the game — ShopService (server) and
	HudController's Shop/Inventory panels (client) both read this SAME list, so there's no way
	for what the shop shows to drift from what the server will actually accept as a valid
	purchase. SkinVisualsService (server) also reads it to know what a Fork/Plate/Chair/Food
	skin actually LOOKS like. Add new items here; nothing else needs to change to make them
	purchasable and visible in the world.

	Every item unlocks exactly one of three ways — exactly one of Price / UnlockLevel /
	GamePassId must be set per item:
	  Price (Gold)   -- purchased directly, see ShopService:PurchaseCosmetic
	  UnlockLevel    -- automatically granted once Level reaches this value, checked whenever
	                    RewardService levels a player up
	  GamePassId     -- a "Robux Shop" item; ownership is checked against a real Roblox Game
	                    Pass (key into MonetizationIds.GamePasses), never against Gold or Level

	Rarity is cosmetic-only flavor (color coding in the UI) — it has no gameplay effect,
	matching "No gameplay advantages. Never pay-to-win." from the design doc.

	Color/Material/SpecialEffect describe what a Fork/Plate/Chair/Food skin actually looks like
	once equipped — see SkinVisualsService.luau for how these get applied to the real parts at
	a player's seat. Emote/Title/VictoryAnimation items are tracked (ownable, equippable) but
	have no physical seat part to skin; visually representing those needs real animation
	assets/a nameplate UI, which is future scope, not this pass.
]]

export type CosmeticCategory = "Fork" | "Plate" | "Chair" | "Food" | "Emote" | "Title" | "VictoryAnimation"
export type Rarity = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret"
export type SpecialEffect = "Rainbow" | "Sway"

export type CosmeticItem = {
	Id: string,
	Name: string,
	Category: CosmeticCategory,
	Rarity: Rarity,
	Price: number?,
	UnlockLevel: number?,
	GamePassId: string?,
	Color: Color3?,
	Material: Enum.Material?,
	SpecialEffect: SpecialEffect?,
}

local CosmeticCatalog: { CosmeticItem } = {
	-- Fork — applied to a seat's "Fork" part.
	{
		Id = "Fork_Default",
		Name = "Standard Fork",
		Category = "Fork",
		Rarity = "Common",
		Price = 0,
		Color = Color3.fromRGB(200, 200, 205),
		Material = Enum.Material.SmoothPlastic,
	},
	{
		Id = "Fork_Silver",
		Name = "Silver Fork",
		Category = "Fork",
		Rarity = "Rare",
		Price = 150,
		Color = Color3.fromRGB(225, 225, 235),
		Material = Enum.Material.Metal,
	},
	{
		Id = "Fork_Golden",
		Name = "Golden Fork",
		Category = "Fork",
		Rarity = "Epic",
		UnlockLevel = 5,
		Color = Color3.fromRGB(212, 175, 55),
		Material = Enum.Material.Metal,
	},
	{
		Id = "Fork_Mythic",
		Name = "Mythic Fork",
		Category = "Fork",
		Rarity = "Mythic",
		GamePassId = "MythicFork",
		Color = Color3.fromRGB(255, 60, 140),
		Material = Enum.Material.Neon,
	},

	-- Plate — applied to a seat's "Plate" part.
	{
		Id = "Plate_Default",
		Name = "Standard Plate",
		Category = "Plate",
		Rarity = "Common",
		Price = 0,
		Color = Color3.fromRGB(235, 230, 220),
		Material = Enum.Material.SmoothPlastic,
	},
	{
		Id = "Plate_Porcelain",
		Name = "Porcelain Plate",
		Category = "Plate",
		Rarity = "Rare",
		Price = 150,
		Color = Color3.fromRGB(250, 250, 255),
		Material = Enum.Material.Marble,
	},
	{
		Id = "Plate_Golden",
		Name = "Golden Plate",
		Category = "Plate",
		Rarity = "Legendary",
		GamePassId = "GoldenPlate",
		Color = Color3.fromRGB(212, 175, 55),
		Material = Enum.Material.Metal,
	},

	-- Chair — applied to a seat's "SeatPart".
	{
		Id = "Chair_Default",
		Name = "Standard Chair",
		Category = "Chair",
		Rarity = "Common",
		Price = 0,
		Color = Color3.fromRGB(87, 57, 41),
		Material = Enum.Material.Wood,
	},
	{
		Id = "Chair_Oak",
		Name = "Oak Chair",
		Category = "Chair",
		Rarity = "Rare",
		Price = 200,
		Color = Color3.fromRGB(130, 90, 50),
		Material = Enum.Material.Wood,
	},
	{
		Id = "Chair_Animated",
		Name = "Animated Chair",
		Category = "Chair",
		Rarity = "Legendary",
		GamePassId = "AnimatedChair",
		Color = Color3.fromRGB(80, 180, 255),
		Material = Enum.Material.Neon,
		SpecialEffect = "Sway", -- a slow, continuous rock — see SkinVisualsService
	},

	-- Food — applied to a seat's "Food" part. This is the one EatingService also resizes as
	-- the player eats; SkinVisualsService only ever touches Color/Material/effect, never Size,
	-- so the two systems can't fight each other.
	{
		Id = "Food_Default",
		Name = "Standard Meal",
		Category = "Food",
		Rarity = "Common",
		Price = 0,
		Color = Color3.fromRGB(178, 120, 70),
		Material = Enum.Material.SmoothPlastic,
	},
	{
		Id = "Food_Feast",
		Name = "Feast Platter",
		Category = "Food",
		Rarity = "Epic",
		UnlockLevel = 10,
		Color = Color3.fromRGB(160, 90, 50),
		Material = Enum.Material.Slate,
	},
	{
		Id = "Food_Rainbow",
		Name = "Rainbow Eating Effect",
		Category = "Food",
		Rarity = "Mythic",
		GamePassId = "RainbowEatingEffect",
		Color = Color3.fromRGB(255, 255, 255), -- overridden every frame by the Rainbow effect
		Material = Enum.Material.Neon,
		SpecialEffect = "Rainbow",
	},

	-- Emote/Title/VictoryAnimation — ownable/equippable, no physical seat part (see file doc).
	{ Id = "Emote_Wave", Name = "Wave", Category = "Emote", Rarity = "Common", Price = 50 },
	{ Id = "Emote_Dance", Name = "Victory Dance", Category = "Emote", Rarity = "Rare", Price = 250 },
	{ Id = "Emote_Premium", Name = "Premium Emote Pack", Category = "Emote", Rarity = "Epic", GamePassId = "PremiumEmotes" },

	{ Id = "Title_Newcomer", Name = "Newcomer", Category = "Title", Rarity = "Common", UnlockLevel = 1 },
	{ Id = "Title_Survivor", Name = "Survivor", Category = "Title", Rarity = "Rare", UnlockLevel = 10 },
	{ Id = "Title_Untouchable", Name = "Untouchable", Category = "Title", Rarity = "Legendary", UnlockLevel = 25 },
	{ Id = "Title_VIP", Name = "VIP", Category = "Title", Rarity = "Secret", GamePassId = "VIP" },

	{ Id = "Victory_Default", Name = "Standard Bow", Category = "VictoryAnimation", Rarity = "Common", Price = 0 },
	{ Id = "Victory_Fireworks", Name = "Fireworks", Category = "VictoryAnimation", Rarity = "Epic", UnlockLevel = 15 },
	{
		Id = "Victory_Premium",
		Name = "Premium Victory Animation",
		Category = "VictoryAnimation",
		Rarity = "Legendary",
		GamePassId = "PremiumVictoryAnimation",
	},
}

return CosmeticCatalog
