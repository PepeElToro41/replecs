local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.utils.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)

local q_lifetimes = world:query(c.unix, c.lifetime):cached()

function LIFETIMES()
	local now = os.clock()

	for entity, unix, lifetime in q_lifetimes:iter() do
		if now - unix > lifetime then
			world:delete(entity)
		end
	end
end

scheduler.System(LIFETIMES)
return LIFETIMES
