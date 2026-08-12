--!strict
--[[
	MonetizationIds.luau

	PLACEHOLDER IDS. Every value below is 0 until you create the matching Developer Product /
	Game Pass for this experience in the Roblox Creator Dashboard and paste in the real numeric
	ID. Nothing else in the codebase needs to change once you do — MonetizationService and
	CosmeticCatalog both read these keys at runtime, not literal numbers.

	IMPORTANT: Robux prices are NOT a code-level concept — there is no field anywhere in this
	codebase that sets a product's price. You set the price directly in the Creator Dashboard
	when you create each product/pass; the ID that comes back is the only thing that goes here.
	Suggested prices below are just that — reasoning to actually type into the dashboard, not
	something this file enforces or could enforce.

	How to create a Developer Product:
	  Creator Dashboard -> your experience -> Monetization -> Developer Products -> Create Product
	  (set the Robux price there — see suggestions next to each key below)
	How to create a Game Pass:
	  Creator Dashboard -> your experience -> Monetization -> Passes -> Create a Pass
	  (GamePasses below are intentionally still 0 — deferred for now, no action needed yet)

	Until real IDs are filled in, MarketplaceService calls using a 0 ID will simply fail (Roblox
	returns an error/no-op) — MonetizationService logs a warning rather than erroring when that
	happens, so testing every OTHER system in this codebase is unaffected.
]]

local MonetizationIds = {}

-- Suggested Robux prices (set these when you create each product in the Dashboard):
--   Revive pricing escalates per round, on purpose: the FIRST time you're caught, reviving is
--   completely free (RevivalService grants it directly — no product involved, nothing to
--   create for that one). Every revive after that costs Robux, and it gets pricier each time,
--   because reviving over and over would otherwise trivialize "last player standing" — a
--   cheap flat price forever would let one player buy infinite lives; an escalating price
--   keeps it a real impulse buy (heat-of-the-moment, you just died) without letting Robux
--   fully remove the risk of getting caught. Roblox Developer Products can't have a dynamic
--   price, so each tier below is its OWN product with its own fixed Dashboard price:
--     ReviveSecond     — 49 Robux (2nd revive this round)
--     ReviveThird       — 60 Robux (3rd revive this round)
--     ReviveFourthPlus — 99 Robux (4th and every revive after, this round — the price plateaus
--                         here rather than climbing forever)
--   DoubleXP / DoubleGold — 99 Robux each, deliberately priced the same. Both are 24h boosts
--     (Constants.Monetization.BoostDurationSeconds) with genuinely different appeal (long-term
--     progression vs. immediate shop spending power) — pricing them identically avoids
--     signaling one is "better value" than the other and just lets players pick by preference.
MonetizationIds.DeveloperProducts = {
	ReviveSecond = 0, -- suggested: 49 Robux
	ReviveThird = 0, -- suggested: 60 Robux
	ReviveFourthPlus = 0, -- suggested: 99 Robux
	DoubleXP = 0, -- suggested: 99 Robux
	DoubleGold = 0, -- suggested: 99 Robux
}

-- Keys here must match a CosmeticItem's GamePassId in CosmeticCatalog.luau, plus "VIP" for the
-- perk-only pass (cosmetic Title unlock only — see the design doc's "No pay-to-win").
-- DEFERRED FOR NOW — no need to create these yet; everything works fine with them left at 0
-- (ShopService/HudController already treat a 0 Game Pass ID as "not purchasable," not an
-- error). Come back to these once Developer Products are live and working.
MonetizationIds.GamePasses = {
	MythicFork = 0,
	GoldenPlate = 0,
	AnimatedChair = 0,
	RainbowEatingEffect = 0,
	PremiumEmotes = 0,
	PremiumVictoryAnimation = 0,
	VIP = 0,
}

return MonetizationIds
