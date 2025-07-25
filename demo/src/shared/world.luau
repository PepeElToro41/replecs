local ReplicatedStorage = game:GetService "ReplicatedStorage"
local jecs = require(ReplicatedStorage.packages.jecs)
local observers = require(script.Parent.ecs.observers)

return observers(jecs.world())
