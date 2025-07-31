local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local lifetimes = require(ReplicatedStorage.code.systems.lifetimes)
local transforms = require(ReplicatedStorage.code.systems.transforms)
local replecs_server = require(ServerScriptService.code.systems.replecs_server)

local ordered: { string | ((...any) -> ()) } = {
	"__other__",
	transforms,
	replecs_server,
	lifetimes,
}

return ordered
