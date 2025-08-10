local fs = require "@lune/fs"
local darklua = require "./darklua"
local process = require "@lune/process"
local serde = require "@lune/serde"
local stdio = require "@lune/stdio"

darklua.run()

fs.copy("wally.toml", darklua.OUTPUT .. "/wally.toml")

type WallyData = {
	package: {
		name: string,
		version: string,
	},
}
local wally_data = serde.decode("toml", fs.readFile "wally.toml") :: WallyData

local accepted = stdio.prompt("confirm", "release version " .. wally_data.package.version .. "?")

if accepted then
	process.exec("wally", {
		"publish",
	}, {
		cwd = darklua.OUTPUT,
		stdio = "forward",
	})
end
