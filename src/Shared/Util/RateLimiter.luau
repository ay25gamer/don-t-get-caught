--!strict
--[[
	RateLimiter.luau

	Minimal per-player cooldown tracker for remote handlers that don't already have a natural
	cooldown baked into their own logic — EatingService's Constants.Eating.BiteInterval already
	rate-limits RequestBite as a side effect of its bite-timing rules; this is for the rest
	(UpdateSetting, PurchaseCosmetic, EquipCosmetic, ClaimDailyLogin, ClaimMission), none of
	which has a reason a legitimate client would ever call faster than a person can click.

	This is a cost-control measure, not a security boundary by itself — every handler using
	this still validates everything else server-side. The point is purely that a client
	scripting FireServer() in a tight loop (bypassing normal UI click rates entirely) can't
	waste meaningful server CPU on an otherwise-harmless, idempotent-safe action.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Class = typeof(setmetatable(
	{} :: {
		_intervalSeconds: number,
		_lastCallClock: { [Player]: number },
	},
	RateLimiter
))

function RateLimiter.new(intervalSeconds: number): Class
	return setmetatable({
		_intervalSeconds = intervalSeconds,
		_lastCallClock = {},
	}, RateLimiter)
end

-- Returns true if `player` is allowed to act right now (and records that they just did).
function RateLimiter.TryAcquire(self: Class, player: Player): boolean
	local now = os.clock()
	local last = self._lastCallClock[player]
	if last and now - last < self._intervalSeconds then
		return false
	end
	self._lastCallClock[player] = now
	return true
end

function RateLimiter.Clear(self: Class, player: Player)
	self._lastCallClock[player] = nil
end

return RateLimiter
