local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
require(ReplicatedStorage.packages.replecs)

local c = require(ReplicatedStorage.code.components)

local players = require(ReplicatedStorage.code.players)
local systems_order = require(script.systems_order)
local start = require(ReplicatedStorage.code.start)
local ref = require(ReplicatedStorage.code.utils.ecs.ref)
local import_paths = require(ReplicatedStorage.code.utils.import_paths)
local world = require(ReplicatedStorage.code.world)
local zap = require(ReplicatedStorage.code.zap)

local replicator = require(script.replicator)
replicator:init()

import_paths(script.systems)
import_paths(ReplicatedStorage.code.systems)

replicator:handle_global(function(id)
	return ref(`global-{id}`) :: any
end)

start(systems_order)

import_paths(script.controllers)

players.start_current_players()
players.listen_for_players()

local player = ref(Players.LocalPlayer)
world:add(player, c.client)

local buf, variants = zap.WaitForServer.Call()
if buf then
	replicator:apply_full(buf, variants)
end
