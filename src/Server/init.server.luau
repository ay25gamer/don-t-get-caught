--!strict
--[[
	Server bootstrap for DON'T GET CAUGHT.

	Two-phase service lifecycle, run once at server start:
	  1. Require every ModuleScript directly under Services/.
	  2. Call each service's optional :Init() — services set up state and may reference
	     other services here, since ALL services are guaranteed to exist by this point.
	  3. Call each service's optional :Start() — services begin doing work (loops, event
	     connections). Runs only after every service has finished Init, so Start-time work
	     never races another service's setup.

	This is the only place service load order is decided implicitly (folder iteration order
	does not matter, because Init is fully separated from Start). New systems plug in by
	dropping a ModuleScript into Services/ — no edits needed here. See Services/README.md
	for the contract.

	Mode-gating: this server is either "Hub" (the menu/matchmaking experience) or "Match" (an
	actual round) — see Shared/Util/ServerMode.luau. Every service still gets REQUIRED either
	way (safe — requiring just defines the module, it doesn't run anything), but a service can
	opt out of a mode by exporting `Service.Modes = {"Match"}` (or `{"Hub"}`); a service with no
	`Modes` field runs in both. Only Init/Start are gated, so a Match-only service sits
	completely inert (never Started) on a Hub server instead of needing its own internal mode
	checks scattered through its logic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("ServerBootstrap")

-- Remote Instances must exist before any service's Init/Start runs, since services may hand
-- out RemoteEvents to the client as soon as they start.
Shared.Remotes.Init()

local currentMode = Shared.ServerMode.Current()
Logger:Info(("Server mode: %s"):format(currentMode))

local Services = script:WaitForChild("Services")
local loadedServices: { [string]: any } = {}
local serviceCount = 0

for _, moduleScript in ipairs(Services:GetChildren()) do
	if moduleScript:IsA("ModuleScript") then
		local ok, serviceOrErr = pcall(require, moduleScript)
		if ok then
			loadedServices[moduleScript.Name] = serviceOrErr
			serviceCount += 1
		else
			Logger:Error(("Failed to require service '%s': %s"):format(moduleScript.Name, tostring(serviceOrErr)))
		end
	end
end

local function runsInCurrentMode(service: any): boolean
	local modes = service.Modes
	if not modes then
		return true
	end
	return table.find(modes, currentMode) ~= nil
end

for name, service in pairs(loadedServices) do
	if type(service) == "table" and runsInCurrentMode(service) and type(service.Init) == "function" then
		local ok, err = pcall(service.Init, service)
		if not ok then
			Logger:Error(("Service '%s' failed Init: %s"):format(name, tostring(err)))
		end
	end
end

for name, service in pairs(loadedServices) do
	if type(service) == "table" and runsInCurrentMode(service) and type(service.Start) == "function" then
		local ok, err = pcall(service.Start, service)
		if not ok then
			Logger:Error(("Service '%s' failed Start: %s"):format(name, tostring(err)))
		end
	end
end

Logger:Info(("Bootstrap complete. %d service(s) loaded."):format(serviceCount))
