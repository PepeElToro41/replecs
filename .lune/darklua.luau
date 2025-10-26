local fs = require "@lune/fs"
local process = require "@lune/process"

local OUTPUT = "serve"
local DARKLUA_CONFIG = ".darklua.json"

local function process_darklua()
	if fs.isDir(OUTPUT) then
		fs.removeDir(OUTPUT)
	end

	fs.writeDir(OUTPUT)

	fs.copy("serve.project.json", OUTPUT .. "/serve.project.json")
	fs.copy("default.project.json", OUTPUT .. "/default.project.json")
	fs.copy("src", OUTPUT .. "/src")
	fs.copy("luau_packages", OUTPUT .. "/luau_packages")
	fs.copy("jecs.luau", OUTPUT .. "/jecs.luau")
	fs.copy("wally.toml", OUTPUT .. "/wally.toml")
	fs.copy("LICENSE", OUTPUT .. "/LICENSE")
	fs.copy("README.md", OUTPUT .. "/README.md")

	process.exec("rojo", {
		"sourcemap",
		OUTPUT .. "/serve.project.json",
		"--output",
		"darklua-sourcemap.json",
	}, { stdio = "forward" })

	process.exec("darklua", {
		"process",
		"src",
		`{OUTPUT}/src`,
		`--config`,
		DARKLUA_CONFIG,
	}, { stdio = "forward" })
end

return {
	run = process_darklua,
	OUTPUT = OUTPUT,
}
