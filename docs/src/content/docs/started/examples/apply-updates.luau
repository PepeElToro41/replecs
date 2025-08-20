local replicator = require("@client/replicator")
local collect = require("@utils/collect")
local system = require("@utils/scheduler/system")

-- collect converts events into iterators
local updates = collect(remotes_client.send_updates)

-- system running every frame
function replecs_client()
    for buf, variants in updates do
        replicator:apply_updates(buf, variants)
    end
end

system(replecs_client)
