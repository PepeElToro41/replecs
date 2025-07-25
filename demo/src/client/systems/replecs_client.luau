local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicator = require(script.Parent.Parent.replicator)
local collect = require(ReplicatedStorage.code.ecs.collect)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local zap = require(ReplicatedStorage.code.zap)

local update_events = collect(zap.OnReliableUpdates.SetCallback)
local unreliable_events = collect(zap.OnUnreliableUpdates.SetCallback)

function REPLECS_CLIENT()
	for _, buf, variants in update_events do
		replicator:apply_updates(buf, variants)
	end

	for _, buf, variants in unreliable_events do
		replicator:apply_unreliable(buf, variants)
	end
end

scheduler.System(REPLECS_CLIENT)
return REPLECS_CLIENT
