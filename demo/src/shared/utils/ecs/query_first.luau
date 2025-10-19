local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Jecs = require(ReplicatedStorage.packages.jecs)

function query_first<T...>(
	query: Jecs.Query<T...>,
	predicator: ((entity: Jecs.Entity, T...) -> boolean)?
): (Jecs.Entity, T...)
	local iterator = query:iter()
	if predicator then
		while true do
			local values = { iterator() }
			if not values[1] then
				break
			end
			if predicator(unpack(values)) then
				return unpack(values) :: any
			end
		end
		return nil :: any
	else
		return iterator()
	end
end

return query_first
