local ReplicatedStorage = game:GetService "ReplicatedStorage"
local add_names = require(ReplicatedStorage.code.ecs.add_names)
local world = require(ReplicatedStorage.code.world)

local components = {
	cube = world:entity(),
}

add_names(components)
return components
