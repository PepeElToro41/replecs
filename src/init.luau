local common = require "@self/common"
local types = require "@self/types"
local utils = require "@self/utils"

local client = require "@self/client"
local server = require "@self/server"
local customid = require "@self/customid"
local VERSION = require "@self/ver"

export type Server = server.Server
export type Client = client.Client

type Entity = common.Entity
type World = common.World

export type HandleContext = customid.HandleContext
export type CustomId = customid.CustomId
export type HandshakeInfo = types.HandshakeInfo

export type ReplecsLib = {
	server: Server,
	client: Client,
	components: types.Components,

	after_replication: (self: ReplecsLib, callback: () -> ()) -> (),
	register_custom_id: (self: ReplecsLib, custom_id: CustomId) -> (),
}

type Replecs = types.Components & {
	__index: any,
	VERSION: string,
	create: (world: World?) -> ReplecsLib,

	create_server: (world: World?) -> Server,
	create_client: (world: World?) -> Client,
	create_custom_id: (identifier: string, handler: (ctx: HandleContext) -> Entity?) -> CustomId,
}

local replecs = {}
replecs.VERSION = VERSION
replecs.__index = replecs

local PREREGISTRATION = common.preregistration

if PREREGISTRATION then
	local components = replecs :: Replecs
	utils.create_components(common.preregister_tag, common.preregister_component, components)
	utils.add_component_names(components, common.add_preregistered_name)

	--[[
	jecs.meta(components.custom, jecs.Exclusive)
	jecs.meta(components.global, jecs.Exclusive)
	]]
end

local COMPONENTS = if PREREGISTRATION then replecs :: Replecs else nil

function replecs.create_server(world: World?): Server
	return server.create(world, COMPONENTS)
end

function replecs.create_client(world: World?): Client
	return client.create(world, COMPONENTS)
end

function replecs.create(world: World?): ReplecsLib
	assert(game, "This is a Roblox specific function")
	local RunService = game:GetService "RunService"
	local self = {} :: ReplecsLib

	if COMPONENTS then
		self.components = COMPONENTS
	elseif world then
		self.components = utils.create_components(utils.tag_factory(world), utils.component_factory(world))
		utils.add_component_names(self.components, function(component, name)
			common.add_name(world, component, name)
		end)
	end

	if RunService:IsServer() then
		self.server = server.create(world, self.components)
	end
	if RunService:IsClient() then
		self.client = client.create(world, self.components)
	end

	return setmetatable(self, replecs) :: any
end

function replecs.create_custom_id(identifier: string, handler: (ctx: HandleContext) -> Entity?)
	return customid.create(identifier, handler)
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
