local fs = require "@lune/fs"
local process = require "@lune/process"

local OUTPUT = "dist"
local DARKLUA_CONFIG = ".darklua.json"

local barrel = [[
import "./jecs"

import replecs from "./replecs"

export = replecs;
]]

local function process_darklua()
	if fs.isDir(OUTPUT) then
		fs.removeDir(OUTPUT)
	end

	fs.writeDir(OUTPUT)

	-- Write project files with $path pointing to "out" for rbxtsc
	fs.writeFile(OUTPUT .. "/default.project.json", fs.readFile("default.project.json"):gsub('"src"', '"out"'))

	fs.copy("./serve-ts.project.json", OUTPUT .. "/serve.project.json")
	fs.copy("package.json", OUTPUT .. "/package.json")
	fs.copy("src", OUTPUT .. "/src/replecs")
	fs.copy("tsconfig.json", OUTPUT .. "/tsconfig.json")
	fs.copy(".darklua.json", OUTPUT .. "/.darklua.json")
	fs.copy("LICENSE", OUTPUT .. "/LICENSE")
	fs.copy("README.md", OUTPUT .. "/README.md")

	fs.writeFile(OUTPUT .. "/src/jecs.ts", 'export * from "@rbxts/jecs"\n')
	fs.writeFile(OUTPUT .. "/src/index.ts", barrel)

	process.exec("npm", { "install" }, { shell = true, stdio = "forward", cwd = OUTPUT })
	process.exec("npx", { "rbxtsc", "--verbose" }, { shell = true, stdio = "forward", cwd = OUTPUT })

	process.exec("rojo", {
		"sourcemap",
		OUTPUT .. "/serve.project.json",
		"--output",
		OUTPUT .. "/darklua-sourcemap.json",
	}, { stdio = "forward" })

	process.exec("darklua", {
		"process",
		`out/replecs`,
		`out/replecs`,
		`--config`,
		DARKLUA_CONFIG,
	}, { stdio = "forward", cwd = OUTPUT })

	if process.args[1] and type(process.args[1]) == "string" then
		fs.writeFile(OUTPUT .. "/src/ver.luau", `return "{process.args[1]}"`)
	end
end

process_darklua()
