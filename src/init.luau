local RunService = game:GetService "RunService"
local jecs = require(script.Parent.jecs)
local common = require(script.common)

local client = require(script.client)
local server = require(script.server)

export type Server = server.Server
export type Client = client.Client

export type Replecs = {
	components: common.Components,
	server: Server,
	client: Client,

	after_replication: (self: any, callback: () -> ()) -> (),
}

local replecs = {
	shared = jecs.tag(),
	networked = jecs.component() :: jecs.Entity<{ [Player]: boolean }?>,
	reliable = jecs.tag(),
	unreliable = jecs.tag(),
	pair = jecs.tag(),

	serdes = jecs.component() :: jecs.Entity<common.Serdes>,
	bytespan = jecs.component() :: jecs.Entity<number>,
	custom_id = jecs.component() :: jecs.Entity<(any) -> jecs.Entity>,
	__alive_tracking__ = jecs.tag(),
}
replecs.__index = replecs

function replecs.create(world: jecs.World, forced: ("client" | "server" | "both")?): Replecs
	local lib = {} :: Replecs

	if forced then
		if forced == "server" or forced == "both" then
			lib.server = server.create(world, replecs)
		end
		if forced == "client" or forced == "both" then
			lib.client = client.create(world, replecs)
		end
	else
		if RunService:IsServer() then
			lib.server = server.create(world, replecs)
		end
		if RunService:IsClient() then
			lib.client = client.create(world, replecs)
		end
	end

	return setmetatable(lib, replecs) :: any
end

function replecs.after_replication(lib: Replecs, callback: () -> ())
	local lib_client = lib.client
	if lib_client then
		lib_client:after_replication(callback)
	else
		callback()
	end
end

return replecs
