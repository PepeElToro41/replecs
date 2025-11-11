local ReplicatedStorage = game:GetService "ReplicatedStorage"

local collect = require(ReplicatedStorage.code.utils.collect)
local replicator = require(script.Parent.Parent.replicator)
local scheduler = require(ReplicatedStorage.code.utils.ecs.scheduler)
local zap = require(ReplicatedStorage.code.zap)

local reliable_updates = collect(zap.OnReliableUpdates.SetCallback)
local unreliable_updates = collect(zap.OnUnreliableUpdates.SetCallback)

function REPLECS_CLIENT()
	for _, buf, variants in reliable_updates do
		replicator:apply_updates(buf, variants)
	end
	for _, buf, variants in unreliable_updates do
		replicator:apply_unreliable(buf, variants)
	end
end

scheduler.System(REPLECS_CLIENT)
return REPLECS_CLIENT
