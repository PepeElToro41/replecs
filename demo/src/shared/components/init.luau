local ReplicatedStorage = game:GetService "ReplicatedStorage"
local world = require(script.Parent.world)
local add_names = require(ReplicatedStorage.code.ecs.add_names)
local add_shared = require(ReplicatedStorage.code.ecs.add_shared)
local ref = require(ReplicatedStorage.code.ecs.ref)
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)

export type TimerInterface = {
	start: number,
	wait: number,
	repeats: boolean?,
	callback: (jecs.Entity) -> (),
}

local components = {
	player = world:component() :: jecs.Entity<Player>,
	client = world:entity(),
	r_owner = world:entity(),
	setup_player = world:component() :: jecs.Entity<(Player, jecs.Entity) -> ()>,
	cleanup = world:component() :: jecs.Entity<(jecs.Entity) -> ()>,

	cube = world:entity(),
	wooble = world:entity(),
	rainbow = world:entity(),
	size = world:component() :: jecs.Entity<Vector3>,
	timer = world:component() :: jecs.Entity<TimerInterface>,
	lifetime = world:component() :: jecs.Entity<number>,
	transform = world:component() :: jecs.Entity<CFrame>,
	color = world:component() :: jecs.Entity<Color3>,
	basepart = world:component() :: jecs.Entity<BasePart>,
	unix = world:component() :: jecs.Entity<number>,
}

world:set(components.player, replecs.custom_id, function(player: Player)
	return ref(player) :: any
end)

world:set(components.transform, replecs.serdes, {
	serialize = function(transform: CFrame)
		local buf = buffer.create(12)
		buffer.writef32(buf, 0, transform.X)
		buffer.writef32(buf, 4, transform.Y)
		buffer.writef32(buf, 8, transform.Z)
		return buf
	end,
	deserialize = function(buf: buffer)
		return CFrame.new(buffer.readf32(buf, 0), buffer.readf32(buf, 4), buffer.readf32(buf, 8))
	end,
})

world:removed(components.cleanup, function(entity: jecs.Entity)
	local callback = world:get(entity, components.cleanup)

	if callback then
		print "cleaning up entity"
		callback(entity)
	end
end)

world:set(components.transform, replecs.bytespan, 12)

add_names(components)
add_shared(components)

return components
