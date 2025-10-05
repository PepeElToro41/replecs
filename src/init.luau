local jecs = require "./jecs"
local common = require "@self/common"

local client = require "@self/client"
local server = require "@self/server"
local customid = require "@self/customid"

export type Server = server.Server
export type Client = client.Client
export type CustomId = customid.CustomId

export type ReplecsLib = {
	server: Server,
	client: Client,

	after_replication: (self: ReplecsLib, callback: () -> ()) -> (),
	register_custom_id: (self: ReplecsLib, custom_id: CustomId) -> (),
}

type Replecs = common.Components & {
	create: (world: jecs.World?) -> ReplecsLib,

	create_server: (world: jecs.World?) -> Server,
	create_client: (world: jecs.World?) -> Client,
	create_custom_id: (identifier: string) -> CustomId,
}

type MemberFilter = {
	[Player]: boolean,
}

local replecs = {
	shared = jecs.tag(),
	networked = jecs.component(),
	reliable = jecs.component(),
	unreliable = jecs.component(),
	pair = jecs.component(),

	serdes = jecs.component(),
	bytespan = jecs.component(),
	custom = jecs.component(),
	global = jecs.component(),
	__alive_tracking__ = jecs.tag(),
}

replecs.__index = replecs
replecs.Serdes = replecs.serdes
replecs.Bytespan = replecs.bytespan
replecs.Custom = replecs.custom
replecs.Networked = replecs.networked
replecs.Reliable = replecs.reliable
replecs.Unreliable = replecs.unreliable
replecs.Pair = replecs.pair
replecs.Shared = replecs.shared
replecs.Global = replecs.global

jecs.meta(replecs.serdes, jecs.Name, "replecs.serdes")
jecs.meta(replecs.bytespan, jecs.Name, "replecs.bytespan")
jecs.meta(replecs.custom, jecs.Name, "replecs.custom")
jecs.meta(replecs.networked, jecs.Name, "replecs.networked")
jecs.meta(replecs.reliable, jecs.Name, "replecs.reliable")
jecs.meta(replecs.unreliable, jecs.Name, "replecs.unreliable")
jecs.meta(replecs.pair, jecs.Name, "replecs.pair")
jecs.meta(replecs.shared, jecs.Name, "replecs.shared")
jecs.meta(replecs.global, jecs.Name, "replecs.global")

jecs.meta(replecs.__alive_tracking__, jecs.Name, "replecs.__alive_tracking__")

jecs.meta(replecs.custom, jecs.Exclusive)
jecs.meta(replecs.global, jecs.Exclusive)

function replecs.create_server(world: jecs.World?): Server
	return server.create(world, replecs :: Replecs)
end

function replecs.create_client(world: jecs.World?): Client
	return client.create(world, replecs :: Replecs)
end

function replecs.create(world: jecs.World?): ReplecsLib
	assert(game, "This is a Roblox specific function")

	local RunService = game:GetService "RunService"
	local lib = {} :: ReplecsLib

	if RunService:IsServer() then
		lib.server = server.create(world, replecs :: Replecs)
	end
	if RunService:IsClient() then
		lib.client = client.create(world, replecs :: Replecs)
	end

	return setmetatable(lib, replecs) :: any
end

function replecs.create_custom_id(identifier: string)
	return customid.create(identifier)
end

function replecs.after_replication(lib: ReplecsLib, callback: () -> ())
	local lib_client = lib.client
	if lib_client then
		lib_client:after_replication(callback)
	else
		callback()
	end
end

function replecs.register_custom_id(lib: ReplecsLib, custom_id: CustomId)
	if lib.server then
		lib.server:register_custom_id(custom_id)
	end
	if lib.client then
		lib.client:register_custom_id(custom_id)
	end
end

return replecs :: Replecs
