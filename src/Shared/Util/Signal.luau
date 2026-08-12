--!strict
--[[
	Signal.luau

	Minimal custom event object for decoupled communication between modules on the SAME side
	(e.g. GuardService signalling RoundService, or a client controller signalling another
	client controller). This is not for client<->server communication — use Remotes for that.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Class = typeof(setmetatable(
	{} :: {
		_handlers: { (...any) -> () },
	},
	Signal
))

function Signal.new(): Class
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return self
end

function Signal.Connect(self: Class, handler: (...any) -> ()): Connection
	table.insert(self._handlers, handler)
	local handlers = self._handlers

	local connection = {
		Connected = true,
	} :: Connection

	connection.Disconnect = function(conn: Connection)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local index = table.find(handlers, handler)
		if index then
			table.remove(handlers, index)
		end
	end

	return connection
end

function Signal.Fire(self: Class, ...: any)
	-- Snapshot the handler list so a handler connecting/disconnecting mid-fire can't
	-- corrupt this iteration.
	local handlers = table.clone(self._handlers)
	for _, handler in ipairs(handlers) do
		task.spawn(handler, ...)
	end
end

function Signal.DisconnectAll(self: Class)
	table.clear(self._handlers)
end

return Signal
