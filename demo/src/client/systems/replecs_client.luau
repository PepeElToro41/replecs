local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicator = require(script.Parent.Parent.replicator)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local zap = require(ReplicatedStorage.code.zap)

function REPLECS_CLIENT()
	for _, buf, variants in zap.OnReliableUpdates.Iter() do
		replicator:apply_updates(buf, variants)
	end
	for _, buf, variants in zap.OnUnreliableUpdates.Iter() do
		replicator:apply_unreliable(buf, variants)
	end
end

scheduler.System(REPLECS_CLIENT)
return REPLECS_CLIENT
