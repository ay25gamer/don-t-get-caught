--!strict
--[[
	Client bootstrap for DON'T GET CAUGHT.

	Mirrors the server's two-phase Init/Start lifecycle for Controllers/ — see
	src/Server/init.server.luau for the rationale, including mode-gating: a controller can
	export `Controller.Modes = {"Match"}` (or `{"Hub"}`) to only run in that server mode; no
	`Modes` field means it runs in both. See Shared/Util/ServerMode.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("Shared"))
local Logger = Shared.Logger.new("ClientBootstrap")

local currentMode = Shared.ServerMode.Current()
Logger:Info(("Server mode: %s"):format(currentMode))

local Controllers = script:WaitForChild("Controllers")
local loadedControllers: { [string]: any } = {}
local controllerCount = 0

for _, moduleScript in ipairs(Controllers:GetChildren()) do
	if moduleScript:IsA("ModuleScript") then
		local ok, controllerOrErr = pcall(require, moduleScript)
		if ok then
			loadedControllers[moduleScript.Name] = controllerOrErr
			controllerCount += 1
		else
			Logger:Error(("Failed to require controller '%s': %s"):format(moduleScript.Name, tostring(controllerOrErr)))
		end
	end
end

local function runsInCurrentMode(controller: any): boolean
	local modes = controller.Modes
	if not modes then
		return true
	end
	return table.find(modes, currentMode) ~= nil
end

for name, controller in pairs(loadedControllers) do
	if type(controller) == "table" and runsInCurrentMode(controller) and type(controller.Init) == "function" then
		local ok, err = pcall(controller.Init, controller)
		if not ok then
			Logger:Error(("Controller '%s' failed Init: %s"):format(name, tostring(err)))
		end
	end
end

for name, controller in pairs(loadedControllers) do
	if type(controller) == "table" and runsInCurrentMode(controller) and type(controller.Start) == "function" then
		local ok, err = pcall(controller.Start, controller)
		if not ok then
			Logger:Error(("Controller '%s' failed Start: %s"):format(name, tostring(err)))
		end
	end
end

Logger:Info(("Bootstrap complete. %d controller(s) loaded."):format(controllerCount))
