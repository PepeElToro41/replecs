local replicator = require("@server/replicator")
local interval = require("@utils/interval")
local system = require("@utils/scheduler/system")

local updates_interval = interval(1 / 20)
local unreliables_interval = interval(1 / 30)

function replecs_server()
    -- will send updates 20 times a second
    if updates_interval() then
        for player, buf, variants in replicator:collect_updates() do
            remotes_server.send_updates:fire(player, buf, variants)
        end
    end

    -- will send unreliables 30 times a second
    if unreliables_interval() then
        for player, buf, variants in replicator:collect_unreliable() do
            remotes_server.send_unreliables:fire(player, buf, variants)
        end
    end
end

system(replecs_server)
