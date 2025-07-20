local RunService = game:GetService "RunService"
local Jecs = require(script.Parent.jecs)
local Common = require(script.common)

local client = require(script.client)
local server = require(script.server)

local rejecs = {}

export type Server = server.Server
export type Client = client.Client

function rejecs.create(world: Jecs.World, forced: ("client" | "server")?)
	local components: Common.Components = {
		shared = world:entity(),
		networked = world:entity() :: Jecs.Entity<{ [Player]: boolean }?>,
		reliable = world:entity(),
		unreliable = world:entity(),
		pair = world:entity(),

		serdes = world:component() :: Jecs.Entity<Common.Serdes>,
		bytespan = world:component() :: Jecs.Entity<number>,
		custom_id = world:component() :: Jecs.Entity<(any) -> Jecs.Entity>,
		__alive_tracking__ = world:entity(),
	}

	local hooks: Common.WorldHooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	local lib = {}

	if forced then
		if forced == "server" then lib.server = server.create(world, components, hooks) end
		if forced == "client" then lib.client = client.create(world, components) end
	else
		if RunService:IsServer() then lib.server = server.create(world, components, hooks) end
		if RunService:IsClient() then lib.client = client.create(world, components) end
	end

	return lib
end

return rejecs
