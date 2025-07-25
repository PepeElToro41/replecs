local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)

local q_timers = world:query(c.timer):cached()

function TIMERS()
	local now = os.clock()

	for entity, timer in q_timers:iter() do
		local elapsed = now - timer.start

		if elapsed < timer.wait then
			continue
		end
		timer.callback(entity)
		if timer.repeats then
			timer.start = now
		else
			world:delete(entity)
		end
	end
end

scheduler.System(TIMERS)
return TIMERS
