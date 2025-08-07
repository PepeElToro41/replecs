local jecs = require "./jecs"
local common = require "@self/common"

local client = require "@self/client"
local server = require "@self/server"

export type Server = server.Server
export type Client = client.Client

export type ReplecsLib = {
	server: Server,
	client: Client,

	after_replication: (self: ReplecsLib, callback: () -> ()) -> (),
}

type MemberFilter = {
	[Player]: boolean,
}

local replecs = {
	shared = jecs.tag(),
	networked = jecs.component() :: jecs.Entity<(MemberFilter | Player)?>,
	reliable = jecs.component() :: jecs.Entity<(MemberFilter | Player)?>,
	unreliable = jecs.component() :: jecs.Entity<(MemberFilter | Player)?>,
	pair = jecs.tag(),

	serdes = jecs.component() :: jecs.Entity<common.Serdes>,
	bytespan = jecs.component() :: jecs.Entity<number>,
	custom = jecs.tag() :: jecs.Entity,
	custom_handler = jecs.component() :: jecs.Entity<(any) -> jecs.Entity>,
	global = jecs.component() :: jecs.Entity<number>,
	__alive_tracking__ = jecs.tag(),
}

replecs.__index = replecs
replecs.Serdes = replecs.serdes
replecs.Bytespan = replecs.bytespan
replecs.Custom = replecs.custom
replecs.CustomHandler = replecs.custom_handler
replecs.Networked = replecs.networked
replecs.Reliable = replecs.reliable
replecs.Unreliable = replecs.unreliable
replecs.Pair = replecs.pair
replecs.Shared = replecs.shared
replecs.Global = replecs.global

jecs.meta(replecs.serdes, jecs.Name, "replecs.serdes")
jecs.meta(replecs.bytespan, jecs.Name, "replecs.bytespan")
jecs.meta(replecs.custom, jecs.Name, "replecs.custom")
jecs.meta(replecs.custom_handler, jecs.Name, "replecs.custom_handler")
jecs.meta(replecs.networked, jecs.Name, "replecs.networked")
jecs.meta(replecs.reliable, jecs.Name, "replecs.reliable")
jecs.meta(replecs.unreliable, jecs.Name, "replecs.unreliable")
jecs.meta(replecs.pair, jecs.Name, "replecs.pair")
jecs.meta(replecs.shared, jecs.Name, "replecs.shared")
jecs.meta(replecs.global, jecs.Name, "replecs.global")

jecs.meta(replecs.custom, jecs.Exclusive)
jecs.meta(replecs.global, jecs.Exclusive)

function replecs.create_server(world: jecs.World?): Server
	return server.create(world, replecs)
end

function replecs.create_client(world: jecs.World?): Client
	return client.create(world, replecs)
end

function replecs.create(world: jecs.World?): ReplecsLib
	assert(game, "This is a Roblox specific function")

	local RunService = game:GetService "RunService"
	local lib = {} :: ReplecsLib

	if RunService:IsServer() then
		lib.server = server.create(world, replecs)
	end
	if RunService:IsClient() then
		lib.client = client.create(world, replecs)
	end

	return setmetatable(lib, replecs) :: any
end

function replecs.after_replication(lib: ReplecsLib, callback: () -> ())
	local lib_client = lib.client
	if lib_client then
		lib_client:after_replication(callback)
	else
		callback()
	end
end

return replecs
