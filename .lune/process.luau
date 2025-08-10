local fs = require "@lune/fs"
local process = require "@lune/process"
local task = require "@lune/task"

local OUTPUT = "serve"
local DARKLUA_CONFIG = ".darklua.json"

local function process_darklua()
	if fs.isDir(OUTPUT) then
		fs.removeDir(OUTPUT)
	end

	fs.writeDir(OUTPUT)

	fs.copy("serve.project.json", OUTPUT .. "/serve.project.json")
	fs.copy("src", OUTPUT .. "/src")
	fs.copy("luau_packages", OUTPUT .. "/luau_packages")
	fs.copy("jecs.luau", OUTPUT .. "/jecs.luau")

	process.exec("rojo", {
		"sourcemap",
		OUTPUT .. "/serve.project.json",
		"--output",
		"darklua-sourcemap.json",
	}, { stdio = "forward" })

	task.spawn(function()
		process.exec("rojo", {
			"sourcemap",
			OUTPUT .. "/serve.project.json",
			"--output",
			"darklua-sourcemap.json",
		})
	end)

	process.exec("darklua", {
		"process",
		"-w",
		"src",
		`{OUTPUT}/src`,
		`--config`,
		DARKLUA_CONFIG,
	}, { stdio = "forward" })
end

return process_darklua
