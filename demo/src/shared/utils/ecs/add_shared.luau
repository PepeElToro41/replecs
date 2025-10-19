local ReplicatedStorage = game:GetService "ReplicatedStorage"
local world = require(ReplicatedStorage.code.world)
local replecs = require(ReplicatedStorage.packages.replecs)

function add_shared<T>(entities: T): T
	for name, entity in pairs(entities :: any) do
		world:add(entity, replecs.shared)
	end
	return entities
end

return add_shared
