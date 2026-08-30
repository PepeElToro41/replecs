type Set<T> = { [T]: boolean }

local utils = {}

function utils.is_include_filter(filter: Set<any>): boolean
	for _, allow in filter do
		return allow
	end
	return true
end

function utils.get_used_filter_type(filter: any)
	if typeof(filter) == "table" then
		return utils.is_include_filter(filter)
	else
		return true
	end
end

return utils
