local ReplicatedStorage = game:GetService "ReplicatedStorage"
require(ReplicatedStorage.packages.replecs)

local players = require(ReplicatedStorage.code.players)
local systems_order = require(script.systems_order)
local start = require(ReplicatedStorage.code.start)
local import_paths = require(ReplicatedStorage.code.utils.import_paths)
local zap = require(script.zap)

local replicator = require(script.replicator)
replicator:init()

import_paths(script.systems)
import_paths(ReplicatedStorage.code.systems)

start(systems_order)

import_paths(script.controllers)

players.start_current_players()
players.listen_for_players()

zap.WaitForServer.SetCallback(function(player)
	if replicator:is_player_ready(player) then
		return nil, nil
	end
	replicator:mark_player_ready(player)
	local buf, variants = replicator:get_full(player)

	return buf, variants, replicator:generate_handshake()
end)

game:BindToClose(function()
	task.wait(2)
end)
