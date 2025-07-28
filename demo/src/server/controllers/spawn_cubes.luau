local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local count_query = require(ReplicatedStorage.code.utils.count_query)
local world = require(ReplicatedStorage.code.world)
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)

local MAX_CUBES = 50

function create_cube()
	local new_cube = world:entity()
	print("CREATING NEW CUBE", new_cube, jecs.ECS_ID(new_cube :: any))

	local random_pos = Vector3.new(math.random(-200, 200), math.random(20, 200), math.random(-200, 200))
	local cube_size = math.random(5, 10)

	world:set(new_cube, c.transform, CFrame.new(random_pos))
	world:set(new_cube, c.color, BrickColor.Random().Color)
	world:set(new_cube, c.size, Vector3.new(cube_size, cube_size, cube_size))
	world:add(new_cube, c.cube)
	world:add(new_cube, c.wooble)
	world:set(new_cube, c.unix, os.clock())
	world:set(new_cube, c.lifetime, math.random(5, 15))

	world:add(new_cube, replecs.networked)
	world:add(new_cube, jecs.pair(replecs.reliable, c.transform))
	world:add(new_cube, jecs.pair(replecs.reliable, c.color))
	world:add(new_cube, jecs.pair(replecs.reliable, c.cube))
	world:add(new_cube, jecs.pair(replecs.reliable, c.size))
end

task.spawn(function()
	for i = 1, MAX_CUBES do
		task.wait(0.1)
		create_cube()
	end

	while true do
		task.wait()
		if count_query(world:query(c.cube, replecs.networked)) > MAX_CUBES then
			continue
		end
		create_cube()
	end
end)

return nil
