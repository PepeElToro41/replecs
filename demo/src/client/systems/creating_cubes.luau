local ReplicatedStorage = game:GetService "ReplicatedStorage"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)

local q_no_cube = world:query(c.cube, c.transform, c.size, c.color):without(c.basepart):cached()

function CREATING_CUBES()
	for entity, cube, transform, size, color in q_no_cube:iter() do
		local new_cube = Instance.new "Part"
		new_cube.Size = size
		new_cube.Anchored = true
		new_cube.CanCollide = false
		new_cube.CFrame = transform
		new_cube.Color = color

		new_cube.Parent = workspace
		world:set(entity, c.basepart, new_cube)
		world:set(entity, c.cleanup, function()
			new_cube:Destroy()
		end)
	end
end

scheduler.System(CREATING_CUBES)
return CREATING_CUBES
