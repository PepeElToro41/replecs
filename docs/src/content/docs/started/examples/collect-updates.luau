local replicator = require("@server/replicator")
local interval = require("@utils/interval")
local system = require("@utils/scheduler/system")

-- interval throttles systems to a specific interval
local updates_interval = interval(1 / 20)

function replecs_server()
    -- will send updates 20 times a second
    if updates_interval() then
        for player, buf, variants in replicator:collect_updates() do
            remotes_server.send_updates:fire(player, buf, variants)
        end
    end
end

system(replecs_server)
