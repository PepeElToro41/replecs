local replecs = require "@replecs"
local jecs = require "@pkg/jecs"

local member = newproxy()

local world = jecs.world()
local replicator = replecs.create_server(world)

replicator.masking:register_client(member)

replicator:mark_player_ready(member)
replicator:init()
