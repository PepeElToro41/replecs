local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local UserInputService = game:GetService "UserInputService"
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)
local jabby = require(ReplicatedStorage.packages.jabby)

function start_jabby()
	local prefix = RunService:IsServer() and "Server" or "Client"
	jabby.register {
		applet = jabby.applets.world,
		name = `World - {prefix}`,
		configuration = {
			world = world,
		},
	}
	jabby.register {
		applet = jabby.applets.scheduler,
		name = `Scheduler - {prefix}`,
		configuration = {
			scheduler = scheduler.Scheduler :: any,
		},
	}

	jabby.set_check_function(function(player)
		return true
	end)

	if RunService:IsClient() then
		local mounted = false
		local client = jabby.obtain_client()

		UserInputService.InputBegan:Connect(function(input)
			if input.KeyCode ~= Enum.KeyCode.F4 then
				return
			end

			if mounted then
				client.unmount_all()
				mounted = false
			else
				client.spawn_app(client.apps.home :: any)
				mounted = true
			end
		end)
	end
end

function start(systems_order: any)
	start_jabby()
	local events = scheduler.CollectSystems()
	scheduler.Initialize(events, systems_order)
end

return start
