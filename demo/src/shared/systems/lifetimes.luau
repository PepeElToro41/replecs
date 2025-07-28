local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)
local jecs = require(ReplicatedStorage.packages[".pesde"]["ukendio_jecs@0.8.3"].jecs)

local q_lifetimes = world:query(c.unix, c.lifetime):cached()

function LIFETIMES()
	local now = os.clock()

	for entity, unix, lifetime in q_lifetimes:iter() do
		if now - unix > lifetime then
			print("DELETING ENTITY", entity, jecs.ECS_ID(entity :: any))
			world:delete(entity)
		end
	end
end

scheduler.System(LIFETIMES)
return LIFETIMES
