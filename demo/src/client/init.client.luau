local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
require(ReplicatedStorage.packages.replecs)

local c = require(ReplicatedStorage.code.components)
local ref = require(ReplicatedStorage.code.ecs.ref)
local players = require(ReplicatedStorage.code.players)
local systems_order = require(script.systems_order)
local start = require(ReplicatedStorage.code.start)
local import_paths = require(ReplicatedStorage.code.utils.import_paths)
local world = require(ReplicatedStorage.code.world)
local zap = require(ReplicatedStorage.code.zap)
local replicator = require(script.replicator)

import_paths(script.systems)
import_paths(ReplicatedStorage.code.systems)

replicator:parse_global_id(function(id)
	return ref(`global-{id}`) :: any
end)

replicator:init()
start(systems_order)

import_paths(script.controllers)

players.start_current_players()
players.listen_for_players()

local player = ref(Players.LocalPlayer)
world:add(player, c.client)

task.wait(5)
local buf, variants = zap.WaitForServer.Call()
if buf then
	replicator:apply_full(buf, variants)
end
print "REPLICATED FULL"
