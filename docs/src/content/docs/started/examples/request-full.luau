local replicator = require("@client/replicator")
local collect = require("@utils/collect")
local system = require("@utils/scheduler/system")

local updates = collect(remotes_client.send_updates)

-- the full state is applied as soon as it arrives,
-- updates are queued and applied by the system afterwards
remotes_client.receive_full:on(function(buf, variants)
	replicator:apply_full(buf, variants)
end)

-- ask the server for the full state of the world
remotes_client.request_full:fire()

function replecs_client()
	for buf, variants in updates do
		replicator:apply_updates(buf, variants)
	end
end

system(replecs_client)
