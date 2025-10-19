local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local c = require(script.Parent.components)
local replicator = require(script.Parent.replicator)
local ref = require(ReplicatedStorage.code.utils.ecs.ref)
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)
local world = require(script.Parent.world)

local players = {}

function setup(player: Player)
	if RunService:IsServer() then
		-- shuffling the entityid to make sure custom ids are working
		world:entity()
		world:entity()
		world:entity()
		world:entity()
	end

	local entity = ref(player)
	world:set(entity, c.player, player)

	if RunService:IsServer() then
		world:add(entity, replecs.networked)
		replicator.server:set_custom(entity, c.player)
		replicator.server:set_reliable(entity, c.player)
		replicator.server:set_reliable(entity, c.unix)
		world:set(entity, c.unix, 0)

		world:set(entity, c.timer, {
			start = os.clock(),
			wait = 1,
			repeats = true,
			callback = function()
				world:set(entity, c.unix, world:get(entity, c.unix) :: number + 1)
			end,
		})
	end

	for _, callback in world:query(c.setup_player):iter() do
		callback(player, entity)
	end
end

function players.cleanup(player: Player)
	local entity = ref.search(player)
	if entity then
		world:delete(entity)
	end
end

function players.start_current_players()
	for _, player in Players:GetPlayers() do
		setup(player)
	end
end

function players.listen_for_players()
	Players.PlayerAdded:Connect(setup)
	Players.PlayerRemoving:Connect(players.cleanup)
end

return players
