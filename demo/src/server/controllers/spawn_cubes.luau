local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local world = require(ReplicatedStorage.code.world)
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)

task.spawn(function()
	for i = 1, 50 do
		task.wait(0.1)
		local new_cube = world:entity()
		local random_pos = Vector3.new(math.random(-200, 200), math.random(20, 200), math.random(-200, 200))
		local cube_size = math.random(5, 10)

		world:set(new_cube, c.transform, CFrame.new(random_pos))
		world:set(new_cube, c.color, BrickColor.Random().Color)
		world:set(new_cube, c.size, Vector3.new(cube_size, cube_size, cube_size))
		world:add(new_cube, c.cube)
		world:add(new_cube, c.wooble)
		world:set(new_cube, c.unix, os.clock())

		world:add(new_cube, replecs.networked)
		world:add(new_cube, jecs.pair(replecs.unreliable, c.transform))
		world:add(new_cube, jecs.pair(replecs.reliable, c.color))
		world:add(new_cube, jecs.pair(replecs.reliable, c.cube))
		world:add(new_cube, jecs.pair(replecs.reliable, c.size))
	end
end)

return nil
