local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local replicator = require(ServerScriptService.code.replicator)
local zap = require(ServerScriptService.code.zap)
local interval = require(ReplicatedStorage.code.ecs.interval)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)

local updates_interval = interval(1 / 20)
local unreliable_interval = interval(1 / 30)

function REPLECS_SERVER()
	if updates_interval() then
		for player, buf, variants in replicator:collect_updates() do
			zap.OnReliableUpdates.Fire(player, buf, variants)
		end
	end
	if unreliable_interval() then
		for player, buf, variants in replicator:collect_unreliable() do
			zap.OnUnreliableUpdates.Fire(player, buf, variants)
		end
	end
end

scheduler.System(REPLECS_SERVER)
return REPLECS_SERVER
