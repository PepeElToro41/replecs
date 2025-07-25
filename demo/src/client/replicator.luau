local ReplicatedStorage = game:GetService "ReplicatedStorage"
local world = require(ReplicatedStorage.code.world)
local replecs = require(ReplicatedStorage.packages.replecs)

return replecs.create_client(world)
