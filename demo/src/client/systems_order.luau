local ReplicatedStorage = game:GetService "ReplicatedStorage"
local replecs_client = require(script.Parent.systems.replecs_client)
local transforms = require(ReplicatedStorage.code.systems.transforms)
local apply_colors = require(script.Parent.systems.apply_colors)

local ordered: { string | ((...any) -> ()) } = {
	"__other__",
	transforms,
	apply_colors,
	replecs_client,
}

return ordered
