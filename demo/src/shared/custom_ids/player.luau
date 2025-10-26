local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local replicator = require(ReplicatedStorage.code.replicator)
local ref = require(ReplicatedStorage.code.utils.ecs.ref)
local replecs = require(ReplicatedStorage.packages.replecs)

local handler = replecs.create_custom_id("player", function(ctx)
	return ref(ctx.component(c.player))
end)
replicator:register_custom_id(handler)

return handler
