local RunService = game:GetService "RunService"
local jecs = require(script.Parent.roblox_packages.jecs)
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

local function init(replecs: Replecs, world: jecs.World)
	if replecs.server then
		local hooks: common.WorldHooks = {
			added = (world :: any).added,
			changed = (world :: any).changed,
			removed = (world :: any).removed,
		}
		replecs.server:init(world, hooks)
	elseif replecs.client then
		replecs.client:init(world)
	end
end

local replecs = {}
replecs.__index = replecs
replecs.init = init

local function create(forced: ("client" | "server")?): Replecs
	local self = {} :: Replecs

	self.components = {
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
			self.server = server.create(self.components)
		end
		if forced == "client" then
			self.client = client.create(self.components)
		end
	else
		if RunService:IsServer() then
			self.server = server.create(self.components)
		end
		if RunService:IsClient() then
			self.client = client.create(self.components)
		end
	end

	return setmetatable(self, replecs) :: any
end

replecs.create = create

return replecs :: { create: typeof(create) }
