--!strict
--[[
	Shared/init.luau

	Aggregates every shared module behind a single require(ReplicatedStorage.Shared) call so
	server and client code depend on one stable entry point instead of deep-requiring paths
	like ReplicatedStorage.Shared.Util.Signal everywhere.

	Usage:
		local Shared = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"))
		local log = Shared.Logger.new("MyService")
]]

local Shared = {}

Shared.Constants = require(script.Constants.GameConstants)
Shared.MonetizationIds = require(script.Constants.MonetizationIds)
Shared.Remotes = require(script.Remotes.Remotes)
Shared.Signal = require(script.Util.Signal)
Shared.Logger = require(script.Util.Logger)
Shared.Progression = require(script.Util.Progression)
Shared.RateLimiter = require(script.Util.RateLimiter)
Shared.ServerMode = require(script.Util.ServerMode)
Shared.Async = require(script.Util.Async)
Shared.Types = require(script.Types.Types)
Shared.CosmeticCatalog = require(script.Data.CosmeticCatalog)
Shared.DailyMissionCatalog = require(script.Data.DailyMissionCatalog)

return Shared
