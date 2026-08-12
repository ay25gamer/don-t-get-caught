--!strict
--[[
	Logger.luau

	Small tagged logger so console output can be traced back to the system that produced it.

	Usage:
		local log = Logger.new("GuardService")
		log:Info("state changed to Looking")
]]

local RunService = game:GetService("RunService")

local Logger = {}
Logger.__index = Logger

export type Class = typeof(setmetatable(
	{} :: { _tag: string },
	Logger
))

function Logger.new(tag: string): Class
	local self = setmetatable({
		_tag = tag,
	}, Logger)
	return self
end

-- Debug logs are stripped from live servers by only printing in Studio, keeping production
-- output logs readable.
function Logger.Debug(self: Class, message: string)
	if RunService:IsStudio() then
		print(("[%s] %s"):format(self._tag, message))
	end
end

function Logger.Info(self: Class, message: string)
	print(("[%s] %s"):format(self._tag, message))
end

function Logger.Warn(self: Class, message: string)
	warn(("[%s] %s"):format(self._tag, message))
end

function Logger.Error(self: Class, message: string)
	warn(("[%s] ERROR: %s"):format(self._tag, message))
end

return Logger
