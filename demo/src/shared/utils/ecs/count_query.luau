local ReplicatedStorage = game:GetService "ReplicatedStorage"
local jecs = require(ReplicatedStorage.packages.jecs)

function count_query(query: jecs.Query<any>)
	local count = 0
	for _, archetype in query:archetypes() do
		count += #archetype.entities
	end
	return count
end

return count_query
