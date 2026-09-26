local replicator = require("@server/replicator")
local interval = require("@utils/interval")
local system = require("@utils/scheduler/system")

local updates_interval = interval(1 / 20)

-- callbacks waiting to be resumed by the system
local pending_threads: { thread } = {}

remotes_server.receive_full:set_callback(function(player)
	-- yield until the replication system resumes us
	table.insert(pending_threads, coroutine.running())
	coroutine.yield()

	if not player.Parent then
		return -- left while waiting
	end
	replicator:mark_player_ready(player)
	return replicator:get_full(player)
end)

function replecs_server()
	if updates_interval() then
		-- resume the callbacks right before collecting updates
		local threads = table.clone(pending_threads)
		table.clear(pending_threads)
		for _, thread in threads do
			coroutine.resume(thread)
		end

		for player, buf, variants in replicator:collect_updates() do
			remotes_server.send_updates:fire(player, buf, variants)
		end
	end
end

system(replecs_server)
