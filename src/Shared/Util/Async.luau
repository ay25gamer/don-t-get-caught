--!strict
--[[
	Async.luau

	WithTimeout races a function against a deadline using a BindableEvent — event-driven, not
	a polling loop — so a slow/hanging call (e.g. TeleportService:ReserveServer() in a context
	where it can't actually work: an unpublished place, or Studio without API access enabled)
	makes the CALLER give up and return an error instead of leaving a RemoteFunction, and
	therefore a client UI button, stuck waiting forever with no feedback.

	Note: this does not (cannot) actually cancel the underlying call — Luau/Roblox has no API
	to abort an in-flight DataStore/TeleportService request. If it eventually does complete
	after the timeout already fired, its result is just discarded. That's fine for the
	one-shot, idempotent-ish calls this wraps (reserving a server, a DataStore write) — the
	caller has already told the player "try again" by then.
]]

local Async = {}

function Async.WithTimeout<T...>(timeoutSeconds: number, fn: () -> T...): (boolean, ...any)
	local resultEvent = Instance.new("BindableEvent")
	local finished = false

	task.spawn(function()
		local packed = table.pack(pcall(fn))
		if not finished then
			finished = true
			resultEvent:Fire(packed)
		end
	end)

	task.delay(timeoutSeconds, function()
		if not finished then
			finished = true
			resultEvent:Fire(nil)
		end
	end)

	local packed = resultEvent.Event:Wait()
	resultEvent:Destroy()

	if not packed then
		return false, "TimedOut"
	end

	local ok = packed[1]
	if not ok then
		return false, packed[2]
	end
	return true, table.unpack(packed, 2, packed.n)
end

return Async
