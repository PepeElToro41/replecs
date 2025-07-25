local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Jecs = require(ReplicatedStorage.packages.jecs)
local world = require(ReplicatedStorage.code.world)

function add_names<T>(entities: T): T
	for name, entity in pairs(entities :: any) do
		world:set(entity, Jecs.Name, name)
	end
	return entities
end

return add_names
