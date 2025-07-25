local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)
local jecs = require(ReplicatedStorage.packages.jecs)

local started_at = world:component() :: jecs.Entity<CFrame>

local q_non_started = world:query(c.transform):without(started_at):cached()
local q_wooble = world:query(c.unix, started_at):with(c.wooble):cached()

function WOOBLE()
	local now = os.clock()

	for entity, transform in q_non_started:iter() do
		world:set(entity, started_at, transform)
	end
	for entity, unix: number, started: CFrame in q_wooble:iter() do
		local elapsed = now - unix
		world:set(entity, c.transform, started + Vector3.new(0, math.sin(elapsed) * 10, 0))
	end
end

scheduler.System(WOOBLE)
return WOOBLE
