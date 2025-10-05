local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local replicator = require(ServerScriptService.code.replicator)
local c = require(ReplicatedStorage.code.components)
local count_query = require(ReplicatedStorage.code.utils.count_query)
local world = require(ReplicatedStorage.code.world)
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)

local MAX_CUBES = 100

function create_cube()
	local new_cube = world:entity()

	local random_pos = Vector3.new(math.random(-200, 200), math.random(20, 200), math.random(-200, 200))
	local cube_size = math.random(5, 10)

	world:set(new_cube, c.transform, CFrame.new(random_pos))
	world:set(new_cube, c.color, BrickColor.random().Color)
	world:set(new_cube, c.size, Vector3.new(cube_size, cube_size, cube_size))
	world:add(new_cube, c.cube)
	world:add(new_cube, c.wooble)
	world:set(new_cube, c.unix, os.clock())

	replicator:set_networked(new_cube)
	replicator:set_unreliable(new_cube, c.transform)
	replicator:set_reliable(new_cube, c.color)
	replicator:set_reliable(new_cube, c.cube)
	replicator:set_reliable(new_cube, c.size)

	return new_cube
end

local q_cubes = world:query(c.cube):cached()

task.spawn(function()
	for i = 1, MAX_CUBES do
		task.wait(0.2)
		create_cube()
	end

	while true do
		task.wait(0.2)
		local count = count_query(q_cubes)
		if count >= MAX_CUBES then
			continue
		end
		create_cube()
	end
end)

return nil
