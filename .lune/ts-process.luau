local fs = require "@lune/fs"
local process = require "@lune/process"

local OUTPUT = "out/replecs"

function process_npm()
	process.exec("npm", { "install" })
	process.exec("npx roblox-ts", { "--verbose" })
	if process.args[1] and type(process.args[1]) == "string" then
		fs.writeFile(OUTPUT .. "/ver.luau", `return "{process.args[1]}"`)
	end
end

process_npm()
