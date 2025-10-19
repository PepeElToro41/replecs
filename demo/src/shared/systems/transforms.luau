local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"
local c = require(ReplicatedStorage.code.components)
local scheduler = require(ReplicatedStorage.code.utils.ecs.scheduler)
local world = require(ReplicatedStorage.code.world)

local q_transforms = world:query(c.basepart, c.transform):cached()

function TRANSFORMS()
	for _, archetype in q_transforms:archetypes() do
		local basepart_index = world.component_index[c.basepart]
		local transform_index = world.component_index[c.transform]
		local basepart_record = basepart_index.records[archetype.id]
		local transform_record = transform_index.records[archetype.id]

		local baseparts = archetype.columns[basepart_record]
		local transforms = archetype.columns[transform_record]

		Workspace:BulkMoveTo(baseparts, transforms)
	end
end

scheduler.System(TRANSFORMS)
return TRANSFORMS
