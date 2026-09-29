local replicator = require("@server/replicator")
local interval = require("@utils/interval")
local system = require("@utils/scheduler/system")

local updates_interval = interval(1 / 20)

-- players waiting for the full state of the world
local pending_players: { Player } = {}

remotes_server.request_full:on(function(player)
	table.insert(pending_players, player)
end)

function replecs_server()
	if updates_interval() then
		-- activate pending players right before collecting updates
		for _, player in pending_players do
			if not player.Parent then
				continue -- left before we got here
			end
			replicator:mark_player_ready(player)
			local buf, variants = replicator:get_full(player)
			remotes_server.receive_full:fire(player, buf, variants)
		end
		table.clear(pending_players)

		for player, buf, variants in replicator:collect_updates() do
			remotes_server.send_updates:fire(player, buf, variants)
		end
	end
end

system(replecs_server)
