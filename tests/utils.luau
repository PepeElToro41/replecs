local utils = {}

local color = {
	white_underline = function(s: string): string
		return `\27[1;4m{s}\27[0m`
	end,

	white = function(s: string): string
		return `\27[37;1m{s}\27[0m`
	end,

	green = function(s: string): string
		return `\27[38;5;78m{s}\27[0m`
	end,

	magenta = function(s: string): string
		return `\27[38;5;171m{s}\27[0m`
	end,

	red = function(s: string): string
		return `\27[31;1m{s}\27[0m`
	end,

	blue = function(s: string): string
		return `\27[38;5;39m{s}\27[0m`
	end,

	yellow = function(s: string): string
		return `\27[38;5;11m{s}\27[0m`
	end,

	red_highlight = function(s: string): string
		return `\27[41;1;30m{s}\27[0m`
	end,

	green_highlight = function(s: string): string
		return `\27[42;1;30m{s}\27[0m`
	end,

	gray = function(s: string): string
		return `\27[38;1m{s}\27[0m`
	end,
}

function is_valid_identifier(str: string): boolean
	if typeof(str) ~= "string" then
		return false
	end
	return str:match "^[A-Za-z_][A-Za-z0-9_]*$" == nil
end

function table_is_empty(t: any): boolean
	for _ in pairs(t) do
		return false
	end
	return true
end

function table_is_single(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local count = 0
	for _ in t do
		if count >= 1 then
			return false
		end
		count += 1
	end
	return true
end

function table_is_array(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	return #t > 0
end

function format_value(value: any, depth: number, indent: number, visited: any): string
	local t = typeof(value)
	if t == "string" then
		return color.green(`"{value}"`)
	elseif t == "number" then
		return color.blue(tostring(value))
	elseif t == "boolean" then
		return color.yellow(tostring(value))
	elseif t == "table" then
		if visited[value] then
			return color.red "[CYCLE]"
		end
		if indent >= depth then
			return color.gray "{...}"
		end
		if table_is_empty(value) then
			return "{ }"
		end
		local is_single = table_is_single(value)
		local is_array = table_is_array(value)

		visited[value] = true
		local parts = {}
		local indent_str = string.rep("   ", indent)
		for k, val in value do
			local val_t = type(val)
			local val_str = format_value(val, depth, indent + 1, visited)
			if is_array then
				if is_single then
					if val_t == "table" then
						is_single = false
						table.insert(parts, indent_str .. val_str)
					else
						table.insert(parts, val_str)
					end
				else
					table.insert(parts, indent_str .. val_str)
				end
			else
				local key_str: any = k
				if is_valid_identifier(k :: any) then
					key_str = "[" .. format_value(k, depth, indent + 1, visited) .. "]"
				else
					if typeof(key_str) ~= "string" then
						key_str = "[" .. color.magenta(tostring(key_str)) .. "]"
					end
				end
				if is_single then
					if val_t == "table" then
						is_single = false
						table.insert(parts, indent_str .. key_str .. color.white " = " .. val_str)
					else
						table.insert(parts, key_str .. color.white " = " .. val_str)
					end
				else
					table.insert(parts, indent_str .. key_str .. color.white " = " .. val_str)
				end
			end
		end
		visited[value] = nil
		if is_single then
			return "{ " .. table.concat(parts, "") .. " }"
		else
			return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("   ", indent - 1) .. "}"
		end
	else
		return color.magenta(`[{t}]: ` .. tostring(value))
	end
end

function utils.stringify_value(t: any, depth: number?): string
	return format_value(t, (depth or 8) + 1, 1, {})
end

return utils
