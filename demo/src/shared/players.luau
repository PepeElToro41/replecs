local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local c = require(script.Parent.components)
local ref = require(ReplicatedStorage.code.ecs.ref)
local replecs = require(ReplicatedStorage.packages.replecs)
local jecs = require(ReplicatedStorage.packages[".pesde"]["alicesaidhi_jabby@0.3.1"].jecs)
local world = require(script.Parent.world)

local players = {}

function setup(player: Player)
	local entity = ref(player)
	world:set(entity, c.player, player)

	if RunService:IsServer() then
		world:add(entity, replecs.networked)
		world:add(entity, jecs.pair(replecs.custom_id, c.player))
	end

	for _, callback in world:query(c.setup_player):iter() do
		callback(player, entity)
	end
end

function players.start_current_players()
	for _, player in Players:GetPlayers() do
		setup(player)
	end
end

function players.listen_for_players()
	Players.PlayerAdded:Connect(setup)
end

return players
