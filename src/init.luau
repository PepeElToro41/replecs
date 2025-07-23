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
}

local replecs = {}

function replecs.create(forced: ("client" | "server")?): Replecs
	local lib = {} :: Replecs

	lib.components = {
		shared = jecs.tag(),
		networked = jecs.tag() :: jecs.Entity<{ [Player]: boolean }?>,
		reliable = jecs.tag(),
		unreliable = jecs.tag(),
		pair = jecs.tag(),

		serdes = jecs.component() :: jecs.Entity<common.Serdes>,
		bytespan = jecs.component() :: jecs.Entity<number>,
		custom_id = jecs.component() :: jecs.Entity<(any) -> jecs.Entity>,
		__alive_tracking__ = jecs.tag(),
	}

	if forced then
		if forced == "server" then
			lib.server = server.create(lib.components)
		end
		if forced == "client" then
			lib.client = client.create(lib.components)
		end
	else
		if RunService:IsServer() then
			lib.server = server.create(lib.components)
		end
		if RunService:IsClient() then
			lib.client = client.create(lib.components)
		end
	end

	return lib
end

return replecs
