local replicator = require("@client/replicator")
local collect = require("@utils/collect")
local system = require("@utils/scheduler/system")

local updates = collect(remotes_client.send_updates)
local unreliables = collect(remotes_client.send_unreliables)

function replecs_client()
    for buf, variants in updates do
        replicator:apply_updates(buf, variants)
    end
    for buf, variants in unreliables do
        replicator:apply_unreliable(buf, variants)
    end
end

system(replecs_client)
