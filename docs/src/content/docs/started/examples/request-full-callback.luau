local replicator = require("@client/replicator")
local collect = require("@utils/collect")
local system = require("@utils/scheduler/system")

local updates = collect(remotes_client.send_updates)

-- yields until the server resumes the callback inside its system
local buf, variants = remotes_client.receive_full:invoke_server()
replicator:apply_full(buf, variants)

function replecs_client()
	for buf, variants in updates do
		replicator:apply_updates(buf, variants)
	end
end

system(replecs_client)
